import AppKit
import ModernPARCore

/// AppKit bridges SwiftUI cannot cover: Finder open-with / dock-drop delivery, and blocking
/// quit while an operation is running. (ARCHITECTURE.md §5.3, §8; ROADMAP Phase 3)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            OpenFilesBroker.deliver(urls)
        }
    }

    /// "Quit disabled while any session busy" — a running repair must not be killed mid-write
    /// without the user insisting. (ROADMAP Phase 3)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard OperationRegistry.shared.busyCount > 0 else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "An operation is still running"
            alert.informativeText =
                "Quitting now interrupts the running verify/repair. The set can be repaired again later, but quitting mid-repair leaves partially written files."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
    }
}
