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

    public init(
        id: UUID = UUID(),
        mode: Mode,
        folderBookmark: Data? = nil,
        anchorBookmark: Data? = nil
    ) {
        self.id = id
        self.mode = mode
        self.folderBookmark = folderBookmark
        self.anchorBookmark = anchorBookmark
    }
}
