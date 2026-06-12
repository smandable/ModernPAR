import Foundation

/// Document-level status line shown at the bottom of a set window. Green on OK end-states,
/// otherwise primary/red. Maps the original's `DocStatus0..16`. (ARCHITECTURE.md §3.2)
public enum DocStatus: Sendable, Equatable {
    case waitingToStart  // DocStatus16
    /// The user cancelled the running operation (⌘., the Cancel button, or a dialog).
    case cancelled  // DocStatus3
    /// A create window with files staged but nothing written yet.
    case newParFileNeeded  // DocStatus10
    case checking  // DocStatus1/2
    case allFilesOK  // DocStatus5      (green)
    /// A rename-only repair: nothing was rebuilt, the files just got their roster names back.
    case allFilesOKWithRenames  // DocStatus6      (green)
    case repairing  // DocStatus2
    case restoredSuccessfully  // DocStatus7      (green)
    case restoredWithRenames  // DocStatus8      (green)
    /// Verify-only outcome: damage found and the recovery data suffices — awaiting consent.
    case repairNeeded  // DocStatus3
    case needMoreRecovery(blocks: Int)  // DocStatus4      (retryable; PAR2 counts blocks)
    /// PAR1 counts whole FILES, not blocks (each volume restores exactly one file).
    case needMoreFiles(count: Int)  // DocStatus4/4A   (retryable)
    /// Enough volumes exist but the spec's Vandermonde submatrix is singular for this damage
    /// combination — a PAR1 format flaw, structurally unrecoverable.
    case cannotRestore  // DocStatus4B
    case onlyNonRecoverableMissing  // DocStatus13
    case onlyNonRecoverableMissingWithRenames  // DocStatus14
    case notValid  // DocStatus9
    case internalError  // DocStatus15
    // Archive extraction (ROADMAP Phase 4; the original's unrar progress-window states).
    case extracting
    case extractedSuccessfully  // (green)
    case extractionFailed
    // Create (ROADMAP Phase 6; the original's create progress states).
    case creating
    case createdSuccessfully  // (green)
    case createFailed

    public var isGreenEndState: Bool {
        switch self {
        case .allFilesOK, .allFilesOKWithRenames, .restoredSuccessfully, .restoredWithRenames,
            .extractedSuccessfully, .createdSuccessfully:
            return true
        default:
            return false
        }
    }

    /// Terminal failure outcomes — what unattended operation surfaces as a user notification
    /// instead of a dialog (doc-01 §5.1 `UnattendedOperation`). Consent states like
    /// `repairNeeded` are not failures.
    public var isFailureEndState: Bool {
        switch self {
        case .notValid, .internalError, .extractionFailed, .createFailed, .needMoreRecovery,
            .needMoreFiles, .cannotRestore:
            return true
        default:
            return false
        }
    }
}
