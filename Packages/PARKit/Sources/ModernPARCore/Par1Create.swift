import CryptoKit
import Foundation

/// Native PAR1 authoring — the half of the format MacPAR deLuxe could only do through its
/// Intel helper. Wire format pinned against that binary's output (the golden corpus):
/// the index sorts files lexicographically, every authored file contributes (status 0x1 —
/// the original could PROCESS non-contributing sets but not create them), volume data areas
/// are sized to the LARGEST ROSTER FILE, volumes are lowercase `.p01`…, and the parity bytes
/// are the `Par1RS` Vandermonde rows (byte-identical to the Intel binary for identical
/// inputs). (ROADMAP Phase 8; docs/research/03 §6)
public struct Par1CreateEngine: Par2Creator, Sendable {
    public init() {}

    /// Our program id in the version field's high dword (the Intel par wrote 0x02000900).
    static let clientID: UInt32 = 0x4D6F_5061  // "MoPa"

    private static let queue = DispatchQueue(
        label: "org.modernpar.par1-create", qos: .userInitiated)

    public func create(_ request: CreateRequest) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let token = Par1CancelToken()
            continuation.onTermination = { _ in token.cancel() }
            Self.queue.async {
                EngineDrainRegistry.shared.enter()
                defer { EngineDrainRegistry.shared.leave() }
                Self.execute(request: request, token: token, continuation: continuation)
                continuation.finish()
            }
        }
    }

    // MARK: - Blocking drive (engine queue)

    private static func execute(
        request: CreateRequest,
        token: Par1CancelToken,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) {
        guard let volumeCount = request.par1VolumeCount else {
            continuation.yield(.finished(.failure(.notImplemented)))
            return
        }
        var scopeStops: [URL] = []
        defer { for url in scopeStops { url.stopAccessingSecurityScopedResource() } }
        if let data = request.folderBookmark, let folder = try? ScopedAccess.resolve(data),
            folder.didStart
        {
            scopeStops.append(folder.url)
        }

        // Targets: the index, then lowercase .pNN volumes beside it. PAR1 caps the volume
        // count at 99 (.p01–.p99); the model validates, the engine re-guards.
        let parFile = request.parFile
        let stem = parFile.deletingPathExtension()
        guard (0...99).contains(volumeCount),
            !request.files.isEmpty, request.files.count <= 255,
            request.files.count + volumeCount <= Par1RS.maxEntities
        else {
            continuation.yield(.docStatusChanged(.createFailed))
            continuation.yield(
                .logLine("A PAR1 set allows at most 255 files plus parity volumes (99 max)."))
            continuation.yield(.finished(.failure(.launchFailed("PAR1 limits exceeded"))))
            return
        }
        var targets = [parFile]
        for v in 1...max(1, volumeCount) where volumeCount > 0 {
            targets.append(stem.appendingPathExtension(String(format: "p%02d", v)))
        }
        // Never overwrite — the PAR2 engine's posture ("File already exists"), kept here.
        for target in targets where FileManager.default.fileExists(atPath: target.path) {
            continuation.yield(.docStatusChanged(.createFailed))
            continuation.yield(.logLine("File already exists: \(target.lastPathComponent)"))
            continuation.yield(.finished(.failure(.launchFailed("output already exists"))))
            return
        }

        // The index sorts lexicographically regardless of how files were handed over —
        // coefficient indices follow this order, so it is part of the wire format.
        let sources = request.files.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var created: [URL] = []
        do {
            try author(
                sources: sources, volumeCount: volumeCount, parFile: parFile, targets: targets,
                created: &created, token: token, continuation: continuation)
            continuation.yield(.extractionPlaced(parFile))
            continuation.yield(.overallProgress(fraction: 1))
            continuation.yield(.docStatusChanged(.createdSuccessfully))
            continuation.yield(.finished(.success(OperationSummary())))
        } catch {
            // A cancelled or failed create never leaves partial output behind — but it
            // removes ONLY what it created. The hash phase can run for minutes before the
            // first byte is written, and a file the user dropped on a target path in that
            // window is theirs, not ours. (Phase 8 review)
            for target in created {
                try? FileManager.default.removeItem(at: target)
            }
            if error is CancellationError {
                continuation.yield(.finished(.failure(.cancelled)))
            } else {
                continuation.yield(.docStatusChanged(.createFailed))
                continuation.yield(
                    .logLine("Could not create the PAR1 set: \(error.localizedDescription)"))
                continuation.yield(
                    .finished(
                        .failure(.engine(code: 10, message: "PAR1 create failed"))))
            }
        }
    }

    private struct SourceFile {
        let url: URL
        let name: String
        let size: UInt64
        let md5: MD5Digest
        let md5of16k: MD5Digest
    }

    private static func author(
        sources: [URL],
        volumeCount: Int,
        parFile: URL,
        targets: [URL],
        created: inout [URL],
        token: Par1CancelToken,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) throws {
        // ── Hash phase ──────────────────────────────────────────────────────────────────
        continuation.yield(.docStatusChanged(.creating))
        var files: [SourceFile] = []
        var rows: [FileEntry] = []
        let totalBytes = max(
            1,
            sources.reduce(UInt64(0)) { sum, url in
                sum &+ (UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            })
        var hashed: UInt64 = 0
        for url in sources {
            try token.checkCancelled()
            let (size, md5, md5of16k) = try hashSource(at: url, token: token) { bytes in
                hashed &+= UInt64(bytes)
                continuation.yield(
                    .overallProgress(fraction: Double(hashed) / Double(totalBytes) * 0.4))
            }
            let name = url.lastPathComponent
            files.append(.init(url: url, name: name, size: size, md5: md5, md5of16k: md5of16k))
            rows.append(FileEntry(name: name, sizeBytes: size, status: .ok))
        }
        continuation.yield(.scanningStarted(totalFiles: files.count))
        continuation.yield(.filesDiscovered(rows))

        // ── Wire bytes shared by index and volumes ──────────────────────────────────────
        let fileList = makeFileList(files)
        let setHash = MD5Digest.hash(parts: files.map(\.md5.bytes))
        let paddedSize = files.map(\.size).max() ?? 0
        let dataOffset = UInt64(0x60 + fileList.count)

        func header(volume: UInt64, dataSize: UInt64) -> Data {
            var data = Data()
            data.append(Data([0x50, 0x41, 0x52, 0, 0, 0, 0, 0]))  // "PAR\0\0\0\0\0"
            data.appendLEUInt32(0x0001_0000)  // version 1.0
            data.appendLEUInt32(clientID)
            data.append(Data(count: 16))  // control hash patched after streaming
            data.append(setHash.bytes)
            data.appendLEUInt64(volume)
            data.appendLEUInt64(UInt64(files.count))
            data.appendLEUInt64(0x60)  // file list directly after the header
            data.appendLEUInt64(UInt64(fileList.count))
            data.appendLEUInt64(dataOffset)
            data.appendLEUInt64(dataSize)
            return data
        }

        // ── Index ───────────────────────────────────────────────────────────────────────
        // Empty data area (no comment) — dataOffset still points past the list.
        try writeArtifact(
            to: parFile, header: header(volume: 0, dataSize: 0), fileList: fileList,
            parityChunks: nil, token: token)
        created.append(parFile)

        guard volumeCount > 0 else { return }

        // ── Volumes ─────────────────────────────────────────────────────────────────────
        // Parity streams chunk-wise: every volume file is written in one pass while its
        // control hash accumulates; the hash field is patched at the end.
        var readers: [Par1ChunkReader] = []
        for file in files {
            readers.append(
                try Par1ChunkReader(
                    url: file.url, dataOffset: 0, dataSize: file.size, paddedSize: paddedSize))
        }
        var writers: [Par1ArtifactWriter] = []
        defer { for writer in writers { writer.discardIfUnfinished() } }
        for v in 1...volumeCount {
            writers.append(
                try Par1ArtifactWriter(
                    finalURL: targets[v],
                    header: header(volume: UInt64(v), dataSize: paddedSize),
                    fileList: fileList))
            created.append(targets[v])
        }

        // Coefficient product rows precompute once — they are constant across chunks.
        let coefficients = (1...volumeCount).map { v in
            (1...files.count).map { j in Par1RS.coefficient(volume: v, fileIndex: j) }
        }

        var offset: UInt64 = 0
        while offset < paddedSize {
            try token.checkCancelled()
            let length = Int(min(UInt64(Par1Engine.chunkSize), paddedSize - offset))
            let chunks = try readers.map { try $0.readChunk(length: length) }
            for (vIndex, writer) in writers.enumerated() {
                var parity = [UInt8](repeating: 0, count: length)
                for (jIndex, chunk) in chunks.enumerated() {
                    GF256.accumulate(
                        &parity, src: chunk, coefficient: coefficients[vIndex][jIndex])
                }
                try writer.appendParity(parity)
            }
            offset += UInt64(length)
            continuation.yield(
                .overallProgress(
                    fraction: 0.4 + Double(offset) / Double(max(1, paddedSize)) * 0.6))
        }
        for (v, writer) in writers.enumerated() {
            try writer.finish()
            continuation.yield(.logLine("Wrote \(targets[v + 1].lastPathComponent)."))
        }
    }

    /// One streamed pass per source: full-file MD5, first-16k MD5, and the byte size.
    private static func hashSource(
        at url: URL, token: Par1CancelToken, onChunk: (Int) -> Void
    ) throws -> (UInt64, MD5Digest, MD5Digest) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var full = Insecure.MD5()
        var head = Insecure.MD5()
        var headRemaining = 16 * 1024
        var size: UInt64 = 0
        while true {
            try token.checkCancelled()
            guard let data = try handle.read(upToCount: Par1Engine.chunkSize), !data.isEmpty
            else { break }
            full.update(data: data)
            if headRemaining > 0 {
                let take = min(headRemaining, data.count)
                head.update(data: data.prefix(take))
                headRemaining -= take
            }
            size &+= UInt64(data.count)
            onChunk(data.count)
        }
        return (
            size,
            MD5Digest(bytes: Data(full.finalize()))!,
            MD5Digest(bytes: Data(head.finalize()))!
        )
    }

    private static func makeFileList(_ files: [SourceFile]) -> Data {
        var list = Data()
        for file in files {
            let nameBytes = file.name.data(using: .utf16LittleEndian) ?? Data()
            list.appendLEUInt64(UInt64(0x38 + nameBytes.count))
            list.appendLEUInt64(0x1)  // status: contributes to parity (the only kind we author)
            list.appendLEUInt64(file.size)
            list.append(file.md5.bytes)
            list.append(file.md5of16k.bytes)
            list.append(nameBytes)
        }
        return list
    }

    /// Writes header + list (+ optional parity) and patches the control hash (MD5 of bytes
    /// 0x20..EOF) once everything streamed through.
    private static func writeArtifact(
        to url: URL, header: Data, fileList: Data, parityChunks: [[UInt8]]?,
        token: Par1CancelToken
    ) throws {
        let writer = try Par1ArtifactWriter(finalURL: url, header: header, fileList: fileList)
        if let parityChunks {
            for chunk in parityChunks {
                try token.checkCancelled()
                try writer.appendParity(chunk)
            }
        }
        try writer.finish()
    }
}

