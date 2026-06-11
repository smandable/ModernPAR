import Foundation

/// Persists the one-time "grant this folder" powerbox results as app-scoped security-scoped
/// bookmarks, so re-opening a set never re-prompts. Opening a single `.par2` grants only that
/// file; verify/repair needs the whole folder. (ARCHITECTURE.md §5.2; ROADMAP Phase 3)
public enum FolderAccessStore {
    private static let defaultsKey = "FolderAccessBookmarks"

    /// Remembers a folder the user granted via the open panel (the panel URL itself carries
    /// the grant; the bookmark makes it durable across launches).
    public static func remember(_ folderURL: URL) {
        guard let bookmark = try? ScopedAccess.bookmark(for: folderURL) else { return }
        var stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
        stored[folderURL.standardizedFileURL.path] = bookmark
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    /// A stored bookmark for `folderURL` (or an ancestor — a grant on a parent covers children).
    public static func bookmark(forFolder folderURL: URL) -> Data? {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
        var path = folderURL.standardizedFileURL.path
        while true {
            if let bookmark = stored[path] { return bookmark }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return nil }
            path = parent
        }
    }

    /// Test/maintenance hook.
    public static func removeAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

/// Bridges Finder open-with / dock-drop URLs from the AppKit delegate (App target) to the
/// SwiftUI layer (package): events can arrive before any view exists at cold launch, so URLs
/// buffer until a window installs the handler. (ROADMAP Phase 3)
@MainActor
public enum OpenFilesBroker {
    private static var handler: (([URL]) -> Void)?
    private static var pendingURLs: [URL] = []

    public static func installHandler(_ newHandler: @escaping ([URL]) -> Void) {
        handler = newHandler
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            newHandler(urls)
        }
    }

    public static func deliver(_ urls: [URL]) {
        if let handler {
            handler(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }
}

/// Tracks in-flight operations app-wide so quit can be blocked while work is running
/// (`applicationShouldTerminate` → ask). Sessions are held WEAKLY: a window closed mid-parse
/// deallocates its session, and a strong identifier set would block quit for the rest of the
/// launch on an operation that no longer exists. (ROADMAP Phase 3)
@MainActor
public final class OperationRegistry {
    public static let shared = OperationRegistry()
    private let busySessions = NSHashTable<AnyObject>.weakObjects()

    public var busyCount: Int { busySessions.allObjects.count }

    public func setBusy(_ busy: Bool, session: AnyObject) {
        if busy {
            busySessions.add(session)
        } else {
            busySessions.remove(session)
        }
    }
}
