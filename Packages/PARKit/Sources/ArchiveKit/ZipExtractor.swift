import CLibArchive
import Foundation
import ModernPARCore

/// Zip extraction through the SYSTEM libarchive (CLibArchive — BSD, supports store/deflate/
/// LZMA/ZSTD, Zip64, ZipCrypto and WinZip AES decryption). (ARCHITECTURE.md §1.4; ROADMAP
/// Phase 5. libarchive is deliberately NEVER in the RAR path — encrypted RAR must hit UnRAR.)
///
/// Same shape and contracts as `RARExtractor`: hot stream, private serial queue, cooperative
/// cancellation, two passes (list → staged extract), shared placement/conflict machinery,
/// prompt-once password via `PasswordBroker`, and placement skipped for wrong-password runs.
public final class ZipExtractor: ArchiveExtractor, Sendable {
    /// "Keep broken files": when true, entries failing mid-extraction stay on disk.
    private let keepBrokenFiles: @Sendable () -> Bool

    public init(keepBrokenFiles: Bool = false) {
        self.keepBrokenFiles = { keepBrokenFiles }
    }

    public init(keepBrokenFiles provider: @escaping @Sendable () -> Bool) {
        self.keepBrokenFiles = provider
    }

    private static let queue = DispatchQueue(
        label: "org.modernpar.unzip-engine", qos: .userInitiated)

    public func extract(
        _ archive: SessionRoute,
        to destination: ExtractDestination,
        password: any PasswordProvider,
        conflicts: any ConflictResolver
    ) -> AsyncStream<EngineEvent> {
        let keepBroken = keepBrokenFiles()
        return AsyncStream { continuation in
            let token = ExtractCancelToken()
            continuation.onTermination = { _ in token.cancel() }
            Self.queue.async {
                EngineDrainRegistry.shared.enter()
                defer { EngineDrainRegistry.shared.leave() }
                Self.execute(
                    route: archive, destination: destination, password: password,
                    conflicts: conflicts, keepBroken: keepBroken,
                    token: token, continuation: continuation)
                continuation.finish()
            }
        }
    }

    // MARK: - Blocking engine drive (engine queue)

    private struct ZipEntry {
        var name: String
        var unpackedSize: UInt64
        var isDirectory: Bool
        var isEncrypted: Bool
    }

    private static func execute(
        route: SessionRoute,
        destination: ExtractDestination,
        password: any PasswordProvider,
        conflicts: any ConflictResolver,
        keepBroken: Bool,
        token: ExtractCancelToken,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) {
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

        let destFolder: URL
        switch destination {
        case .besideArchive:
            destFolder = anchor.deletingLastPathComponent()
        case .fixed(let bookmark):
            guard let resolved = try? ScopedAccess.resolve(bookmark) else {
                continuation.yield(
                    .finished(.failure(.launchFailed("the destination folder is unavailable"))))
                return
            }
            if resolved.didStart { scopeStops.append(resolved.url) }
            destFolder = resolved.url
        case .ask:
            continuation.yield(
                .finished(
                    .failure(.launchFailed("destination must be chosen before extraction starts"))))
            return
        }

        let archiveBase = RARVolumes.baseName(for: anchor)
        let broker = PasswordBroker(provider: password, token: token, archiveName: archiveBase)

        // ── Pass 1: list (zip entry names/sizes are never encrypted) ────────────────────
        var entries: [ZipEntry] = []
        var hostileSkips: [String] = []
        switch listEntries(of: anchor, token: token, into: &entries, hostile: &hostileSkips) {
        case .failure(let error):
            yieldExtractFailure(
                token.isCancelled ? .cancelled : error, continuation: continuation)
            return
        case .success:
            break
        }

        let files = entries.filter { !$0.isDirectory }
        let rows = files.map { FileEntry(name: $0.name, sizeBytes: $0.unpackedSize) }
        var idsByName: [String: UUID] = [:]
        for (entry, row) in zip(files, rows) where idsByName[entry.name] == nil {
            idsByName[entry.name] = row.id
        }
        let totalBytes = files.reduce(UInt64(0)) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(file.unpackedSize)
            return overflow ? UInt64.max : sum
        }

