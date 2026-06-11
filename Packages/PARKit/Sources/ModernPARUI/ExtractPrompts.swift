import AppKit
import ModernPARCore
import UserNotifications

/// Modal password prompt for protected archives — the original's modal dialog, AppKit-style
/// like the other powerbox panels. (ROADMAP Phase 4 "password prompt-once-and-reuse": the
/// engine caches the first answer for the whole archive; this prompt fires once per run.)
@MainActor
enum PasswordPrompt {
    static func present(archiveName: String, previousAttemptFailed: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText =
            previousAttemptFailed
            ? "Wrong password for “\(archiveName)”" : "Password required"
        alert.informativeText =
            previousAttemptFailed
            ? "The password did not match. Enter the password to try again."
            : "“\(archiveName)” is password-protected. Enter the password to extract it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Extract")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let password = field.stringValue
        return password.isEmpty ? nil : password
    }
}

/// Bridges the engine's async password request to the modal prompt on the main actor.
/// The engine thread waits cooperatively (cancellable) while the prompt is up.
public final class UIPasswordProvider: PasswordProvider {
    private let previousAttemptFailed: Bool

    public init(previousAttemptFailed: Bool = false) {
        self.previousAttemptFailed = previousAttemptFailed
    }

    public func password(forVolume name: String) async -> String? {
        let failed = previousAttemptFailed
        return await MainActor.run {
            PasswordPrompt.present(archiveName: name, previousAttemptFailed: failed)
        }
    }
}

/// The destination-conflict dialog: ask / overwrite / keep-both / cancel. (ROADMAP Phase 4;
/// the per-preference default answer arrives with the Phase 7 Settings work.)
public struct UIConflictResolver: ConflictResolver {
    public init() {}

    public func resolve(conflictAt url: URL) async -> ConflictPolicy {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” already exists"
            alert.informativeText =
                "The destination folder already contains an item with this name. Overwrite moves the existing item to the Trash."
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .keepBoth
            case .alertSecondButtonReturn: return .overwrite
            default: return .cancel
            }
        }
    }
}

/// Posts the "extraction finished" notification with Show in Finder. (ROADMAP Phase 4
/// demoable milestone: "a notification fires with Show in Finder".)
@MainActor
public final class ExtractionNotifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = ExtractionNotifier()
    private var prepared = false

    /// Must run before app launch finishes (AppDelegate): the system delivers notification
    /// clicks only to a delegate installed by then, and the action category must already be
    /// registered when a click on an old (pre-relaunch) notification arrives.
    public func prepare() {
        // UNUserNotificationCenter traps outside a real app bundle (previews, swift test).
        guard Bundle.main.bundleIdentifier != nil, !prepared else { return }
        prepared = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let show = UNNotificationAction(identifier: "show-in-finder", title: "Show in Finder")
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "extraction-finished", actions: [show], intentIdentifiers: [])
        ])
    }

    public func notifyExtractionFinished(of url: URL) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        prepare()
        let content = UNMutableNotificationContent()
        content.title = "Extraction finished"
        content.body = "“\(url.lastPathComponent)” was extracted."
        content.userInfo = ["path": url.path]
        content.categoryIdentifier = "extraction-finished"
        content.sound = .default
        let center = UNUserNotificationCenter.current()
        // Post from the authorization completion: adding while authorization is still
        // undetermined silently drops the very first notification.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(
                UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // Banner even while the app is frontmost (a background extraction window may be hidden).
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Both the default click and the explicit action reveal the output.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let path = response.notification.request.content.userInfo["path"] as? String
        else { return }
        let url = URL(fileURLWithPath: path)
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
