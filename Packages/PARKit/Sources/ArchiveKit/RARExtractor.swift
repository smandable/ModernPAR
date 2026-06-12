import CUnrar
import Foundation
import ModernPARCore

/// RAR extraction through the in-process RARLAB UnRAR engine (CUnrar) — no CLI is ever spawned.
/// (ARCHITECTURE.md §1.4; ROADMAP Phase 4)
///
/// Shape mirrors `EmbeddedEngine`: `extract` starts immediately (hot stream — consume promptly),
/// the blocking engine drive runs on a private serial queue (the UnRAR DLL surface keeps
/// process-global state, so RAR operations must never overlap in-process), and cancelling the
/// consuming task trips the token that the shim's callbacks poll.
///
/// The operation is a two-pass design:
///  1. LIST pass — entry roster (names/sizes for the table and the progress denominator).
///  2. EXTRACT pass — into a fresh hidden staging folder inside the destination, then the
///     output is moved into place per the single-item/multi-item rule and the conflict policy.
///     Staging means a cancelled or failed run never leaves half-written output mixed into the
///     user's folder, and "keep both" is a simple rename.
public final class RARExtractor: ArchiveExtractor, Sendable {
    public init() {}

    /// All RAR runs serialize here — see the type comment.
    private static let queue = DispatchQueue(
        label: "org.modernpar.unrar-engine", qos: .userInitiated)

