import Foundation

public enum ParKind: Sendable, Equatable {
    case par1
    case par2
}

/// Immutable, parser-derived description of a PAR set. Produced by the native read-only parser in
/// Phase 1; the turbo engine (embedded or helper) is only the *actuator* and never the source of
/// truth. (ARCHITECTURE.md §1.3, §3.1)
public struct ParSet: Identifiable, Sendable {
    public let id: UUID
    public let kind: ParKind
    /// PAR2 slice size in bytes (a multiple of 4); 0 for PAR1.
    public let sliceSizeBytes: UInt64
    /// Number of source blocks; ≤ 32 768 for PAR2 (the GF(2¹⁶) limit).
    public let sourceBlockCount: Int
    public let recoveryBlocksAvailable: Int
    public let files: [FileEntry]
    /// The `.par2` files that contributed packets to this set — what `AutoDeletePnn` moves
    /// to the Trash after a successful restore. Empty for PAR1 until Phase 8 wires its
    /// verify path. (doc-01 §5.1; ROADMAP Phase 7)
    public let parFiles: [URL]

    public init(
        id: UUID = UUID(),
        kind: ParKind,
        sliceSizeBytes: UInt64 = 0,
        sourceBlockCount: Int = 0,
        recoveryBlocksAvailable: Int = 0,
        files: [FileEntry] = [],
        parFiles: [URL] = []
    ) {
        self.id = id
        self.kind = kind
        self.sliceSizeBytes = sliceSizeBytes
        self.sourceBlockCount = sourceBlockCount
        self.recoveryBlocksAvailable = recoveryBlocksAvailable
        self.files = files
        self.parFiles = parFiles
    }
}
