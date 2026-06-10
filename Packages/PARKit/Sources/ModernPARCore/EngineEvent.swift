import Foundation

/// The single event stream that every engine emits — the embedded PAR2 engine, the helper-process
/// fallback, and the native PAR1 engine — so the UI is engine-agnostic. (ARCHITECTURE.md §4.1)
public enum EngineEvent: Sendable {
    case scanningStarted(totalFiles: Int)
    /// The file roster for this set. Emitted by the native parser (the source of truth) before
    /// verification, so the UI can paint the status grid immediately. (ARCHITECTURE.md §1.3)
    case filesDiscovered([FileEntry])
    case fileStatusChanged(id: UUID, status: FileStatus)
    case overallProgress(fraction: Double)  // 0...1
    case logLine(String)  // raw helper output → "Show par Output" pane
    case docStatusChanged(DocStatus)
    case finished(Result<OperationSummary, EngineError>)
}

public struct OperationSummary: Sendable, Equatable {
    public var repaired: Int
    public var stillMissing: Int
    public init(repaired: Int = 0, stillMissing: Int = 0) {
        self.repaired = repaired
        self.stillMissing = stillMissing
    }
}

public enum EngineError: Error, Sendable, Equatable {
    case notImplemented
    case launchFailed(String)
    case cancelled
    case engine(code: Int32, message: String)
}
