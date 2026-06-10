import AppKit

/// Dock-drop / open-with robustness. `onOpenURL` is the primary SwiftUI path, but the first dock
/// drop is known-flaky, so we keep an `NSApplicationDelegate` bridge for `application(_:open:)`.
/// (ARCHITECTURE.md §5.3, §8)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // Phase 2 wires this: round-trip each URL through `ScopedAccess.bookmark`, classify by
        // extension (.par2/.par/.rar), and `openWindow(value:)` a matching SessionRoute.
        // Phase 0 is a no-op so the app launches and accepts open-with without crashing.
    }
}
