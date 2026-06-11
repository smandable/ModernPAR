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

    /// The real embedded engine (par2cmdline-turbo via Par2Shim) — swapped in behind the
    /// `PAR2Engine` protocol without touching the UI, exactly as the seam was designed.
    /// (`MockEngine` remains for tests/previews; `HelperProcessEngine` is the fallback.)
    @State private var model = AppModel(par2Engine: EmbeddedEngine())

    var body: some Scene {
        WindowGroup(for: SessionRoute.self) { $route in
            SetWindow(route: route)
                .environment(model)
        } defaultValue: {
            SessionRoute(mode: .verifyRepair)
        }
        .handlesExternalEvents(matching: ["modernpar"])
        .commands { ModernPARCommands() }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
