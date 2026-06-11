import Foundation

/// Document-level status line shown at the bottom of a set window. Green on OK end-states,
/// otherwise primary/red. Maps the original's `DocStatus0..16`. (ARCHITECTURE.md §3.2)
public enum DocStatus: Sendable, Equatable {
    case waitingToStart  // DocStatus16
    case checking  // DocStatus1/2
    case allFilesOK  // DocStatus5      (green)
    case repairing  // DocStatus2
    case restoredSuccessfully  // DocStatus7      (green)
    case restoredWithRenames  // DocStatus8      (green)
    /// Verify-only outcome: damage found and the recovery data suffices — awaiting consent.
    case repairNeeded  // DocStatus3
    case needMoreRecovery(blocks: Int)  // DocStatus4      (retryable)
    case onlyNonRecoverableMissing  // DocStatus13/14
    case notValid  // DocStatus9
    case internalError  // DocStatus15
    // Archive extraction (ROADMAP Phase 4; the original's unrar progress-window states).
    case extracting
    case extractedSuccessfully  // (green)
    case extractionFailed

    public var isGreenEndState: Bool {
        switch self {
        case .allFilesOK, .restoredSuccessfully, .restoredWithRenames, .extractedSuccessfully:
            return true
        default:
            return false
        }
    }
}
