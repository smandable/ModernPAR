import Combine
import ModernPARCore
import Sparkle
import SwiftUI

/// Sparkle scaffolding (ROADMAP Phase 9; doc-06 §6). The updater starts only when Info.plist
/// carries a complete configuration — `SUFeedURL` plus a real `SUPublicEDKey` — per
/// `UpdaterConfiguration`. Until the EdDSA key is generated and feed hosting is decided, the
/// controller stays nil and "Check for Updates…" is disabled: Sparkle must never run against
/// a half-configured feed (it alerts at launch and asserts in debug builds).
///
/// Sandbox notes baked into the build, not here: the installer-launcher XPC service is ON
/// (`SUEnableInstallerLauncherService`), the downloader service stays OFF because the app
/// already holds `network.client`, and the two mach-lookup temporary exceptions live in
/// ModernPAR.entitlements.
@MainActor
final class UpdaterSupport {
    /// nil while the Info.plist configuration is incomplete.
    let controller: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary
        let configured = UpdaterConfiguration.isConfigured(
            feedURL: info?["SUFeedURL"] as? String,
            publicEDKey: info?["SUPublicEDKey"] as? String)
        controller =
            configured
            ? SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }
}

/// App-menu "Check for Updates…", mirroring the original's placement. Enabled only while
/// Sparkle reports a check is possible — and never when the updater is unconfigured.
struct UpdaterCommands: Commands {
    let support: UpdaterSupport

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if let updater = support.controller?.updater {
                CheckForUpdatesButton(updater: updater)
            } else {
                Button("Check for Updates…") {}
                    .disabled(true)
            }
        }
    }
}

/// Sparkle's documented SwiftUI pattern: drive the menu item's enabled state from the
/// updater's KVO-compliant `canCheckForUpdates` (false mid-check or mid-install).
private struct CheckForUpdatesButton: View {
    let updater: SPUUpdater
    @State private var canCheckForUpdates = false

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!canCheckForUpdates)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheckForUpdates = $0 }
    }
}