    public func extract(
        _ archive: SessionRoute,
        options: ExtractOptions,
        password: any PasswordProvider,
        conflicts: any ConflictResolver
    ) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let token = ExtractCancelToken()
            continuation.onTermination = { _ in token.cancel() }
            Self.queue.async {
                // Quit gating: the run owns its staging folder until execute's defers finish,
                // even after the owning session was cancelled/closed.
                EngineDrainRegistry.shared.enter()
                defer { EngineDrainRegistry.shared.leave() }
                Self.execute(
                    route: archive, options: options, password: password,
                    conflicts: conflicts,
                    token: token, continuation: continuation)
                continuation.finish()
            }
        }
    }

    // MARK: - Blocking engine drive (engine queue)

    private static func execute(
        route: SessionRoute,
        options: ExtractOptions,
        password: any PasswordProvider,
        conflicts: any ConflictResolver,
        token: ExtractCancelToken,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) {
        let destination = options.destination
        let keepBroken = options.keepBrokenFiles
        guard route.mode == .extractArchive else {
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
                .finished(.failure(.launchFailed("session has no archive bookmark"))))
            return
        }

        let firstVolume = RARVolumes.firstVolume(for: anchor)
        if firstVolume != anchor {
            continuation.yield(
                .logLine("Opening the set from its first volume: \(firstVolume.lastPathComponent)"))
        }
        // Starting mid-set would silently skip every file that begins in the absent first
        // volume and then report success — fail fast and name what's missing instead.
        if let missingFirst = RARVolumes.missingFirstVolumeName(for: firstVolume) {
            continuation.yield(
                .logLine("The set's first volume (\(missingFirst)) is missing — cannot start."))
            continuation.yield(.finished(.failure(.volumeMissing(missingFirst))))
            return
        }

        let destFolder: URL
        switch destination {
        case .besideArchive:
            destFolder = firstVolume.deletingLastPathComponent()
        case .fixed(let bookmark):
            // A STALE bookmark means the chosen folder moved — typically into the Trash,
            // which the bookmark silently follows (file-ID resolution). Honor the documented
            // contract instead: a missing-or-moved fixed destination degrades to
            // beside-the-archive, visibly. (Phase 7 review)
            if let resolved = try? ScopedAccess.resolve(bookmark), !resolved.isStale {
                if resolved.didStart { scopeStops.append(resolved.url) }
                destFolder = resolved.url
            } else {
                continuation.yield(
                    .logLine(
                        "The configured destination folder is unavailable or has moved — extracting beside the archive instead."
                    ))
                destFolder = firstVolume.deletingLastPathComponent()
            }
        case .ask:
            // The UI resolves "ask" to a concrete folder before starting the engine.
            continuation.yield(
                .finished(
                    .failure(.launchFailed("destination must be chosen before extraction starts"))))
            return
        }

        let archiveBase = RARVolumes.baseName(for: firstVolume)
        let broker = PasswordBroker(provider: password, token: token, archiveName: archiveBase)

        // ── Pass 1: list ────────────────────────────────────────────────────────────────
        let collector = ListCollector(broker: broker, token: token)
        var archiveFlags: UInt32 = 0
        let listResult = listArchive(at: firstVolume, collector: collector, flags: &archiveFlags)
        let encryptedHeaders = archiveFlags & UInt32(UNRARSHIM_FLAG_ENCHEADERS) != 0
        guard listResult == UNRARSHIM_SUCCESS, !token.isCancelled else {
            let error = mappedError(
                code: token.isCancelled ? UNRARSHIM_CANCELLED : listResult,
                missingVolume: collector.missingVolume,
                passwordWasConsulted: broker.wasConsulted,
                wrongPasswordLikely: encryptedHeaders)
            yieldExtractFailure(error, continuation: continuation)
            return
        }

        let entries = collector.collected
        // Legacy-codepage names (pre-RAR5 headers without a Unicode variant whose raw bytes
        // are not UTF-8): resolve the decode once per run — possibly prompting through the
        // run's encoding picker — and redirect those entries to decoded paths in staging.
        // Valid-UTF-8 names and RAR5 archives produce an empty plan. (ROADMAP Phase 7)
        let decodePlan = LegacyFilenameDecoder.plan(
            for: entries, preference: options.filenameEncoding, picker: options.encodingPicker,
            token: token, continuation: continuation)
        if token.isCancelled {
            continuation.yield(.finished(.failure(.cancelled)))
            return
        }

        // Rows and outcome bookkeeping key on the archive-order entry index (the shim's
        // entry_index): legacy mangled names collide or come out empty, so names cannot
        // identify entries. Rows display the decoded name where one applies.
        var rows: [FileEntry] = []
        var rowsByIndex: [Int: ExtractRowRef] = [:]
        var legacyEncryptedIndices: Set<Int> = []
        // Hostile headers can declare absurd sizes; the sum is only a progress denominator,
        // so saturate instead of trapping the whole app.
        var totalBytes: UInt64 = 0
        for (index, entry) in entries.enumerated() where !entry.isDirectory {
            let row = FileEntry(
                name: decodePlan.relativePaths[index] ?? entry.name,
                sizeBytes: entry.unpackedSize)
            rows.append(row)
            rowsByIndex[index] = ExtractRowRef(id: row.id, name: row.name)
            // The wrong-password heuristic only applies to pre-RAR5 entries: RAR5 stores a
            // password check value, so its BAD_DATA with a working password IS data damage.
            if entry.isEncrypted && entry.unpVersion < 50 { legacyEncryptedIndices.insert(index) }
            let (sum, overflow) = totalBytes.addingReportingOverflow(entry.unpackedSize)
            totalBytes = overflow ? UInt64.max : sum
        }

        continuation.yield(.scanningStarted(totalFiles: rows.count))
        continuation.yield(.filesDiscovered(rows))
        continuation.yield(.docStatusChanged(.extracting))
        describeArchive(
            flags: archiveFlags, fileCount: rows.count, totalBytes: totalBytes,
            continuation: continuation)

        // ── Pass 2: extract into staging ────────────────────────────────────────────────
        ExtractPlacement.sweepStaleStaging(in: destFolder)
        let staging: URL
        do {
            staging = try ExtractPlacement.makeStaging(in: destFolder)
        } catch {
            yieldExtractFailure(
                .engine(
                    code: Int32(UNRARSHIM_CREATE_ERROR.rawValue),
                    message:
                        "Could not create a working folder in \(destFolder.lastPathComponent): \(error.localizedDescription)"
                ), continuation: continuation)
            return
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let bridge = ExtractBridge(
            continuation: continuation, idsByName: [:], legacyEncryptedNames: [],
            totalBytes: totalBytes, broker: broker, token: token,
            rowsByIndex: rowsByIndex, legacyEncryptedIndices: legacyEncryptedIndices,
            // Decoded redirects become absolute now that the staging folder exists.
            overridePathsByIndex: decodePlan.relativePaths.mapValues {
                staging.appendingPathComponent($0).path
            })
        let result = extractArchive(
            at: firstVolume, into: staging, keepBroken: keepBroken, bridge: bridge)

        // ── Terminal handling ───────────────────────────────────────────────────────────
        let aborted =
            token.isCancelled || result == UNRARSHIM_CANCELLED
            || result == UNRARSHIM_MISSING_PASSWORD || result == UNRARSHIM_VOLUME_MISSING
        let isPerFileFailure =
            result == UNRARSHIM_BAD_DATA || result == UNRARSHIM_BAD_PASSWORD
            || result == UNRARSHIM_LARGE_DICT
        let completedLoop = result == UNRARSHIM_SUCCESS || isPerFileFailure
        let terminalError: EngineError? =
            (result == UNRARSHIM_SUCCESS && !token.isCancelled)
            ? nil
            : mappedError(
                code: token.isCancelled ? UNRARSHIM_CANCELLED : result,
                missingVolume: bridge.missingVolume ?? collector.missingVolume,
                passwordWasConsulted: broker.wasConsulted,
                wrongPasswordLikely: bridge.failuresLookLikeWrongPassword)
        // A wrong-password run must not deliver output: the UI re-prompts and re-runs, and
        // this run's leftovers would collide with the retry (plus "placed" looks like success).
        let placementAllowed = !aborted && completedLoop && terminalError != .badPassword

        if placementAllowed {
            switch ExtractPlacement.place(
                staging: staging, destFolder: destFolder, fallbackName: archiveBase,
                isReservedTarget: { RARVolumes.belongsToSet($0, firstVolume: firstVolume) },
                conflicts: ConflictBroker(resolver: conflicts, token: token),
                continuation: continuation)
            {
            case .placed(let url):
                continuation.yield(.extractionPlaced(url))
                continuation.yield(.logLine("Extracted to \(url.path)"))
                if bridge.skipped > 0 {
                    continuation.yield(
                        .logLine(
                            "\(bridge.skipped) entr\(bridge.skipped == 1 ? "y" : "ies") skipped (links or unsupported entries)."
                        ))
                }
                if let terminalError {
                    continuation.yield(
                        .logLine(
                            "Extracted \(bridge.succeeded) of \(rows.count) file(s); \(bridge.failed) failed."
                        ))
                    yieldExtractFailure(terminalError, continuation: continuation)
                } else {
                    // Warning-class skips (e.g. unsafe symlinks) leave the run "successful"
                    // but PARTIALLY delivered — the volumes must survive so the user can
                    // extract the rest elsewhere. (Phase 7 review)
                    if bridge.skipped == 0 {
                        disposeSegments(
                            options.segmentDisposal, firstVolume: firstVolume,
                            visitedVolumes: bridge.visitedVolumes, placedOutput: url,
                            continuation: continuation)
                    } else if options.segmentDisposal != .leave {
                        continuation.yield(
                            .logLine(
                                "Leaving the archive segments in place — not every entry was extracted."
                            ))
                    }
                    continuation.yield(.docStatusChanged(.extractedSuccessfully))
                    continuation.yield(.finished(.success(OperationSummary())))
                }
                return
            case .cancelledByUser:
                continuation.yield(.logLine("Extraction cancelled at the destination conflict."))
                continuation.yield(.finished(.failure(.cancelled)))
                return
            case .nothingToPlace:
                if terminalError == nil {
                    // An archive of empty directories (or no entries) still "succeeds" —
                    // but if entries were SKIPPED, the user received nothing of substance
                    // and the volumes are their only copy: never dispose. (Phase 7 review)
                    if bridge.skipped == 0 {
                        disposeSegments(
                            options.segmentDisposal, firstVolume: firstVolume,
                            visitedVolumes: bridge.visitedVolumes, placedOutput: nil,
                            continuation: continuation)
                    } else if options.segmentDisposal != .leave {
                        continuation.yield(
                            .logLine(
                                "Leaving the archive segments in place — not every entry was extracted."
                            ))
                    }
                    continuation.yield(.docStatusChanged(.extractedSuccessfully))
                    continuation.yield(.logLine("The archive contained no extractable files."))
                    continuation.yield(.finished(.success(OperationSummary())))
                    return
                }
            case .failed(let message):
                yieldExtractFailure(
                    .engine(code: Int32(UNRARSHIM_WRITE_ERROR.rawValue), message: message),
                    continuation: continuation)
                return
            }
        }

        yieldExtractFailure(
            terminalError
                ?? .engine(
                    code: Int32(result.rawValue),
                    message: "Extraction ended unexpectedly (code \(result.rawValue))."),
            continuation: continuation)
    }

    // MARK: - Segment disposal (ROADMAP Phase 7; doc-01 §5.4 "delete segments")

    /// Disposes the extracted set's volume files after a FULLY successful run (and only
    /// then — partial failures, wrong passwords and cancels never reach here, so a
    /// re-prompt-and-retry always still finds its volumes). Eligible are exactly the
    /// volumes the engine visited during the extract pass plus the opened first volume,
    /// each re-checked against set membership and the placed output. A failed trash
    /// NEVER escalates to deletion (network volumes without a Trash leave the file and
    /// say so). Runs while the operation's security scopes are still active.
    private static func disposeSegments(
        _ disposal: SegmentDisposal,
        firstVolume: URL,
        visitedVolumes: [String],
        placedOutput: URL?,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) {
        guard disposal != .leave else { return }
        let manager = FileManager.default
        var volumes: [URL] = []
        var seen = Set<String>()
        for url in [firstVolume] + visitedVolumes.map(URL.init(fileURLWithPath:)) {
            guard seen.insert(url.standardizedFileURL.path.lowercased()).inserted else {
                continue
            }
            // Belt and suspenders: never a similarly-named unrelated file, never the
            // placed output (the reserved-target rename should make that impossible).
            guard RARVolumes.belongsToSet(url, firstVolume: firstVolume) else { continue }
            if let placedOutput, samePath(url, placedOutput) { continue }
            guard manager.fileExists(atPath: url.path) else { continue }
            volumes.append(url)
        }
        guard !volumes.isEmpty else { return }

        var disposed = 0
        for url in volumes {
            do {
                switch disposal {
                case .leave:
                    return
                case .moveToTrash:
                    try manager.trashItem(at: url, resultingItemURL: nil)
                case .deletePermanently:
                    try manager.removeItem(at: url)
                }
                disposed += 1
            } catch {
                continuation.yield(
                    .logLine(
                        disposal == .moveToTrash
                            ? "Could not move \(url.lastPathComponent) to the Trash — leaving it in place."
                            : "Could not delete \(url.lastPathComponent): \(error.localizedDescription)"
                    ))
            }
        }
        guard disposed > 0 else { return }
        continuation.yield(
            .logLine(
                disposal == .moveToTrash
                    ? "Moved \(disposed) segment(s) to the Trash."
                    : "Deleted \(disposed) segment(s)."))
    }

    /// Path equality across the /var → /private/var symlink and standardization differences.
    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Shim calls

    private static func listArchive(
        at url: URL, collector: ListCollector, flags: inout UInt32
    ) -> UnrarShimResult {
        let context = Unmanaged.passUnretained(collector).toOpaque()
        var callbacks = UnrarShimCallbacks()
        callbacks.context = context
        callbacks.entry = { context, entry in
            guard let context, let entry = entry?.pointee, let name = entry.name_utf8 else {
                return
            }
            // raw_name points into shim storage that only lives for this callback — copy.
            var rawNameBytes: [UInt8]?
            if entry.name_had_unicode == 0, let raw = entry.raw_name, entry.raw_name_size > 0 {
                rawNameBytes = Array(UnsafeBufferPointer(start: raw, count: entry.raw_name_size))
            }
            Unmanaged<ListCollector>.fromOpaque(context).takeUnretainedValue().add(
                RAREntry(
                    name: String(cString: name),
                    unpackedSize: entry.unpacked_size,
                    isDirectory: entry.is_directory != 0,
                    isEncrypted: entry.is_encrypted != 0,
                    unpVersion: Int(entry.unp_version),
                    rawNameBytes: rawNameBytes))
        }
        callbacks.volume_missing = { context, name in
            guard let context, let name else { return }
            Unmanaged<ListCollector>.fromOpaque(context).takeUnretainedValue()
                .noteMissingVolume(String(cString: name))
        }
        callbacks.need_password = { context, buf, size in
            guard let context else { return 0 }
            let collector = Unmanaged<ListCollector>.fromOpaque(context).takeUnretainedValue()
            return RARExtractor.fill(buffer: buf, size: size, with: collector.broker.passwordSync())
        }
        callbacks.should_cancel = { context in
            guard let context else { return 0 }
            return Unmanaged<ListCollector>.fromOpaque(context).takeUnretainedValue()
                .token.isCancelled
                ? 1 : 0
        }
        callbacks.allow_large_dictionary = { _, requiredKiB, _ in
            RARExtractor.allowDictionary(requiredKiB: requiredKiB) ? 1 : 0
        }
        return withUnsafePointer(to: callbacks) { pointer in
            unrarshim_list(url.path, pointer, &flags)
        }
    }

    private static func extractArchive(
        at url: URL, into staging: URL, keepBroken: Bool, bridge: ExtractBridge
    ) -> UnrarShimResult {
        let context = Unmanaged.passUnretained(bridge).toOpaque()
        var callbacks = UnrarShimCallbacks()
        callbacks.context = context
        callbacks.file_start = { context, index, name, _ in
            guard let context, let name else { return }
            Unmanaged<ExtractBridge>.fromOpaque(context).takeUnretainedValue()
                .fileStart(String(cString: name), index: Int(index))
        }
        callbacks.file_done = { context, index, name, code in
            guard let context, let name else { return }
            Unmanaged<ExtractBridge>.fromOpaque(context).takeUnretainedValue()
                .fileDone(String(cString: name), code: code, index: Int(index))
        }
        callbacks.destination_override = { context, index, _, buf, size in
            guard let context else { return 0 }
            let bridge = Unmanaged<ExtractBridge>.fromOpaque(context).takeUnretainedValue()
            return RARExtractor.fill(
                buffer: buf, size: size, with: bridge.overridePath(forEntry: Int(index)))
        }
        callbacks.bytes_extracted = { context, bytes in
            guard let context else { return }
            Unmanaged<ExtractBridge>.fromOpaque(context).takeUnretainedValue().addBytes(bytes)
        }
        callbacks.volume_changed = { context, name in
            guard let context, let name else { return }
            Unmanaged<ExtractBridge>.fromOpaque(context).takeUnretainedValue()
                .volumeChanged(String(cString: name))
        }
        callbacks.volume_missing = { context, name in
            guard let context, let name else { return }
            Unmanaged<ExtractBridge>.fromOpaque(context).takeUnretainedValue()
                .noteMissingVolume(String(cString: name))
        }
        callbacks.need_password = { context, buf, size in
            guard let context else { return 0 }
            let bridge = Unmanaged<ExtractBridge>.fromOpaque(context).takeUnretainedValue()
            return RARExtractor.fill(buffer: buf, size: size, with: bridge.broker.passwordSync())
        }
        callbacks.should_cancel = { context in
            guard let context else { return 0 }
            return Unmanaged<ExtractBridge>.fromOpaque(context).takeUnretainedValue()
                .token.isCancelled
                ? 1 : 0
        }
        callbacks.allow_large_dictionary = { _, requiredKiB, _ in
            RARExtractor.allowDictionary(requiredKiB: requiredKiB) ? 1 : 0
        }
        return withUnsafePointer(to: callbacks) { pointer in
            unrarshim_extract(url.path, staging.path, keepBroken ? 1 : 0, pointer, nil)
        }
    }

    /// Copies a UTF-8 string (password / destination override) into the engine's callback
    /// buffer; 0 declines the request (which keeps the engine default for overrides).
    private static func fill(
        buffer: UnsafeMutablePointer<CChar>?, size: Int, with value: String?
    ) -> Int32 {
        guard let buffer, size > 0, let value, !value.isEmpty,
            value.utf8.count < size
        else { return 0 }
        _ = value.withCString { strlcpy(buffer, $0, size) }
        return 1
    }

    /// RAR7 dictionaries can be configured up to 64 GiB; allow what fits comfortably in RAM.
    private static func allowDictionary(requiredKiB: UInt64) -> Bool {
        requiredKiB.multipliedReportingOverflow(by: 1024).overflow == false
            && requiredKiB * 1024 <= ProcessInfo.processInfo.physicalMemory / 2
    }

    // MARK: - Result mapping (ROADMAP: "map the UnRAR error domain to readable messages")

    private static func mappedError(
        code: UnrarShimResult,
        missingVolume: String?,
        passwordWasConsulted: Bool,
        wrongPasswordLikely: Bool
    ) -> EngineError {
        switch code {
        case UNRARSHIM_CANCELLED:
            return .cancelled
        case UNRARSHIM_MISSING_PASSWORD:
            return .passwordNeeded
        case UNRARSHIM_BAD_PASSWORD:
            return .badPassword
        case UNRARSHIM_VOLUME_MISSING:
            return .volumeMissing(missingVolume ?? "(unknown volume)")
        case UNRARSHIM_BAD_DATA where passwordWasConsulted && wrongPasswordLikely:
            // RAR3 cannot distinguish a wrong password from corrupt data (no password check
            // value — decryption garbage just fails the CRC). When a password was asked for
            // and every failure was an encrypted entry, treat it as a wrong password so the
            // UI re-prompts.
            return .badPassword
        default:
            return .engine(code: Int32(code.rawValue), message: message(for: code))
        }
    }

    private static func message(for code: UnrarShimResult) -> String {
        switch code {
        case UNRARSHIM_NO_MEMORY:
            return "Not enough memory to extract the archive."
        case UNRARSHIM_BAD_DATA:
            return "The archive data is damaged (checksum failure)."
        case UNRARSHIM_BAD_ARCHIVE:
            return "This is not a valid RAR archive."
        case UNRARSHIM_UNKNOWN_FORMAT:
            return "Unknown or unsupported archive format."
        case UNRARSHIM_OPEN_ERROR:
            return "The archive (or one of its volumes) could not be opened."
        case UNRARSHIM_CREATE_ERROR:
            return "An output file could not be created in the destination."
        case UNRARSHIM_CLOSE_ERROR:
            return "A file could not be closed."
        case UNRARSHIM_READ_ERROR:
            return "A read error occurred while reading the archive."
        case UNRARSHIM_WRITE_ERROR:
            return "A write error occurred in the destination."
        case UNRARSHIM_SMALL_BUFFER:
            return "Internal error: buffer too small."
        case UNRARSHIM_REFERENCE_ERROR:
            return "A file reference inside the archive could not be resolved."
        case UNRARSHIM_LARGE_DICT:
            return
                "This archive needs a decompression dictionary larger than this Mac's memory comfortably allows."
        case UNRARSHIM_CXX_EXCEPTION:
            return "The extraction engine reported an internal error."
        case UNRARSHIM_BAD_PARAMETER:
            return "Internal error: bad parameter."
        default:
            return "Extraction failed (code \(code.rawValue))."
        }
    }

    private static func describeArchive(
        flags: UInt32, fileCount: Int, totalBytes: UInt64,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) {
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: totalBytes), countStyle: .file)
        var notes: [String] = []
        if flags & UInt32(UNRARSHIM_FLAG_VOLUME) != 0 { notes.append("multi-volume") }
        if flags & UInt32(UNRARSHIM_FLAG_SOLID) != 0 { notes.append("solid") }
        if flags & UInt32(UNRARSHIM_FLAG_ENCHEADERS) != 0 { notes.append("encrypted headers") }
        if flags & UInt32(UNRARSHIM_FLAG_RECOVERY) != 0 { notes.append("recovery record") }
        let suffix = notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"
        continuation.yield(
            .logLine("Archive: \(fileCount) file(s), \(size)\(suffix) — \(engineVersion())"))
    }

    private static func engineVersion() -> String {
        guard let version = unrarshim_version() else { return "UnRAR" }
        return String(cString: version)
    }
}
