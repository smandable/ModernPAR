import Foundation
import ModernPARCore

/// PAR2 via the bundled `par2` CLI helper (par2cmdline-turbo), driven over a `Foundation.Process`
/// boundary. The designed-in fallback to the primary embedded engine — and the standby GPL license
/// firewall should a non-GPL build ever be needed. (ARCHITECTURE.md §0, §1.1, §6)
///
/// Phase 0 is a compiling stub. Phase 2 fills in: launch the helper with `ArgumentBuilder` args,
/// stream stdout/stderr, parse lines into `EngineEvent`s via a version-pinned, snapshot-tested
/// parser, and reconcile against the native parser's file roster.
public actor HelperProcessEngine: PAR2Engine {
    private let helperURL: URL

    public init(helperURL: URL) {
        self.helperURL = helperURL
    }

    public nonisolated func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            continuation.yield(.logLine("HelperProcessEngine is not implemented yet (Phase 2)."))
            continuation.yield(.finished(.failure(.notImplemented)))
            continuation.finish()
        }
    }
}
