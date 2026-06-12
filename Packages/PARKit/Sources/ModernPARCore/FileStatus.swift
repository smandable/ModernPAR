import Foundation

/// The MacPAR deLuxe per-file status vocabulary (`FileStatus0..10`), collapsed into a Swift enum
/// that preserves the crucial recoverable / non-recoverable distinction and the four status icons.
/// (ARCHITECTURE.md §3.2)
public enum FileStatus: Sendable, Equatable {
    case pending  // queued, not yet checked          (FileStatus0/16)
    case checking  // being hashed / matched now
    case ok  // verified OK                      (FileStatus1)
    case recoverableMissing  // missing, but recoverable         (FileStatus5)
    case recoverableCorrupt  // bad checksum, but recoverable    (FileStatus7)
    case unrecoverableMissing  // missing, cannot recover          (FileStatus6)
    case unrecoverableCorrupt  // bad checksum, cannot recover     (FileStatus8)
    case recovered  // repaired this run                (FileStatus9)
    case renamed(from: String)  // OK after renaming                (FileStatus3)
    case notInSet  // present but not part of parity   (FileStatus10)
    case possibleError  // might be recoverable             (FilePossibleErrorIcon)

    public var icon: StatusIcon {
        switch self {
        case .ok, .recovered, .renamed:
            // .renamed is the original's "OK after renaming" (FileStatus3) — an OK state.
            return .ok
        case .recoverableMissing, .recoverableCorrupt, .possibleError:
            return .recoverable
        case .unrecoverableMissing, .unrecoverableCorrupt:
            return .error
        case .notInSet:
            return .notInVolumeSet
        case .pending, .checking:
            return .neutral
        }
    }

    public var isRecoverable: Bool {
        switch self {
        case .recoverableMissing, .recoverableCorrupt, .possibleError:
            return true
        default:
            return false
        }
    }

    /// Terminal-OK states are *sticky* across a re-run, reproducing the original's
    /// "remember files already OK and skip them on Retry" behavior. (ARCHITECTURE.md §3.2)
    public var isTerminalOK: Bool { self == .ok || self == .recovered }

    /// What Edit ▸ Select All Non-OK selects (the original's `onSelectAllNonOK:`, v3.7):
    /// every file with a problem — damaged, missing, or suspect. OK-family, not-yet-checked,
    /// and not-in-set rows don't qualify. (doc-01 §7.1; ROADMAP Phase 7)
    public var isNonOK: Bool {
        switch self {
        case .recoverableMissing, .recoverableCorrupt, .unrecoverableMissing,
            .unrecoverableCorrupt, .possibleError:
            return true
        case .ok, .recovered, .renamed, .pending, .checking, .notInSet:
            return false
        }
    }
}

/// Maps to the original's status icons (FileOKIcon / FileRecoverableIcon / FileErrorIcon /
/// FileNotInVolumeSetIcon).
public enum StatusIcon: Sendable {
    case neutral
    case ok
    case recoverable
    case error
    case notInVolumeSet
}
