import ArchiveKit
import ModernPARCore
import ModernPARUI
import Par2Kit
import SwiftUI

/// The app shell: one window per `SessionRoute`, a Settings scene, and the menu commands.
/// We use `WindowGroup(for:)` rather than `DocumentGroup` because a ModernPAR "document" is a
/// long-running, folder-scoped session, not an editable file. (ARCHITECTURE.md §7.1)
@main
struct ModernPARApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The real engines, injected behind their protocols without touching the UI, exactly as
    /// the seams were designed: par2cmdline-turbo via Par2Shim (`MockEngine` remains for
    /// tests/previews; `HelperProcessEngine` is the fallback), and RARLAB UnRAR via
    /// unrarshim for archive extraction (Phase 4). The keep-broken-files preference is read
    /// per run through UserDefaults (`Settings` mirrors the same key) because the engine
    /// evaluates it off the main actor.
    @State private var model = AppModel(
        par2Engine: EmbeddedEngine(),
        archiveExtractor: RARExtractor(keepBrokenFiles: {
            UserDefaults.standard.bool(forKey: Settings.keepBrokenKey)
        }))

    var body: some Scene {
        WindowGroup(for: SessionRoute.self) { $route in
            // Finder open-with / dock-drop routing lives inside SetWindow (OpenFilesClaimant):
            // a pristine window claims the first opened URL itself, so launching the app by
            // double-clicking a .par2 doesn't leave an extra empty window behind.
            SetWindow(route: route)
                .environment(model)
        } defaultValue: {
            SessionRoute(mode: .verifyRepair)
        }
        .handlesExternalEvents(matching: ["modernpar"])
        .commands { ModernPARCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