/// Streams one PAR1 artifact: header + file list immediately, parity appended chunk-wise,
/// control hash (bytes 0x20..EOF) patched into offset 0x10 on finish. Unfinished writers
/// remove their file — a cancelled create leaves nothing behind.
private final class Par1ArtifactWriter {
    private let url: URL
    private let handle: FileHandle
    private var hasher = Insecure.MD5()
    private var finished = false

    init(finalURL: URL, header: Data, fileList: Data) throws {
        precondition(header.count == 0x60, "PAR1 header must be 0x60 bytes")
        self.url = finalURL
        // EXCLUSIVE creation: a file that appeared at this path since the up-front
        // overwrite check belongs to someone else — fail the run rather than truncate it.
        // (Phase 8 review: the hash phase leaves a long check-then-act window.)
        do {
            try Data().write(to: finalURL, options: .withoutOverwriting)
        } catch {
            throw EngineError.launchFailed("File already exists: \(finalURL.lastPathComponent)")
        }
        self.handle = try FileHandle(forWritingTo: finalURL)
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: fileList)
        // The control hash covers everything from the set hash (0x20) onward.
        hasher.update(data: header[header.index(header.startIndex, offsetBy: 0x20)...])
        hasher.update(data: fileList)
    }

    func appendParity(_ chunk: [UInt8]) throws {
        let data = Data(chunk)
        try handle.write(contentsOf: data)
        hasher.update(data: data)
    }

    func finish() throws {
        let digest = Data(hasher.finalize())
        try handle.seek(toOffset: 0x10)
        try handle.write(contentsOf: digest)
        try handle.close()
        finished = true
    }

    func discardIfUnfinished() {
        guard !finished else { return }
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

extension Data {
    fileprivate mutating func appendLEUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    fileprivate mutating func appendLEUInt64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
