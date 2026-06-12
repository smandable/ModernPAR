import Foundation
import ModernPARCore
import Par2Cxx

/// The primary PAR2 engine: par2cmdline-turbo embedded in-process behind the Par2Shim C ABI.
/// (ARCHITECTURE.md §0, §1.1, §6; ROADMAP Phase 2)
///
/// `run` starts the operation immediately (the stream is NOT cold — consume it promptly;
/// events buffer until read). The blocking engine call runs on a detached task; Par2Shim's
/// line callback feeds `TurboOutputParser`, whose events are yielded into the stream.
/// Cancelling the consuming task (Cmd-.) trips the cancel token, the shim's next output poll
/// throws inside the engine, and the run unwinds cooperatively.
///
/// All engine runs are SERIALIZED (`EngineRunSupport.serialQueue`): a cancelled run keeps the
/// engine briefly while it unwinds, and a follow-up must never overlap it on the same files.
public final class EmbeddedEngine: PAR2Engine, Sendable {
    /// Engine-level master switch ANDed with `route.autoRepair`. Verify-only callers (e.g.
    /// restored windows, where auto-repair must not fire without consent) use the route flag.
    private let repairsAutomatically: Bool
    /// Engine thread count; 0 = automatic (turbo's default). Wired to the "limit CPU cores"
    /// preference in Phase 7. Read by the create path (`EmbeddedCreate`).
    let threadCount: UInt32

    public init(repairsAutomatically: Bool = true, threadCount: UInt32 = 0) {
        self.repairsAutomatically = repairsAutomatically
        self.threadCount = threadCount
    }

    public func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
        let repairs = repairsAutomatically && route.autoRepair
        let threads = threadCount
        return AsyncStream { continuation in
            let token = CancelToken()
            continuation.onTermination = { _ in token.cancel() }
            // Straight onto the serial queue — wrapping in Task.detached + queue.sync would
            // pin a width-limited Swift Concurrency pool thread for the whole run.
            EngineRunSupport.serialQueue.async {
                // Quit gating: a cancelled run owns its files until it unwinds.
                EngineDrainRegistry.shared.enter()
                defer { EngineDrainRegistry.shared.leave() }
                Self.execute(
                    route: route, repairs: repairs, threads: threads,
                    token: token, continuation: continuation)
                continuation.finish()
            }
        }
    }

    // MARK: - Blocking engine drive (off the main actor)

    private static func execute(
        route: SessionRoute,
        repairs: Bool,
        threads: UInt32,
        token: CancelToken,
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

        let fileIDsByName = EngineRunSupport.paintRoster(anchor: anchor, continuation: continuation)
        continuation.yield(.docStatusChanged(.checking))
        EngineRunSupport.warnIfFolderUnreadable(
            route: route, anchor: anchor, continuation: continuation)

        let bridge = LineBridge(
            parser: TurboOutputParser(fileIDsByName: fileIDsByName, repairsAutomatically: repairs),
            continuation: continuation)
        let result = Self.shimRepair(
            anchor: anchor, repair: repairs, threads: threads, token: token, bridge: bridge)

        EngineRunSupport.finish(
            code: Int32(result.rawValue),
            wasCancelled: result == PAR2SHIM_CANCELLED,
            bridge: bridge,
            continuation: continuation)
    }

    private static func shimRepair(
        anchor: URL, repair: Bool, threads: UInt32, token: CancelToken, bridge: LineBridge
    ) -> Par2ShimResult {
        let bridgeContext = Unmanaged.passUnretained(bridge).toOpaque()
        let tokenContext = Unmanaged.passUnretained(token).toOpaque()
        let extras = EngineRunSupport.extraFiles(near: anchor)
        var argv: [UnsafePointer<CChar>?] = extras.map { UnsafePointer(strdup($0.path)) }
        defer {
            for pointer in argv { free(UnsafeMutablePointer(mutating: pointer)) }
        }
        return argv.withUnsafeBufferPointer { buffer in
            par2shim_repair(
                anchor.path,
                nil,
                buffer.baseAddress,
                extras.count,
                threads,
                0,
                repair ? 1 : 0,
                { context, line, isError in
                    guard let context, let line else { return }
                    Unmanaged<LineBridge>.fromOpaque(context).takeUnretainedValue()
                        .handle(String(cString: line), isError: isError != 0)
                },
                bridgeContext,
                { context in
                    guard let context else { return 0 }
                    return Unmanaged<CancelToken>.fromOpaque(context).takeUnretainedValue()
                        .isCancelled
                        ? 1 : 0
                },
                tokenContext
            )
        }
    }
}

/// Set by `onTermination`, polled by the shim on engine threads.
final class CancelToken: @unchecked Sendable {
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
}

/// Serializes engine output lines (which arrive on multiple engine threads) into the parser
/// and forwards the resulting events to the stream continuation (which is thread-safe).
final class LineBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: TurboOutputParser
    private let continuation: AsyncStream<EngineEvent>.Continuation

    init(parser: TurboOutputParser, continuation: AsyncStream<EngineEvent>.Continuation) {
        self.parser = parser
        self.continuation = continuation
    }

    func handle(_ line: String, isError: Bool) {
        lock.lock()
        let events = parser.consume(line, isError: isError)
        lock.unlock()
        for event in events {
            continuation.yield(event)
        }
    }

    var repairedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parser.repairedCount
    }

    var unrecoverableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parser.unrecoverableCount
    }

    var recoverableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parser.recoverableCount
    }
}
