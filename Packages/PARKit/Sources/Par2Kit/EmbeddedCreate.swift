import Foundation
import ModernPARCore
import Par2Cxx

/// PAR2 authoring through the embedded turbo engine (`par2shim_create`). Mirrors the
/// `EmbeddedEngine` verify/repair shape: hot stream, serial queue, `EngineDrainRegistry`
/// gating, cooperative cancellation, and `EngineEvent` output the create window renders with
/// the same machinery as verify. (ARCHITECTURE.md §6; ROADMAP Phase 6)
extension EmbeddedEngine: Par2Creator {
    public func create(_ request: CreateRequest) -> AsyncStream<EngineEvent> {
        let threads = threadCount
        return AsyncStream { continuation in
            let token = CancelToken()
            continuation.onTermination = { _ in token.cancel() }
            EngineRunSupport.serialQueue.async {
                EngineDrainRegistry.shared.enter()
                defer { EngineDrainRegistry.shared.leave() }
                Self.runCreate(
                    request: request, threads: threads, token: token, continuation: continuation)
                continuation.finish()
            }
        }
    }

    private static func runCreate(
        request: CreateRequest,
        threads: UInt32,
        token: CancelToken,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) {
        // Hold the folder grant for the whole run — the recovery files are written into it.
        var stops: [URL] = []
        defer { for url in stops { url.stopAccessingSecurityScopedResource() } }
        if let data = request.folderBookmark, let folder = try? ScopedAccess.resolve(data),
            folder.didStart
        {
            stops.append(folder.url)
        }

        continuation.yield(.docStatusChanged(.creating))

        let sizes = request.files.map { fileSize(of: $0) }
        guard !request.files.isEmpty, sizes.contains(where: { $0 > 0 }) else {
            continuation.yield(.logLine("[err] No non-empty files to protect."))
            continuation.yield(.docStatusChanged(.createFailed))
            continuation.yield(.finished(.failure(.launchFailed("no files to protect"))))
            return
        }

        let blockSize = request.options.effectiveBlockSize(fileSizes: sizes)
        let sourceBlocks = RecoveryMath.sourceBlockCount(fileSizes: sizes, blockSize: blockSize)
        let recoveryBlocks = RecoveryMath.recoveryBlockCount(
            sourceBlocks: sourceBlocks, redundancyPercent: request.options.redundancyPercent)
        guard recoveryBlocks > 0 else {
            continuation.yield(.logLine("[err] The chosen redundancy produces no recovery data."))
            continuation.yield(.docStatusChanged(.createFailed))
            continuation.yield(.finished(.failure(.launchFailed("zero recovery blocks"))))
            return
        }

        continuation.yield(
            .logLine(
                "Creating \(request.parFile.lastPathComponent): \(request.files.count) file(s), block size \(blockSize) bytes, \(sourceBlocks) source + \(recoveryBlocks) recovery block(s) (\(request.options.redundancyPercent)%)."
            ))

        let bridge = CreateBridge(continuation: continuation)
        let result = shimCreate(
            request: request, blockSize: blockSize, recoveryBlocks: UInt32(recoveryBlocks),
            scheme: shimScheme(for: request.options.fileScheme), threads: threads,
            token: token, bridge: bridge)

        if result == PAR2SHIM_CANCELLED || token.isCancelled {
            // par2create writes the index + recovery volumes progressively and does NOT unlink
            // them when its should_cancel poll throws — a cancelled create would otherwise
            // litter the user's folder with a partial set. Reclaim them under the held scope.
            cleanupPartialOutput(request: request)
            continuation.yield(.finished(.failure(.cancelled)))
            return
        }
        guard result == PAR2SHIM_SUCCESS else {
            cleanupPartialOutput(request: request)
            continuation.yield(.docStatusChanged(.createFailed))
            continuation.yield(.overallProgress(fraction: 1))
            continuation.yield(
                .finished(
                    .failure(
                        .engine(
                            code: Int32(result.rawValue),
                            message: createMessage(for: result)))))
            return
        }

        continuation.yield(.overallProgress(fraction: 1))
        continuation.yield(.extractionPlaced(request.parFile))
        continuation.yield(.docStatusChanged(.createdSuccessfully))
        continuation.yield(.finished(.success(OperationSummary())))
    }