        continuation.yield(.scanningStarted(totalFiles: rows.count))
        continuation.yield(.filesDiscovered(rows))
        continuation.yield(.docStatusChanged(.extracting))
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: totalBytes), countStyle: .file)
        let encryptedCount = files.filter(\.isEncrypted).count
        continuation.yield(
            .logLine(
                "Zip archive: \(rows.count) file(s), \(size)\(encryptedCount > 0 ? " (\(encryptedCount) encrypted)" : "") — libarchive \(String(cString: archive_version_string()))"
            ))
        for name in hostileSkips {
            continuation.yield(
                .logLine("Refusing entry \"\(name)\" (path escapes the destination)."))
        }

        // ── Pass 2: extract into staging ────────────────────────────────────────────────
        ExtractPlacement.sweepStaleStaging(in: destFolder)
        let staging: URL
        do {
            staging = try ExtractPlacement.makeStaging(in: destFolder)
        } catch {
            yieldExtractFailure(
                .engine(
                    code: 16,
                    message:
                        "Could not create a working folder in \(destFolder.lastPathComponent): \(error.localizedDescription)"
                ), continuation: continuation)
            return
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        // ZipCrypto's 1-byte verifier means a wrong password CAN slip through to a CRC
        // failure — same shape as legacy RAR, so encrypted names feed the same heuristic.
        let bridge = ExtractBridge(
            continuation: continuation, idsByName: idsByName,
            legacyEncryptedNames: Set(files.filter(\.isEncrypted).map(\.name)),
            totalBytes: totalBytes, broker: broker, token: token)

        let result = extractEntries(
            of: anchor, into: staging, keepBroken: keepBroken, bridge: bridge, token: token)

        // ── Terminal handling (mirrors RARExtractor) ────────────────────────────────────
        let aborted = token.isCancelled || result == .cancelled || result == .passwordNeeded
        let completedLoop = result == nil || result == .perFileFailures
        let terminalError: EngineError? = {
            if token.isCancelled { return .cancelled }
            guard let result else { return nil }
            switch result {
            case .cancelled: return .cancelled
            case .passwordNeeded: return .passwordNeeded
            case .badPassword: return .badPassword
            case .perFileFailures:
                if broker.wasConsulted && bridge.failuresLookLikeWrongPassword {
                    return .badPassword
                }
                return .engine(
                    code: 12, message: "The archive data is damaged (checksum failure).")
            case .fatal(let message):
                return .engine(code: 12, message: message)
            }
        }()
        let placementAllowed = !aborted && completedLoop && terminalError != .badPassword

        if placementAllowed {
            let anchorPath = anchor.standardizedFileURL.path.lowercased()
            switch ExtractPlacement.place(
                staging: staging, destFolder: destFolder, fallbackName: archiveBase,
                isReservedTarget: { $0.standardizedFileURL.path.lowercased() == anchorPath },
                conflicts: ConflictBroker(resolver: conflicts, token: token),
                continuation: continuation)
            {
            case .placed(let url):
                continuation.yield(.extractionPlaced(url))
                continuation.yield(.logLine("Extracted to \(url.path)"))
                if bridge.skipped > 0 {
                    continuation.yield(
                        .logLine(
                            "\(bridge.skipped) entr\(bridge.skipped == 1 ? "y" : "ies") skipped."
                        ))
                }
                if let terminalError {
                    continuation.yield(
                        .logLine(
                            "Extracted \(bridge.succeeded) of \(rows.count) file(s); \(bridge.failed) failed."
                        ))
                    yieldExtractFailure(terminalError, continuation: continuation)
                } else {
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
                    continuation.yield(.docStatusChanged(.extractedSuccessfully))
                    continuation.yield(.logLine("The archive contained no extractable files."))
                    continuation.yield(.finished(.success(OperationSummary())))
                    return
                }
            case .failed(let message):
                yieldExtractFailure(
                    .engine(code: 19, message: message), continuation: continuation)
                return
            }
        }

        yieldExtractFailure(
            terminalError ?? .engine(code: 21, message: "Extraction ended unexpectedly."),
            continuation: continuation)
    }

    // MARK: - libarchive passes

    /// Terminal outcomes of the extract loop; nil result means clean success.
    private enum LoopResult: Equatable {
        case cancelled
        case passwordNeeded
        case badPassword
        case perFileFailures
        case fatal(String)
    }

    private static func listEntries(
        of url: URL, token: ExtractCancelToken,
        into entries: inout [ZipEntry], hostile: inout [String]
    ) -> Result<Void, EngineError> {
        guard let a = archive_read_new() else {
            return .failure(.engine(code: 21, message: "libarchive initialization failed."))
        }
        defer { archive_read_free(a) }
        archive_read_support_format_zip(a)
        archive_read_support_filter_all(a)
        guard archive_read_open_filename(a, url.path, 1 << 16) == ARCHIVE_OK else {
            return .failure(
                .engine(code: 13, message: "This is not a valid zip archive."))
        }
        var entry: OpaquePointer?
        while true {
            if token.isCancelled { return .failure(.cancelled) }
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { return .success(()) }
            if r == ARCHIVE_FATAL {
                return .failure(
                    .engine(code: 12, message: damageMessage(from: a)))
            }
            guard r == ARCHIVE_OK || r == ARCHIVE_WARN, let entry else { continue }
            guard let rawName = entryName(entry) else { continue }
            guard let safeName = safeRelativePath(rawName) else {
                hostile.append(rawName)
                continue
            }
            let isDirectory = entryIsDirectory(entry) || rawName.hasSuffix("/")
            let declared = archive_entry_size(entry)
            entries.append(
                ZipEntry(
                    name: safeName,
                    unpackedSize: declared > 0 ? UInt64(declared) : 0,
                    isDirectory: isDirectory,
                    isEncrypted: archive_entry_is_data_encrypted(entry) != 0))
        }
    }

    private static func extractEntries(
        of url: URL, into staging: URL, keepBroken: Bool,
        bridge: ExtractBridge, token: ExtractCancelToken
    ) -> LoopResult? {
        guard let a = archive_read_new() else { return .fatal("libarchive init failed") }
        defer { archive_read_free(a) }
        archive_read_support_format_zip(a)
        archive_read_support_filter_all(a)

        let passphrase = ZipPassphraseContext(broker: bridge.broker)
        archive_read_set_passphrase_callback(
            a, Unmanaged.passUnretained(passphrase).toOpaque()
        ) { _, context in
            guard let context else { return nil }
            return Unmanaged<ZipPassphraseContext>.fromOpaque(context).takeUnretainedValue()
                .passphrase()
        }

        guard archive_read_open_filename(a, url.path, 1 << 16) == ARCHIVE_OK else {
            return .fatal("This is not a valid zip archive.")
        }
        // libarchive holds the passphrase context pointer (passUnretained) for the handle's
        // lifetime; pin it structurally rather than relying on incidental closure capture.
        return withExtendedLifetime(passphrase) {
            extractLoop(
                a: a, into: staging, keepBroken: keepBroken, bridge: bridge, token: token,
                passphrase: passphrase)
        }
    }

    private static func extractLoop(
        a: OpaquePointer, into staging: URL, keepBroken: Bool,
        bridge: ExtractBridge, token: ExtractCancelToken, passphrase: ZipPassphraseContext
    ) -> LoopResult? {
        guard let disk = archive_write_disk_new() else { return .fatal("libarchive init failed") }
        defer { archive_write_free(disk) }
        // Entry names are sanitized and re-rooted onto an absolute staging path below, so
        // SECURE_NOABSOLUTEPATHS cannot be used (it would reject every write); the name-level
        // guards live in safeRelativePath. SECURE_SYMLINKS still refuses writing THROUGH a
        // symlink an earlier hostile entry planted — the classic zip-slip second stage.
        archive_write_disk_set_options(
            disk,
            ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_SECURE_SYMLINKS
                | ARCHIVE_EXTRACT_SECURE_NODOTDOT)
        archive_write_disk_set_standard_lookup(disk)
        // /var (and any symlinked user destination) must be fully resolved or
        // SECURE_SYMLINKS refuses every write. NOT resolvingSymlinksInPath(): Foundation
        // deliberately prefers the /var alias over /private/var — POSIX realpath() is the
        // only API that yields the symlink-free truth.
        let stagingRoot = realPath(of: staging)

        // Genuine data damage (CRC / lying size) — distinct from safety/permission SKIPS,
        // which are warnings that must not read as "the archive is damaged".
        var sawDataFailure = false
        var seenNames = Set<String>()
        var entry: OpaquePointer?
        while true {
            if token.isCancelled { return .cancelled }
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { break }
            if r == ARCHIVE_FATAL { return .fatal(damageMessage(from: a)) }
            guard r == ARCHIVE_OK || r == ARCHIVE_WARN, let entry else { continue }
            guard let rawName = entryName(entry) else { continue }
            guard let safeName = safeRelativePath(rawName) else { continue }  // listed already

            // A duplicate entry name (legal in zip, common in crafted archives) would
            // silently overwrite the first and double-count — skip the later twin.
            guard seenNames.insert(safeName).inserted else {
                bridge.skip(safeName, reason: "duplicate entry name")
                continue
            }

            // Refuse hostile symlink entries the way the RAR engine does (absolute target or
            // one that escapes the destination) — SECURE_SYMLINKS only blocks writing THROUGH
            // such a link, not creating it.
            if let unsafeTarget = unsafeSymlinkTarget(entry) {
                bridge.skip(safeName, reason: "unsafe link → \(unsafeTarget)")
                continue
            }

            let isDirectory = entryIsDirectory(entry) || rawName.hasSuffix("/")
            let outputURL = stagingRoot.appendingPathComponent(safeName)
            archive_entry_set_pathname_utf8(entry, outputURL.path)

            if !isDirectory { bridge.fileStart(safeName) }

            let headerResult = archive_write_header(disk, entry)
            if headerResult < ARCHIVE_WARN {
                // FAILED/FATAL: the file was not created (a safety refusal, EEXIST, perms).
                // This is a SKIP, not data damage — don't taint the wrong-password heuristic
                // or the "archive damaged" verdict.
                let detail =
                    archive_error_string(disk).map { String(cString: $0) } ?? "unknown error"
                bridge.skip(safeName, reason: detail)
                continue
            }
            if headerResult == ARCHIVE_WARN {
                let detail =
                    archive_error_string(disk).map { String(cString: $0) } ?? ""
                if !detail.isEmpty { bridge.note("\(safeName): \(detail)") }
                // WARN = partial success: the file exists, data can still be pushed.
            }

            // Copy data for every non-directory entry whose size is unknown OR positive —
            // the streamable zip reader (used when the central directory is unreadable, the
            // damaged-tail case) leaves size UNSET, and gating on size>0 would write empty
            // files and report success. (Phase 5 review: silent data loss.)
            var failed: LoopResult?
            if !isDirectory
                && !(archive_entry_size_is_set(entry) != 0 && archive_entry_size(entry) == 0)
            {
                failed = copyData(
                    from: a, to: disk, declined: { passphrase.declined }, token: token,
                    bridge: bridge)
            }
            archive_write_finish_entry(disk)

            if let failed {
                switch failed {
                case .cancelled, .passwordNeeded, .badPassword, .fatal:
                    return failed
                case .perFileFailures:
                    sawDataFailure = true
                    if !isDirectory {
                        bridge.fileDone(safeName, code: 12)
                        if !keepBroken { try? FileManager.default.removeItem(at: outputURL) }
                    }
                }
            } else if !isDirectory {
                bridge.fileDone(safeName, code: 0)
            }
        }
        return sawDataFailure ? .perFileFailures : nil
    }

    /// Streams one entry's data; nil on success.
    private static func copyData(
        from a: OpaquePointer, to disk: OpaquePointer,
        declined: () -> Bool, token: ExtractCancelToken, bridge: ExtractBridge
    ) -> LoopResult? {
        var buffer: UnsafeRawPointer?
        var size = 0
        var offset: Int64 = 0
        while true {
            if token.isCancelled { return .cancelled }
            let r = archive_read_data_block(a, &buffer, &size, &offset)
            if r == ARCHIVE_EOF { return nil }
            guard r == ARCHIVE_OK || r == ARCHIVE_WARN else {
                // The user declining the passphrase prompt surfaces here as a read error.
                if declined() { return .passwordNeeded }
                let message = archive_error_string(a).map { String(cString: $0) } ?? ""
                if message.localizedCaseInsensitiveContains("passphrase") {
                    return .badPassword
                }
                return r == ARCHIVE_FATAL ? .fatal(damageMessage(from: a)) : .perFileFailures
            }
            let w = archive_write_data_block(disk, buffer, size, offset)
            if w < ARCHIVE_WARN {
                // FAILED/FATAL is a real destination error. ARCHIVE_WARN ("Too much data:
                // truncating…", from an entry whose real data exceeds its declared size) is
                // per-file damage, not a disk failure — fall through and let the caller treat
                // the entry as a per-file failure rather than aborting the whole run.
                return .fatal("A write error occurred in the destination.")
            }
            if w == ARCHIVE_WARN { return .perFileFailures }
            bridge.addBytes(UInt64(size))
        }
    }

    /// For a symlink entry, returns its target when that target is unsafe (absolute, or it
    /// escapes the entry's own directory via `..`); nil for safe links and non-links. Mirrors
    /// the CUnrar shim's unsafe-link policy so both extractors agree. (Phase 5 review)
    private static func unsafeSymlinkTarget(_ entry: OpaquePointer) -> String? {
        guard archive_entry_filetype(entry) == 0o120000,  // AE_IFLNK
            let raw = archive_entry_symlink(entry)
        else { return nil }
        let target = String(cString: raw)
        if target.hasPrefix("/") { return target }
        var depth = 0
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            if part == ".." {
                depth -= 1
                if depth < 0 { return target }
            } else if part != "." {
                depth += 1
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// AE_IFDIR is a casting macro in archive_entry.h and does not import into Swift.
    private static func entryIsDirectory(_ entry: OpaquePointer) -> Bool {
        archive_entry_filetype(entry) == 0o040000
    }

    /// Fully symlink-resolved path via POSIX realpath (Foundation's
    /// resolvingSymlinksInPath deliberately keeps the /var alias).
    private static func realPath(of url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func entryName(_ entry: OpaquePointer) -> String? {
        if let utf8 = archive_entry_pathname_utf8(entry) { return String(cString: utf8) }
        if let raw = archive_entry_pathname(entry) { return String(cString: raw) }
        return nil
    }

    /// Normalizes an entry path to a safe staging-relative path; nil = hostile (traversal /
    /// absolute / empty), and the entry is skipped.
    static func safeRelativePath(_ raw: String) -> String? {
        // Windows-built zips may use backslash separators.
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        var components: [String] = []
        for part in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            components.append(String(part))
        }
        // A top-level component using the staging prefix would be placed beside real output
        // and then reaped by a later run's stale-staging sweep — refuse it.
        if let first = components.first, first.hasPrefix(ExtractPlacement.stagingPrefix) {
            return nil
        }
        // An absolute path ("/tmp/x") loses its leading slash here, which re-roots it into
        // staging — but a SINGLE-component absolute name was clearly hostile intent too;
        // keeping the re-rooted form extracts the data safely either way.
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    private static func damageMessage(from a: OpaquePointer) -> String {
        let detail = archive_error_string(a).map { String(cString: $0) } ?? ""
        return detail.isEmpty
            ? "The archive data is damaged." : "The archive is damaged: \(detail)"
    }
}

/// Holds the lazily-prompted passphrase for libarchive's callback, which requires a C string
/// that stays valid for the archive handle's lifetime. Single-threaded by contract: only the
/// engine-queue thread (via the libarchive callback) touches it.
final class ZipPassphraseContext: @unchecked Sendable {
    private let broker: PasswordBroker
    private var cString: UnsafeMutablePointer<CChar>?
    private(set) var declined = false

    init(broker: PasswordBroker) {
        self.broker = broker
    }

    func passphrase() -> UnsafePointer<CChar>? {
        if let cString { return UnsafePointer(cString) }
        if declined { return nil }
        guard let password = broker.passwordSync() else {
            declined = true
            return nil
        }
        cString = strdup(password)
        return cString.map { UnsafePointer($0) }
    }

    deinit {
        if let cString {
            cleandata(cString, strlen(cString))
            free(cString)
        }
    }
}

/// Best-effort scrub of a password buffer before freeing it.
private func cleandata(_ pointer: UnsafeMutablePointer<CChar>, _ count: Int) {
    memset_s(pointer, count, 0, count)
}
