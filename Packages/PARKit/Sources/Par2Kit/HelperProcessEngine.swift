import Foundation
import ModernPARCore

/// PAR2 via the bundled `par2` CLI helper (par2cmdline-turbo), driven over a
/// `Foundation.Process` boundary. The designed-in fallback to the primary embedded engine —
/// and the standby GPL license firewall should a non-GPL build ever be needed.
/// (ARCHITECTURE.md §0, §1.1, §6)
///
/// Same contract as `EmbeddedEngine` (the protocol-level suite runs against both): the run
/// starts at `run(_:)`, output lines stream through the shared `TurboOutputParser`, runs are
/// serialized, and cancelling the consuming task terminates the child process.
public final class HelperProcessEngine: PAR2Engine, Sendable {
    private let helperURL: URL
    private let repairsAutomatically: Bool
    private let threadCount: UInt32

    public init(helperURL: URL, repairsAutomatically: Bool = true, threadCount: UInt32 = 0) {
        self.helperURL = helperURL
        self.repairsAutomatically = repairsAutomatically
        self.threadCount = threadCount
    }

    public func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
        let repairs = repairsAutomatically && route.autoRepair
        let threads = threadCount
        let helper = helperURL
        return AsyncStream { continuation in
            let box = ProcessBox()
            continuation.onTermination = { _ in box.cancel() }
            // Straight onto the serial queue — wrapping in Task.detached + queue.sync would
            // pin a width-limited Swift Concurrency pool thread for the whole run.
            EngineRunSupport.serialQueue.async {
                Self.execute(
                    route: route, helper: helper, repairs: repairs, threads: threads,
                    box: box, continuation: continuation)
                continuation.finish()
            }
        }
    }

    // MARK: - Blocking subprocess drive (off the main actor)

    private static func execute(
        route: SessionRoute,
        helper: URL,
        repairs: Bool,
        threads: UInt32,
        box: ProcessBox,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) {
        guard route.mode == .verifyRepair else {
            continuation.yield(.finished(.failure(.notImplemented)))
            return
        }
        let scopes = EngineRunSupport.beginScopes(for: route)
        defer { scopes.end() }
        guard let anchor = scopes.anchor else {
            continuation.yield(
                .finished(.failure(.launchFailed("session has no .par2 anchor bookmark"))))
            return
        }

        // par2's CLI hard-rejects wildcard characters in the par-file path and glob-expands
        // them in extra files — surface the anchor case clearly instead of "engine failed".
        if anchor.path.contains("*") || anchor.path.contains("?") {
            continuation.yield(
                .finished(
                    .failure(
                        .launchFailed(
                            "the par2 CLI cannot open paths containing '*' or '?' — use the embedded engine for this set"
                        ))))
            return
        }

        let fileIDsByName = EngineRunSupport.paintRoster(anchor: anchor, continuation: continuation)
        continuation.yield(.docStatusChanged(.checking))
        EngineRunSupport.warnIfFolderUnreadable(
            route: route, anchor: anchor, continuation: continuation)

        let bridge = LineBridge(
            parser: TurboOutputParser(fileIDsByName: fileIDsByName, repairsAutomatically: repairs),
            continuation: continuation)

        let process = Process()
        process.executableURL = helper
        process.arguments = ArgumentBuilder.verifyRepair(
            par2Path: anchor.path,
            repair: repairs,
            extraFiles: EngineRunSupport.extraFiles(near: anchor).map(\.path),
            threads: threads)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Dedicated blocking readers, joined BEFORE the terminal event: readabilityHandler
        // callbacks can still be mid-emit when the run ends, and yields into an already
        // finished stream are silently dropped (the verdict lines arrive last).
        let drained = DispatchGroup()
        let readers: [(Pipe, LineSplitter)] = [
            (stdout, LineSplitter { bridge.handle($0, isError: false) }),
            (stderr, LineSplitter { bridge.handle($0, isError: true) }),
        ]
        for (pipe, splitter) in readers {
            drained.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = pipe.fileHandleForReading
                while true {
                    let data = handle.availableData  // blocks until data or EOF
                    if data.isEmpty { break }
                    splitter.consume(data)
                }
                splitter.finish()
                drained.leave()
            }
        }

        do {
            try box.launch(process)
            // Close the PARENT's copies of the write ends: the child holds its own duplicates,
            // and without this the readers never see EOF after the child exits — the drain
            // below would wait forever.
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        } catch {
            // Unblock the reader threads (EOF), wait for them, then report.
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            drained.wait()
            if error is CancellationError {
                continuation.yield(.finished(.failure(.cancelled)))
            } else {
                continuation.yield(
                    .finished(.failure(.launchFailed("could not launch par2 helper: \(error)"))))
            }
            return
        }
        process.waitUntilExit()
        drained.wait()  // every output line is parsed and yielded before the terminal event

        // terminationStatus is only a libpar2 Result for a normal exit; for a signal death it
        // is the SIGNAL NUMBER (SIGHUP=1 would otherwise read as "repair possible").
        guard process.terminationReason == .exit else {
            if box.isCancelled {
                continuation.yield(.finished(.failure(.cancelled)))
            } else {
                continuation.yield(.docStatusChanged(.internalError))
                continuation.yield(
                    .finished(
                        .failure(
                            .engine(
                                code: process.terminationStatus,
                                message:
                                    "par2 helper terminated by signal \(process.terminationStatus)"
                            ))))
            }
            return
        }
        EngineRunSupport.finish(
            code: process.terminationStatus,
            wasCancelled: false,
            bridge: bridge,
            continuation: continuation)
    }
}

/// Holds the child process so `onTermination` (cancel) can SIGTERM it from any thread, and so
/// a cancel that fires before launch prevents the launch entirely.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func launch(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        self.process = process
        try process.run()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        if let process, process.isRunning {
            process.terminate()
            // Escalate: a child wedged in uninterruptible I/O (dead network volume, hung
            // disk — exactly when users cancel) may never take SIGTERM, and the blocked
            // waitUntilExit holds the shared engine queue for the rest of the launch.
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                [weak process] in
                if let process, process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Splits a byte stream into lines on BOTH `\n` and `\r` — the engine's progress updates are
/// `\r`-terminated ("Scanning: 12.3%\r") and would otherwise arrive as one giant line.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let emit: (String) -> Void

    init(emit: @escaping (String) -> Void) {
        self.emit = emit
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        var start = buffer.startIndex
        for index in buffer.indices {
            let byte = buffer[index]
            if byte == 0x0A || byte == 0x0D {  // \n or \r
                if index > start {
                    lines.append(String(decoding: buffer[start..<index], as: UTF8.self))
                }
                start = buffer.index(after: index)
            }
        }
        buffer = Data(buffer[start...])
        lock.unlock()
        for line in lines { emit(line) }
    }

    /// Emits any unterminated tail (the engine's final line is newline-terminated, but be safe).
    func finish() {
        lock.lock()
        let tail = buffer
        buffer = Data()
        lock.unlock()
        if !tail.isEmpty {
            emit(String(decoding: tail, as: UTF8.self))
        }
    }
}