    private static func shimScheme(for scheme: CreateOptions.FileScheme) -> Par2ShimScheme {
        switch scheme {
        case .limitToLargest: return PAR2SHIM_SCHEME_LIMITED
        case .uniform: return PAR2SHIM_SCHEME_UNIFORM
        }
    }

    private static func shimCreate(
        request: CreateRequest,
        blockSize: UInt64,
        recoveryBlocks: UInt32,
        scheme: Par2ShimScheme,
        threads: UInt32,
        token: CancelToken,
        bridge: CreateBridge
    ) -> Par2ShimResult {
        let bridgeContext = Unmanaged.passUnretained(bridge).toOpaque()
        let tokenContext = Unmanaged.passUnretained(token).toOpaque()
        let argv: [UnsafePointer<CChar>?] = request.files.map { UnsafePointer(strdup($0.path)) }
        defer {
            for pointer in argv { free(UnsafeMutablePointer(mutating: pointer)) }
        }
        return argv.withUnsafeBufferPointer { buffer in
            par2shim_create(
                request.parFile.path,
                nil,
                buffer.baseAddress,
                request.files.count,
                blockSize,
                recoveryBlocks,
                scheme,
                0,
                threads,
                0,
                { context, line, isError in
                    guard let context, let line else { return }
                    Unmanaged<CreateBridge>.fromOpaque(context).takeUnretainedValue()
                        .handle(String(cString: line), isError: isError != 0)
                },
                bridgeContext,
                { context in
                    guard let context else { return 0 }
                    return Unmanaged<CancelToken>.fromOpaque(context).takeUnretainedValue()
                        .isCancelled ? 1 : 0
                },
                tokenContext
            )
        }
    }

    /// Best-effort removal of a cancelled/failed create's partial output: the index `.par2`
    /// and the recovery volumes par2 names `<stem>.volNNN+MMM.par2`. Source files (which never
    /// match the `.par2` extension) are untouched. Runs under the folder scope held by the
    /// caller. (Phase 6 review: a cancelled create must not leave litter behind.)
    /// Internal (not private) so the regression test can drive it deterministically.
    static func cleanupPartialOutput(request: CreateRequest) {
        let folder = request.parFile.deletingLastPathComponent()
        let stem = (request.parFile.lastPathComponent as NSString).deletingPathExtension
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [])
        else { return }
        let sourceNames = Set(request.files.map { $0.lastPathComponent })
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.lowercased().hasSuffix(".par2"), !sourceNames.contains(name),
                name == "\(stem).par2" || name.hasPrefix("\(stem).vol")
            else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func fileSize(of url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            .map(UInt64.init) ?? 0
    }

    private static func createMessage(for result: Par2ShimResult) -> String {
        switch result {
        case PAR2SHIM_INVALID_ARGS, PAR2SHIM_BAD_PARAMETER:
            return "The engine rejected the create parameters."
        case PAR2SHIM_FILE_IO_ERROR:
            return "A file could not be read or the recovery files could not be written."
        case PAR2SHIM_MEMORY_ERROR:
            return "Not enough memory to create the recovery set."
        default:
            return "The recovery set could not be created (code \(result.rawValue))."
        }
    }
}

/// Serializes the engine's create output (worker threads) into `EngineEvent`s: `Processing: X%`
/// lines drive `overallProgress`; everything else is a log line. (ROADMAP Phase 6)
final class CreateBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private var lastPermille = -1

    init(continuation: AsyncStream<EngineEvent>.Continuation) {
        self.continuation = continuation
    }

    func handle(_ line: String, isError: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let fraction = Self.processingFraction(trimmed) {
            // Yield inside the lock so the lastPermille update and the emit are atomic — keeps
            // progress monotonic if the engine ever reports it from more than one thread.
            lock.lock()
            defer { lock.unlock() }
            let permille = Int((fraction * 1000).rounded())
            guard permille != lastPermille else { return }
            lastPermille = permille
            continuation.yield(.overallProgress(fraction: fraction))
            return
        }
        continuation.yield(.logLine(isError ? "[err] \(trimmed)" : trimmed))
    }

    /// Parses `Processing: 42.7%` → 0.427. Returns nil for non-progress lines.
    private static func processingFraction(_ line: String) -> Double? {
        guard line.hasPrefix("Processing:"), line.hasSuffix("%") else { return nil }
        let number = line.dropFirst("Processing:".count).dropLast().trimmingCharacters(
            in: .whitespaces)
        guard let percent = Double(number) else { return nil }
        return min(1, max(0, percent / 100))
    }
}
