import Foundation
import Observation

/// A recently-opened set. We hand-roll "Open Recent" because the WindowGroup scene model does not
/// inherit `NSDocumentController`. (ARCHITECTURE.md §7.1)
public struct RecentItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public var folderBookmark: Data

    public init(id: UUID = UUID(), displayName: String, folderBookmark: Data) {
        self.id = id
        self.displayName = displayName
        self.folderBookmark = folderBookmark
    }
}

@MainActor
@Observable
public final class RecentsStore {
    public private(set) var items: [RecentItem] = []
    private let limit = 20

    public init() {}

    public func add(_ item: RecentItem) {
        items.removeAll { $0.folderBookmark == item.folderBookmark }
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }
}
