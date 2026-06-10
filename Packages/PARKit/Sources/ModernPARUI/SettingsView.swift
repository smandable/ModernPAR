import ModernPARCore
import SwiftUI

/// Tabbed Settings mirroring the original's Preferences panes. Phase 7 binds these to real
/// persisted values; Phase 0 ships the tab shell so Cmd-, works. (ARCHITECTURE.md §7.2)
public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    public init() {}

    public var body: some View {
        @Bindable var settings = model.settings
        TabView {
            Form {
                Picker("Default document type:", selection: $settings.defaultMode) {
                    Text("Verify / Repair").tag(SessionRoute.Mode.verifyRepair)
                    Text("Create PAR Set").tag(SessionRoute.Mode.createSet)
                }
                Toggle("Repair automatically after verifying", isOn: $settings.autoRepair)
                Toggle("Move PAR files to Trash after success", isOn: $settings.autoDeleteParFiles)
            }
            .formStyle(.grouped)
            .tabItem { Label("Basic", systemImage: "gearshape") }

            Text("PAR2 creation options (redundancy, block size) — Phase 7.")
                .foregroundStyle(.secondary).padding()
                .tabItem { Label("Par2", systemImage: "shield") }

            Text("Unrar options (destination, conflicts, segments) — Phase 7.")
                .foregroundStyle(.secondary).padding()
                .tabItem { Label("Unrar", systemImage: "archivebox") }

            Text("Other options (CPU cores, updates) — Phase 7.")
                .foregroundStyle(.secondary).padding()
                .tabItem { Label("Other", systemImage: "ellipsis.circle") }
        }
        .frame(width: 480, height: 320)
    }
}
