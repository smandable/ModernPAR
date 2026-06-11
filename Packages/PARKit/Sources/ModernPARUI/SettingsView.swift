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

            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Keep files that fail their checksum (broken files)",
                    isOn: $settings.keepBrokenFiles)
                Text("More unrar options (destination, conflicts, segments) — Phase 7.")
                    .foregroundStyle(.secondary)
                Divider()
                // The UnRAR license's attribution obligation: ship this paragraph verbatim
                // in the app's documentation/acknowledgements. (ARCHITECTURE.md §1.4)
                ScrollView {
                    Text(Self.unrarAcknowledgement)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding()
            .tabItem { Label("Unrar", systemImage: "archivebox") }

            Text("Other options (CPU cores, updates) — Phase 7.")
                .foregroundStyle(.secondary).padding()
                .tabItem { Label("Other", systemImage: "ellipsis.circle") }
        }
        .frame(width: 480, height: 320)
    }

    /// RAR extraction is powered by RARLAB's UnRAR source (unrarsrc 7.2.4). The second
    /// paragraph is the license's mandatory attribution text, reproduced VERBATIM starting
    /// from "UnRAR source code" — do not edit it. (docs/research/05; ARCHITECTURE.md §1.4)
    static let unrarAcknowledgement = """
        RAR extraction is powered by the UnRAR utility, copyright © Alexander L. Roshal. \
        ModernPAR uses UnRAR for extraction only.

        UnRAR source code may be used in any software to handle \
        RAR archives without limitations free of charge, but cannot be \
        used to develop RAR (WinRAR) compatible archiver and to \
        re-create RAR compression algorithm, which is proprietary. \
        Distribution of modified UnRAR source code in separate form \
        or as a part of other software is permitted, provided that \
        full text of this paragraph, starting from "UnRAR source code" \
        words, is included in license, or in documentation if license \
        is not available, and in source code comments of resulting package.
        """
}
