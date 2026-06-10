import Foundation

/// The PAR2/PAR1 engine seam — the single point of swappability.
///
/// Iterating the returned stream starts the operation; cancel by cancelling the consuming `Task`
/// (the embedded engine's progress callback then returns false, the helper engine's child process
/// is terminated, and the native PAR1 engine stops its loop). The embedded PAR2 engine, the
/// helper-process fallback, and the native-Swift PAR1 path all conform to this, and a future PAR3
/// backend slots in behind it without touching the UI. (ARCHITECTURE.md §1.5, §6)
public protocol PAR2Engine: Sendable {
    func run(_ route: SessionRoute) -> AsyncStream<EngineEvent>
}
