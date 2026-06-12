import Foundation

/// Identifies one window/session. Codable + Hashable so `WindowGroup(for:)` can restore it.
/// A ModernPAR "document" is not an editable file — it is a long-running, folder-scoped session.
/// (ARCHITECTURE.md §3.1)
public struct SessionRoute: Codable, Hashable, Sendable, Identifiable {
    public enum Mode: Codable, Hashable, Sendable {
        case verifyRepair  // open an existing PAR set, verify → repair
        case createSet  // author a new set in a folder
        case extractArchive  // unrar / unzip
    }

    public var id: UUID
    public var mode: Mode
    /// Security-scoped bookmark for the working FOLDER (the set lives beside its data files).
    public var folderBookmark: Data?
    /// Bookmark for the specific .par2 / .par / .rar the user opened, if any.
    public var anchorBookmark: Data?
    /// Whether a verify run may repair when repairable damage is found. False = verify-only
    /// (the awaiting-consent path: restored windows must never auto-fire a destructive repair).
    public var autoRepair: Bool
    /// Files this session already verified OK — a Retry skips re-hashing them (the original's
    /// "remembers OK files" behavior; ROADMAP Phase 8). Optional so routes persisted before
    /// this field decode cleanly; the engine re-checks existence/size before trusting it.
    public var assumeVerifiedNames: [String]?
    /// A `.createSet` window authoring PAR1 instead of PAR2 (the File ▸ New PAR 1 Set route).
    /// Optional for pre-Phase 8 route decoding.
    public var createsPar1: Bool?

    public init(
        id: UUID = UUID(),
        mode: Mode,
        folderBookmark: Data? = nil,
        anchorBookmark: Data? = nil,
        autoRepair: Bool = true,
        createsPar1: Bool? = nil
    ) {
        self.id = id
        self.mode = mode
        self.folderBookmark = folderBookmark
        self.anchorBookmark = anchorBookmark
        self.autoRepair = autoRepair
        self.createsPar1 = createsPar1
    }
}
