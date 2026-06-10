import Foundation

/// Security-scoped bookmark round-trip. Mandatory for URLs arriving via drag-drop or dock-open,
/// which are NOT auto-scoped (`startAccessingSecurityScopedResource()` returns `false` on them).
/// Converting to a `.withSecurityScope` bookmark and resolving it back yields a usable, persistable
/// grant — and is exactly what the bundled helper and the RAR engine need anyway.
/// (ARCHITECTURE.md §5.2)
public enum ScopedAccess {
    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a bookmark and begin access. The caller must balance a `true` `didStart` with
    /// `url.stopAccessingSecurityScopedResource()` in a `defer`.
    public static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool, didStart: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale, url.startAccessingSecurityScopedResource())
    }
}
