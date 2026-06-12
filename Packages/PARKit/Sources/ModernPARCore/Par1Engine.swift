import CryptoKit
import Foundation

/// Native PAR1 verify/repair — the replacement for MacPAR deLuxe's Intel-only `par` helper,
/// built on `Par1RS` (GF(2⁸) math pinned byte-for-byte against that binary's parity).
/// Streams the same `EngineEvent`s as the PAR2 engines so the window renders both formats
/// with identical machinery. (ROADMAP Phase 8; docs/research/03 §6)
///
/// Shape mirrors the other engines: hot stream, blocking drive on a private serial queue,
/// cooperative cancellation via a token the loops poll. PAR1 work is pure Swift file I/O +
/// table lookups — no global state — but runs serialize anyway so two windows never hash
/// the same disk concurrently.
public final class Par1Engine: PAR2Engine, Sendable {
    public init() {}

    private static let queue = DispatchQueue(
        label: "org.modernpar.par1-engine", qos: .userInitiated)

    /// Whole-file processing happens in chunks of this size (verify hashing and RS repair).
    static let chunkSize = 1 << 20

    public func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let token = Par1CancelToken()
            continuation.onTermination = { _ in token.cancel() }
            Self.queue.async {
                EngineDrainRegistry.shared.enter()
                defer { EngineDrainRegistry.shared.leave() }
                Self.execute(route: route, token: token, continuation: continuation)
                continuation.finish()
            }
        }
    }

    // MARK: - Blocking drive (engine queue)

    private static func execute(
        route: SessionRoute,
        token: Par1CancelToken,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) {
        guard route.mode == .verifyRepair else {
            continuation.yield(.finished(.failure(.notImplemented)))
            return
        }
        var scopeStops: [URL] = []
        defer { for url in scopeStops { url.stopAccessingSecurityScopedResource() } }
        if let data = route.folderBookmark, let folder = try? ScopedAccess.resolve(data),
            folder.didStart
        {
            scopeStops.append(folder.url)
        }
        var anchor: URL?
        if let data = route.anchorBookmark, let resolved = try? ScopedAccess.resolve(data) {
            anchor = resolved.url
            if resolved.didStart { scopeStops.append(resolved.url) }
        }
        guard let anchor else {
            continuation.yield(
                .finished(.failure(.launchFailed("session has no anchor bookmark"))))
            return
        }

        do {
            let set = try Par1SetContext(
                anchor: anchor, continuation: continuation)
            try verifyAndRepair(
                set: set, autoRepair: route.autoRepair,
                assumeVerified: Set(route.assumeVerifiedNames ?? []),
                token: token, continuation: continuation)
        } catch is CancellationError {
            continuation.yield(.finished(.failure(.cancelled)))
        } catch let error as EngineError {
            continuation.yield(.finished(.failure(error)))
        } catch {
            continuation.yield(.docStatusChanged(.notValid))
            continuation.yield(.logLine("Could not process the PAR1 set: \(error)"))
            continuation.yield(
                .finished(.failure(.launchFailed("the PAR1 set could not be read"))))
        }
    }

    // MARK: - Verify → verdict → repair

    private static func verifyAndRepair(
        set: Par1SetContext,
        autoRepair: Bool,
        assumeVerified: Set<String>,
        token: Par1CancelToken,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) throws {
        continuation.yield(.scanningStarted(totalFiles: set.roster.count))
        continuation.yield(.filesDiscovered(set.rows.map(\.entry)))
        continuation.yield(.docStatusChanged(.checking))

        // ── Verify ──────────────────────────────────────────────────────────────────────
        var outcomes: [Par1FileOutcome] = []
        let totalBytes = max(1, set.roster.reduce(UInt64(0)) { $0 &+ $1.fileSize })
        var hashedBytes: UInt64 = 0
        for (index, file) in set.roster.enumerated() {
            try token.checkCancelled()
            let url = set.folder.appendingPathComponent(file.name)
            let row = set.rows[index]
            // Retry skips files this session already verified OK — unless they vanished or
            // changed size since (then the skip would lie). (ROADMAP Phase 8 exit criterion)
            if assumeVerified.contains(file.name),
                let size = fileSize(at: url), size == file.fileSize
            {
                outcomes.append(.init(file: file, state: .ok))
                continuation.yield(.fileStatusChanged(id: row.entry.id, status: .ok))
                hashedBytes &+= file.fileSize
                continuation.yield(
                    .overallProgress(fraction: Double(hashedBytes) / Double(totalBytes) * 0.5))
                continue
            }
            continuation.yield(.fileStatusChanged(id: row.entry.id, status: .checking))
            guard fileSize(at: url) != nil else {
                outcomes.append(.init(file: file, state: .missing))
                continue
            }
            let md5 = try hashFile(at: url, token: token) { chunkBytes in
                hashedBytes &+= UInt64(chunkBytes)
                continuation.yield(
                    .overallProgress(fraction: Double(hashedBytes) / Double(totalBytes) * 0.5))
            }
            outcomes.append(
                .init(file: file, state: md5 == file.fileMD5 ? .ok : .corrupt))
        }

        // Renamed detection: a non-roster file in the folder whose MD5 matches a bad
        // entry's roster MD5 ("is a match for" — same semantics as the PAR2 path).
        try detectRenames(set: set, outcomes: &outcomes, token: token)

        // ── Verdict ─────────────────────────────────────────────────────────────────────
        // The recovery indices are positions among IN-SET files in roster order — that is
        // what the parity was computed over (pinned against the Intel binary).
        let inSet = outcomes.enumerated().filter { $0.element.file.isInParitySet }
        let badInSet = inSet.filter { $0.element.state.needsRecovery }
        let renamedCount = outcomes.filter { $0.state.isRenamed }.count
        let badNonContributing = outcomes.filter {
            !$0.file.isInParitySet && $0.state.needsRecovery
        }

        let recoverable: Bool
        var decoder: Par1RS.Decoder?
        if badInSet.isEmpty {
            recoverable = true
        } else if badInSet.count <= set.volumes.count {
            var position = 0
            var missingPositions: [Int] = []
            var intactPositions: [Int] = []
            for (_, outcome) in inSet {
                position += 1
                if outcome.state.needsRecovery {
                    missingPositions.append(position)
                } else {
                    intactPositions.append(position)
                }
            }
            decoder = Par1RS.Decoder(
                missing: missingPositions, intact: intactPositions,
                availableVolumes: set.volumes.map(\.number).sorted(),
                fileCount: inSet.count)
            recoverable = decoder != nil
        } else {
            recoverable = false
        }

        publishStatuses(
            set: set, outcomes: outcomes, recoverable: recoverable,
            continuation: continuation)

        if badInSet.isEmpty && renamedCount == 0 {
            if badNonContributing.isEmpty {
                continuation.yield(.docStatusChanged(.allFilesOK))
                continuation.yield(.logLine("All files are correct."))
            } else {
                // DocStatus13: every in-set file is fine; what's missing never contributed
                // to the parity data and cannot be rebuilt from it.
                continuation.yield(.docStatusChanged(.onlyNonRecoverableMissing))
                continuation.yield(
                    .logLine(
                        "\(badNonContributing.count) file(s) that did not contribute to the parity data are missing or damaged."
                    ))
            }
            continuation.yield(.overallProgress(fraction: 1))
            continuation.yield(.finished(.success(OperationSummary())))
            return
        }

        guard recoverable else {
            if badInSet.count > set.volumes.count {
                let needed = badInSet.count - set.volumes.count
                continuation.yield(.docStatusChanged(.needMoreFiles(count: needed)))
                continuation.yield(
                    .logLine(
                        "Cannot restore: \(badInSet.count) file(s) need recovery but only \(set.volumes.count) parity volume(s) are available."
                    ))
            } else {
                // Enough volumes, but the spec's Vandermonde submatrix is singular for this
                // index combination — a known PAR1/Plank construction flaw, not our bug.
                continuation.yield(.docStatusChanged(.cannotRestore))
                continuation.yield(
                    .logLine(
                        "Cannot restore: this combination of damaged files and parity volumes is not solvable (a PAR1 format limitation)."
                    ))
            }
            continuation.yield(.finished(.success(OperationSummary())))
            return
        }

        guard autoRepair else {
            continuation.yield(.docStatusChanged(.repairNeeded))
            continuation.yield(.logLine("Repair is possible."))
            continuation.yield(.finished(.success(OperationSummary())))
            return
        }

        // ── Repair ──────────────────────────────────────────────────────────────────────
        continuation.yield(.docStatusChanged(.repairing))
        try repair(
            set: set, outcomes: outcomes, decoder: decoder,
            badInSet: badInSet.map(\.offset),
            token: token, continuation: continuation)

        let recoveredAny = !badInSet.isEmpty
        let renamedAny = renamedCount > 0
        let final: DocStatus
        if recoveredAny {
            final = renamedAny ? .restoredWithRenames : .restoredSuccessfully
        } else if badNonContributing.isEmpty {
            final = .allFilesOKWithRenames  // rename-only repair (DocStatus6)
        } else {
            // Renames happened but non-contributing files are still missing (DocStatus14).
            final = .onlyNonRecoverableMissingWithRenames
        }
        continuation.yield(.overallProgress(fraction: 1))
        continuation.yield(.docStatusChanged(final))
        continuation.yield(.finished(.success(OperationSummary())))
    }

    /// Publishes per-file statuses once the set-level verdict (recoverable or not) is known —
    /// PAR1 recoverability is a set-level fact, exactly like the PAR2 path.
    private static func publishStatuses(
        set: Par1SetContext,
        outcomes: [Par1FileOutcome],
        recoverable: Bool,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) {
        for (index, outcome) in outcomes.enumerated() {
            let id = set.rows[index].entry.id
            let status: FileStatus
            switch outcome.state {
            case .ok:
                status = outcome.file.isInParitySet ? .ok : .notInSet
            case .renamed(let from):
                status = .renamed(from: from)
            case .missing:
                status =
                    outcome.file.isInParitySet
                    ? (recoverable ? .recoverableMissing : .unrecoverableMissing)
                    : .unrecoverableMissing
            case .corrupt:
                status =
                    outcome.file.isInParitySet
                    ? (recoverable ? .recoverableCorrupt : .unrecoverableCorrupt)
                    : .unrecoverableCorrupt
            }
            continuation.yield(.fileStatusChanged(id: id, status: status))
        }
    }

    private static func detectRenames(
        set: Par1SetContext,
        outcomes: inout [Par1FileOutcome],
        token: Par1CancelToken
    ) throws {
        guard outcomes.contains(where: { $0.state.needsRecovery }) else { return }
        let rosterNames = Set(set.roster.map { $0.name.lowercased() })
        // An MD5 match implies size equality — never hash a candidate whose size cannot
        // match any bad entry (the folder may hold the multi-GB extracted payload, and
        // grinding through it here looks like a hang). (Phase 8 review)
        let neededSizes = Set(
            outcomes.lazy.filter { $0.state.needsRecovery }.map(\.file.fileSize))
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: set.folder, includingPropertiesForKeys: [.isRegularFileKey])
        else { return }
        var candidateHashes: [(url: URL, md5: MD5Digest)] = []
        for url in entries {
            try token.checkCancelled()
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                !rosterNames.contains(url.lastPathComponent.lowercased()),
                !Par1SetContext.isParArtifact(url),
                let size = fileSize(at: url), neededSizes.contains(size)
            else { continue }
            guard let md5 = try? hashFile(at: url, token: token, onChunk: { _ in }) else {
                continue
            }
            candidateHashes.append((url, md5))
        }
        guard !candidateHashes.isEmpty else { return }
        var claimed = Set<URL>()
        for index in outcomes.indices where outcomes[index].state.needsRecovery {
            if let match = candidateHashes.first(where: {
                $0.md5 == outcomes[index].file.fileMD5 && !claimed.contains($0.url)
            }) {
                claimed.insert(match.url)
                outcomes[index].state = .renamed(from: match.url.lastPathComponent)
            }
        }
    }

    private static func repair(
        set: Par1SetContext,
        outcomes: [Par1FileOutcome],
        decoder: Par1RS.Decoder?,
        badInSet: [Int],
        token: Par1CancelToken,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) throws {
        let manager = FileManager.default

        // Fix faulty filenames first (the original's `par -f`): a rename never destroys
        // data, and a renamed file may serve as an INTACT source for the RS solve below.
        for outcome in outcomes {
            guard case .renamed(let from) = outcome.state else { continue }
            let source = set.folder.appendingPathComponent(from)
            let target = set.folder.appendingPathComponent(outcome.file.name)
            // The target name is bad (missing/corrupt) or this entry would not be renamed;
            // a lingering corrupt file under the roster name moves aside as a .1 backup.
            if manager.fileExists(atPath: target.path) {
                try? manager.moveItem(at: target, to: uniqueBackupURL(for: target))
            }
            do {
                try manager.moveItem(at: source, to: target)
                continuation.yield(
                    .logLine("Renamed \"\(from)\" to \"\(outcome.file.name)\"."))
            } catch {
                continuation.yield(
                    .logLine(
                        "Could not rename \"\(from)\" to \"\(outcome.file.name)\": \(error.localizedDescription)"
                    ))
                throw EngineError.engine(code: 1, message: "rename failed")
            }
        }

        guard let decoder, !badInSet.isEmpty else { return }

        // ANYTHING still occupying a repair target's roster path moves aside as a .1 backup
        // (the PAR2 engine's convention) — corrupt originals, but also e.g. a DIRECTORY
        // squatting on a "missing" file's name, which the recovery writer must never have
        // to delete to land the recovered file. (Phase 8 review: removeItem on a directory
        // is recursive — silent data loss reported as success.)
        for index in badInSet {
            let outcome = outcomes[index]
            let url = set.folder.appendingPathComponent(outcome.file.name)
            if manager.fileExists(atPath: url.path) {
                let backup = uniqueBackupURL(for: url)
                try? manager.moveItem(at: url, to: backup)
                continuation.yield(
                    .logLine(
                        "Moved the damaged \"\(outcome.file.name)\" aside as \"\(backup.lastPathComponent)\"."
                    ))
            }
        }

        // Sources: intact in-set files (per the decoder's positions) and the used volumes.
        // Everything streams in chunks against the ONE inverted matrix.
        let inSetFiles = outcomes.filter { $0.file.isInParitySet }
        let paddedSize = inSetFiles.map(\.file.fileSize).max() ?? 0
        var intactReaders: [Int: Par1ChunkReader] = [:]
        var position = 0
        for outcome in inSetFiles {
            position += 1
            if !outcome.state.needsRecovery {
                let name = outcome.file.name  // post-rename, roster names are on disk
                intactReaders[position] = try Par1ChunkReader(
                    url: set.folder.appendingPathComponent(name),
                    dataOffset: 0, dataSize: outcome.file.fileSize, paddedSize: paddedSize)
            }
        }
        var volumeReaders: [Int: Par1ChunkReader] = [:]
        for volume in set.volumes where decoder.usedVolumes.contains(volume.number) {
            volumeReaders[volume.number] = try Par1ChunkReader(
                url: volume.url, dataOffset: volume.dataOffset, dataSize: volume.dataSize,
                paddedSize: paddedSize)
        }

        let targets = badInSet.map { outcomes[$0].file }
        let writers = try targets.map { file in
            try Par1RecoveryWriter(
                finalURL: set.folder.appendingPathComponent(file.name),
                size: file.fileSize, expectedMD5: file.fileMD5)
        }
        defer { for writer in writers { writer.discardIfUnfinished() } }

        var offset: UInt64 = 0
        while offset < paddedSize {
            try token.checkCancelled()
            let length = Int(min(UInt64(chunkSize), paddedSize - offset))
            var intactChunks: [Int: [UInt8]] = [:]
            for (pos, reader) in intactReaders {
                intactChunks[pos] = try reader.readChunk(length: length)
            }
            var volumeChunks: [Int: [UInt8]] = [:]
            for (number, reader) in volumeReaders {
                volumeChunks[number] = try reader.readChunk(length: length)
            }
            guard
                let recovered = decoder.recoverChunk(
                    intactChunks: intactChunks, volumeChunks: volumeChunks, chunkSize: length)
            else {
                throw EngineError.engine(code: 2, message: "recovery chunk failed")
            }
            for (writer, chunk) in zip(writers, recovered) {
                try writer.append(chunk)
            }
            offset += UInt64(length)
            continuation.yield(
                .overallProgress(fraction: 0.5 + Double(offset) / Double(max(1, paddedSize)) * 0.5))
        }

        for (writer, file) in zip(writers, targets) {
            guard writer.finish() else {
                continuation.yield(
                    .docStatusChanged(.cannotRestore))
                continuation.yield(
                    .logLine(
                        "Recovered data for \"\(file.name)\" failed its checksum — the parity volumes do not match these files."
                    ))
                throw EngineError.engine(code: 3, message: "recovered data failed verification")
            }
            continuation.yield(.logLine("Restored \"\(file.name)\"."))
        }
        for index in badInSet {
            continuation.yield(
                .fileStatusChanged(id: set.rows[index].entry.id, status: .recovered))
        }
    }

    // MARK: - Hashing / small helpers

    private static func hashFile(
        at url: URL, token: Par1CancelToken, onChunk: (Int) -> Void
    ) throws -> MD5Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while true {
            try token.checkCancelled()
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            hasher.update(data: data)
            onChunk(data.count)
        }
        return MD5Digest(bytes: Data(hasher.finalize()))!
    }

    private static func fileSize(at url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true, let size = values.fileSize
        else { return nil }
        return UInt64(size)
    }

    /// `name.1`, `name.2`, … — the PAR2 engine's damaged-file backup convention.
    private static func uniqueBackupURL(for url: URL) -> URL {
        var counter = 1
        while true {
            let candidate = url.appendingPathExtension("\(counter)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}

// MARK: - Set context (index + discovered volumes)

/// Everything the engine learned from the anchor and the folder scan: the roster (from the
/// anchor — index and volumes carry the identical file list) and the set's usable parity
/// volumes, matched by SET HASH so renamed volume files still count. Emits the Pnn
/// introspection log lines (the original's `PxxFileStatus` vocabulary) as it scans.
private struct Par1SetContext {
    struct Volume {
        let url: URL
        let number: Int
        let dataOffset: UInt64
        let dataSize: UInt64
    }
    struct Row {
        let entry: FileEntry
    }

    let folder: URL
    let roster: [Par1FileEntry]
    let rows: [Row]
    let volumes: [Volume]

    init(anchor: URL, continuation: AsyncStream<EngineEvent>.Continuation) throws {
        let anchorData = try Data(contentsOf: anchor)
        let archive = try Par1Parser.parse(anchorData)
        guard archive.controlHashVerified || archive.setHashVerified else {
            continuation.yield(.docStatusChanged(.notValid))
            continuation.yield(
                .logLine("The PAR file's control hash does not match — the file is damaged."))
            throw EngineError.launchFailed("damaged PAR1 index")
        }
        self.folder = anchor.deletingLastPathComponent()
        self.roster = archive.files
        self.rows = archive.files.enumerated().map { index, file in
            var indexLE = Data(count: 8)
            for i in 0..<8 {
                indexLE[i] = UInt8(truncatingIfNeeded: UInt64(index) >> (8 * UInt64(i)))
            }
            let rowID = MD5Digest.hash(parts: [file.fileMD5.bytes, Data(file.name.utf8), indexLE])
            return Row(
                entry: FileEntry(
                    id: rowID.uuid, name: file.name, sizeBytes: file.fileSize,
                    status: file.isInParitySet ? .pending : .notInSet))
        }

        // Volume discovery: every PAR1-looking sibling whose SET HASH matches, probed by
        // STREAMING (header read + chunked control-hash MD5) — a volume's data area is the
        // size of the largest protected file, and loading every sibling whole spikes memory
        // by gigabytes on big sets. The volume's file list is never needed (the anchor's
        // roster rules). (Phase 8 review)
        let largest = archive.filesInParitySet.map(\.fileSize).max() ?? 0
        var found: [Volume] = []
        var seenNumbers = Set<Int>()
        let siblings =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for url in siblings.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard Par1SetContext.isParArtifact(url),
                let probe = Par1SetContext.probeVolume(at: url, expectedSetHash: archive.setHash)
            else { continue }
            let name = url.lastPathComponent
            guard probe.volumeNumber > 0 else { continue }  // the index itself
            // volumeNumber is an UNTRUSTED 64-bit header field: PAR1 caps total entities at
            // 255, so anything above is invalid — and converting it unchecked would trap
            // (and a huge-but-fitting value would overflow the Vandermonde exponent).
            // (Phase 8 review)
            guard probe.volumeNumber <= UInt64(Par1RS.maxEntities) else {
                continuation.yield(.logLine("\(name): invalid volume number — ignored."))
                continue
            }
            guard probe.controlHashVerified else {
                continuation.yield(.logLine("\(name): damaged parity volume — ignored."))
                continue
            }
            guard probe.dataSize >= largest else {
                // PxxFileStatus2: a volume whose data area cannot cover the files.
                continuation.yield(.logLine("\(name): contains no recovery blocks — ignored."))
                continue
            }
            let number = Int(probe.volumeNumber)
            guard seenNumbers.insert(number).inserted else {
                // PxxFileStatus3: same parity twice helps nobody.
                continuation.yield(
                    .logLine("\(name): contains duplicate recovery blocks — ignored."))
                continue
            }
            // PxxFileStatus4/5: a PAR1 volume carries exactly one recovery block (its row of
            // the Vandermonde system) covering every in-set file.
            continuation.yield(
                .logLine(
                    "\(name): valid parity volume #\(number) — contains 1 recovery block for \(archive.filesInParitySet.count) file(s)."
                ))
            found.append(
                Volume(
                    url: url, number: number, dataOffset: probe.dataOffset,
                    dataSize: probe.dataSize))
        }
        self.volumes = found
    }

    struct VolumeProbe {
        let volumeNumber: UInt64
        let dataOffset: UInt64
        let dataSize: UInt64
        let controlHashVerified: Bool
    }

    /// Header-level volume probe at O(chunk) memory: rejects on magic/version/set-hash
    /// BEFORE the control-hash pass, which streams MD5 over bytes 0x20..EOF in chunks. The
    /// declared data area must also fit the actual file — a lying header would otherwise
    /// surface as a mid-repair short read.
    static func probeVolume(at url: URL, expectedSetHash: MD5Digest) -> VolumeProbe? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let raw = try? handle.read(upToCount: Par1Parser.headerLength),
            raw.count == Par1Parser.headerLength
        else { return nil }
        let header = Data(raw)
        guard header.field(at: 0, count: 8) == Par1Parser.magic,
            header.leUInt32(at: 0x08) == Par1Parser.version1,
            let storedControl = header.field(at: 0x10, count: 16).flatMap(MD5Digest.init),
            let setHash = header.field(at: 0x20, count: 16).flatMap(MD5Digest.init),
            setHash == expectedSetHash,
            let volumeNumber = header.leUInt64(at: 0x30),
            let dataOffset = header.leUInt64(at: 0x50),
            let dataSize = header.leUInt64(at: 0x58)
        else { return nil }
        guard let actualSize = try? handle.seekToEnd(),
            dataOffset <= actualSize, dataSize <= actualSize - dataOffset
        else { return nil }

        var hasher = Insecure.MD5()
        hasher.update(data: header[header.index(header.startIndex, offsetBy: 0x20)...])
        guard (try? handle.seek(toOffset: UInt64(Par1Parser.headerLength))) != nil else {
            return nil
        }
        while let chunk = try? handle.read(upToCount: Par1Engine.chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let verified = MD5Digest(bytes: Data(hasher.finalize()))! == storedControl
        return VolumeProbe(
            volumeNumber: volumeNumber, dataOffset: dataOffset, dataSize: dataSize,
            controlHashVerified: verified)
    }

    /// `.par`, `.pNN`, `.qNN` — PAR1 artifacts never count as data-file rename candidates.
    static func isParArtifact(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "par" { return true }
        guard ext.count == 3, let first = ext.first, first == "p" || first == "q" else {
            return false
        }
        return ext.dropFirst().allSatisfy(\.isNumber)
    }
}

// MARK: - Per-file outcome

private struct Par1FileOutcome {
    enum State {
        case ok
        case missing
        case corrupt
        case renamed(from: String)

        var needsRecovery: Bool {
            switch self {
            case .missing, .corrupt: return true
            case .ok, .renamed: return false
            }
        }
        var isRenamed: Bool {
            if case .renamed = self { return true }
            return false
        }
    }

    let file: Par1FileEntry
    var state: State
}

// MARK: - Chunked I/O

/// Reads a (possibly padded) data region in fixed chunks: file bytes while they last, zeros
/// beyond — PAR1 pads every in-set file to the largest for the byte-parallel RS math.
final class Par1ChunkReader {
    private let handle: FileHandle
    private let dataSize: UInt64
    private var position: UInt64 = 0

    init(url: URL, dataOffset: UInt64, dataSize: UInt64, paddedSize: UInt64) throws {
        self.handle = try FileHandle(forReadingFrom: url)
        self.dataSize = dataSize
        if dataOffset > 0 { try handle.seek(toOffset: dataOffset) }
    }

    deinit { try? handle.close() }

    func readChunk(length: Int) throws -> [UInt8] {
        var chunk = [UInt8](repeating: 0, count: length)
        let remaining = position < dataSize ? dataSize - position : 0
        let toRead = Int(min(UInt64(length), remaining))
        if toRead > 0 {
            guard let data = try handle.read(upToCount: toRead), data.count == toRead else {
                throw EngineError.engine(code: 4, message: "short read from a source file")
            }
            chunk.replaceSubrange(0..<toRead, with: data)
        }
        position += UInt64(length)
        return chunk
    }
}

/// Writes a recovered file to a temporary sibling, hashing as it goes; `finish()` verifies
/// the roster MD5 and moves it into place atomically. An unfinished writer leaves nothing
/// behind — a failed repair never deposits half a file under the real name.
private final class Par1RecoveryWriter {
    private let finalURL: URL
    private let tempURL: URL
    private let size: UInt64
    private let expectedMD5: MD5Digest
    private var hasher = Insecure.MD5()
    private var written: UInt64 = 0
    private var handle: FileHandle
    private var finished = false

    init(finalURL: URL, size: UInt64, expectedMD5: MD5Digest) throws {
        self.finalURL = finalURL
        self.tempURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".modernpar-recover-\(UUID().uuidString.prefix(8))")
        self.size = size
        self.expectedMD5 = expectedMD5
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: tempURL)
    }

    /// Appends a recovered chunk, clipping the zero padding past the roster size.
    func append(_ chunk: [UInt8]) throws {
        guard written < size else { return }
        let take = Int(min(UInt64(chunk.count), size - written))
        let data = Data(chunk[0..<take])
        try handle.write(contentsOf: data)
        hasher.update(data: data)
        written += UInt64(take)
    }

    /// True when the recovered bytes hash to the roster MD5 and the move succeeded.
    func finish() -> Bool {
        try? handle.close()
        let md5 = MD5Digest(bytes: Data(hasher.finalize()))!
        guard written == size, md5 == expectedMD5 else {
            try? FileManager.default.removeItem(at: tempURL)
            finished = true
            return false
        }
        do {
            // The repair pass moved every occupant aside already; anything that appeared
            // since moves aside too — NEVER removeItem here (recursive on a directory).
            // (Phase 8 review)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                var counter = 1
                var backup = finalURL.appendingPathExtension("\(counter)")
                while FileManager.default.fileExists(atPath: backup.path) {
                    counter += 1
                    backup = finalURL.appendingPathExtension("\(counter)")
                }
                try FileManager.default.moveItem(at: finalURL, to: backup)
            }
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
            finished = true
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            finished = true
            return false
        }
    }

    func discardIfUnfinished() {
        guard !finished else { return }
        try? handle.close()
        try? FileManager.default.removeItem(at: tempURL)
    }
}

// MARK: - Cancellation

final class Par1CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }
}
