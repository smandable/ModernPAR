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
        case .ok, .recovered:
            return .ok
        case .recoverableMissing, .recoverableCorrupt, .possibleError:
            return .recoverable
        case .unrecoverableMissing, .unrecoverableCorrupt:
            return .error
        case .notInSet:
            return .notInVolumeSet
        case .pending, .checking, .renamed:
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
