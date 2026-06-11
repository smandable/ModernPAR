import AppKit
import ModernPARCore
import ModernPARUI

/// AppKit bridges SwiftUI cannot cover: Finder open-with / dock-drop delivery, blocking quit
/// while an operation is running, and notification-center wiring that must exist before any
/// notification is clicked. (ARCHITECTURE.md §5.3, §8; ROADMAP Phase 3–4)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // The notification delegate must be installed before launch finishes, or clicking
            // a delivered "extraction finished" notification after a relaunch does nothing.
            ExtractionNotifier.shared.prepare()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            OpenFilesBroker.deliver(urls)
        }
    }

    /// "Quit disabled while any session busy" — a running repair/extraction must not be killed
    /// mid-write without the user insisting. Also waits on engines that are still UNWINDING
    /// after a window closed (they own staging/files until their cleanup runs).
    /// (ROADMAP Phase 3–4)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let busy = OperationRegistry.shared.busyCount > 0
            let draining = EngineDrainRegistry.shared.activeCount > 0
            guard busy || draining else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText =
                busy ? "An operation is still running" : "An operation is still finishing up"
            alert.informativeText =
                busy
                ? "Quitting now interrupts the running operation (verify, repair, or extraction). It can be run again later, but quitting mid-write leaves partially written files."
                : "A cancelled operation is still cleaning up its working files. Quitting this instant may leave leftovers behind — try again in a moment."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
    }
}
