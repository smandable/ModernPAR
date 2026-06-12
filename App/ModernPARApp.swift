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
    /// unrarshim for archive extraction (Phase 4). Preferences reach the extractors by value
    /// in `ExtractOptions`, captured on the main actor at run start (ROADMAP Phase 7).
    @State private var model = AppModel(
        // One injected engine, routed by anchor form: PAR2 → embedded turbo, PAR1 → the
        // native Swift engine (Phase 8 — no Intel binary anywhere).
        par2Engine: EngineRouter(par2: EmbeddedEngine(), par1: Par1Engine()),
        par2Creator: EmbeddedEngine(),
        par1Creator: Par1CreateEngine(),
        archiveExtractor: RARExtractor(),
        zipExtractor: ZipExtractor())

    /// Sparkle scaffolding — inert (controller nil, menu item disabled) until SUFeedURL +
    /// SUPublicEDKey are fully configured in Info.plist. (ROADMAP Phase 9)
    @State private var updaterSupport = UpdaterSupport()

    var body: some Scene {
        WindowGroup(for: SessionRoute.self) { $route in
            // Finder open-with / dock-drop routing lives inside SetWindow (OpenFilesClaimant):
            // a pristine window claims the first opened URL itself, so launching the app by
            // double-clicking a .par2 doesn't leave an extra empty window behind.
            SetWindow(route: route)
                .environment(model)
        } defaultValue: {
            // The original's "Default document type when program starts" (`DefaultPar`).
            SessionRoute(mode: model.settings.defaultMode)
        }
        .defaultSize(
            width: model.settings.lastWindowWidth > 0 ? model.settings.lastWindowWidth : 700,
            height: model.settings.lastWindowHeight > 0 ? model.settings.lastWindowHeight : 480
        )
        .handlesExternalEvents(matching: ["modernpar"])
        .commands {
            ModernPARCommands(model: model)
            UpdaterCommands(support: updaterSupport)
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("ModernPAR Help", id: "modernpar-help") {
            HelpView()
        }
        .windowResizability(.contentSize)

        Window("Acknowledgements", id: "modernpar-acknowledgements") {
            AcknowledgementsView()
        }
        .windowResizability(.contentSize)
    }
}
