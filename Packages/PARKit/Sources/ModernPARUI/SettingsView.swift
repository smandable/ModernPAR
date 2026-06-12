import AppKit
import ModernPARCore
import SwiftUI

/// Tabbed Settings mirroring the original's six Preferences panes — Basic / Par1 / Par2 /
/// Unrar / Post-processing / Other — every control bound to a persisted value under the
/// original's defaults key (doc-01 §5). Validation messages reproduce the originals.
/// (ROADMAP Phase 7)
public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    public init() {}

    public var body: some View {
        @Bindable var settings = model.settings
        TabView {
            basicTab(settings: $settings)
                .tabItem { Label("Basic", systemImage: "gearshape") }
            par1Tab(settings: $settings)
                .tabItem { Label("Par 1", systemImage: "1.circle") }
            par2Tab(settings: $settings)
                .tabItem { Label("Par 2", systemImage: "shield") }
            unrarTab(settings: $settings)
                .tabItem { Label("Unrar", systemImage: "archivebox") }
            postProcessingTab(settings: $settings)
                .tabItem { Label("Post-processing", systemImage: "arrow.right.doc.on.clipboard") }
            otherTab(settings: $settings)
                .tabItem { Label("Other", systemImage: "ellipsis.circle") }
        }
        .frame(width: 560, height: 480)
    }

    // MARK: - Basic (doc-01 §5.1)

    private func basicTab(settings: Bindable<ModernPARCore.Settings>) -> some View {
        Form {
            Picker("Default document type:", selection: settings.defaultMode) {
                Text("Verify / Repair").tag(SessionRoute.Mode.verifyRepair)
                Text("Create PAR Set").tag(SessionRoute.Mode.createSet)
            }
            Toggle("Repair automatically after verifying", isOn: settings.autoRepair)
            Toggle(
                "Move PAR files to the Trash after a successful restore",
                isOn: settings.autoDeleteParFiles)
            Toggle(
                "Close the window after automatic post-processing",
                isOn: settings.autoCloseAfterPostProcess)
            Toggle("Run unattended", isOn: settings.unattendedOperation)
            Text(
                "Unattended operation never shows dialogs: passwords are declined, name conflicts keep both items, and errors arrive as notifications."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: - Par1 (doc-01 §5.2 — consumed by Phase 8's native PAR1 create)

    private func par1Tab(settings: Bindable<ModernPARCore.Settings>) -> some View {
        Form {
            Section("Number of Pnn files to generate") {
                Picker("Method:", selection: settings.par1VolumeMode) {
                    Text("Based on the number of files")
                        .tag(ModernPARCore.Settings.Par1VolumeMode.byFileCount)
                    Text("Fixed number, independent of the number of files")
                        .tag(ModernPARCore.Settings.Par1VolumeMode.fixed)
                }
                .pickerStyle(.radioGroup)

                if model.settings.par1VolumeMode == .byFileCount {
                    TextField(
                        "Files per Pnn volume:", value: settings.par1FilesPerVolume,
                        format: .number)
                    if !(1...99).contains(model.settings.par1FilesPerVolume) {
                        validationText("The number of files must be a number between 1 and 99")
                    }
                } else {
                    TextField(
                        "Number of Pnn files:", value: settings.par1FixedVolumeCount,
                        format: .number)
                    if !(0...99).contains(model.settings.par1FixedVolumeCount) {
                        validationText("The number of Pnn files must be a number between 0 and 99")
                    }
                }
            }
            Text(
                "PAR1 creation arrives with the native PAR1 engine (Phase 8); these defaults are saved now."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: - Par2 (doc-01 §5.3 — the defaults a new create window starts from)

    private func par2Tab(settings: Bindable<ModernPARCore.Settings>) -> some View {
        Form {
            Section {
                TextField(
                    "Level of redundancy (%):", value: settings.par2Redundancy,
                    format: .number)
                if !CreateOptions.redundancyRange.contains(model.settings.par2Redundancy) {
                    validationText("The redundancy percentage must be a number between 1 and 100")
                }
            }
            Section("Block size") {
                Picker("Block size:", selection: settings.par2BlockSizeAutomatic) {
                    Text("Automatic").tag(true)
                    Text("Manual (KB)").tag(false)
                }
                .pickerStyle(.radioGroup)
                if !model.settings.par2BlockSizeAutomatic {
                    TextField(
                        "Block size (KB):", value: settings.par2BlockSizeKB,
                        format: .number)
                    if !CreateOptions.blockSizeKilobytesRange.contains(
                        model.settings.par2BlockSizeKB)
                    {
                        validationText("The block size must be a number between 1 and 419430")
                    }
                }
                Text(
                    "When uploading to Usenet, set the block size to the size of the data attached to each article. Automatic derives it from the combined size of the files."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Toggle(
                "Limit par2 file size to match largest data file",
                isOn: settings.par2LimitFileSize)
        }
        .formStyle(.grouped)
    }

    // MARK: - Unrar (doc-01 §5.4)

    private func unrarTab(settings: Bindable<ModernPARCore.Settings>) -> some View {
        UnrarTab(settings: model.settings)
    }

    // MARK: - Post-processing (doc-01 §5.5)

    private func postProcessingTab(settings: Bindable<ModernPARCore.Settings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Automatically post-process files after repair",
                isOn: settings.autoPostProcess)
            Text(
                "After a set verifies or repairs successfully, the first rule (top to bottom) whose pattern matches a file in the set fires — one rule per set. When off, use Operation ▸ Apply Rule."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            RuleEditorView()
        }
        .padding(20)
    }

    // MARK: - Other (doc-01 §5.6)

    private func otherTab(settings: Bindable<ModernPARCore.Settings>) -> some View {
        Form {
            Picker(
                "When opening multiple files at the same time:",
                selection: settings.simultaneousProcessing
            ) {
                Text("Process them one by one").tag(false)
                Text("Process them simultaneously").tag(true)
            }
            .pickerStyle(.radioGroup)
            Text(
                "Simultaneous processing runs every window's operation at once, which can thrash slower disks."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func validationText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
    }
}

/// The Unrar pane: keep-broken, destination, conflicts, segments, filename encoding, and the
/// mandatory UnRAR attribution. Split out because the destination picker and the
/// permanent-delete warning carry their own state. (doc-01 §5.4)
private struct UnrarTab: View {
    @Bindable var settings: ModernPARCore.Settings
    @State private var confirmingPermanentDelete = false

    var body: some View {
        Form {
            Toggle("Keep incorrectly expanded (broken) files", isOn: $settings.keepBrokenFiles)

            Section("Where must unrar create the extracted items") {
                Picker("Destination:", selection: $settings.unrarDestinationChoice) {
                    Text("Inside the folder where the archive is")
                        .tag(UnrarDestinationChoice.besideArchive)
                    Text("Always let me choose a location").tag(UnrarDestinationChoice.ask)
                    Text("Inside this folder:").tag(UnrarDestinationChoice.fixed)
                }
                .pickerStyle(.radioGroup)
                if settings.unrarDestinationChoice == .fixed {
                    LabeledContent("Folder:") {
                        HStack {
                            Text(
                                settings.unrarDestinationDisplayName.isEmpty
                                    ? "None selected" : settings.unrarDestinationDisplayName
                            )
                            .foregroundStyle(
                                settings.unrarDestinationDisplayName.isEmpty
                                    ? .secondary : .primary)
                            Button("Choose…") { chooseFixedFolder() }
                        }
                    }
                }
            }

            Picker("If the destination already exists:", selection: $settings.conflictDefault) {
                Text("Ask what to do").tag(ConflictPolicy.ask)
                Text("Overwrite the existing item").tag(ConflictPolicy.overwrite)
                Text("Keep both (rename the new one)").tag(ConflictPolicy.keepBoth)
                Text("Cancel the extraction").tag(ConflictPolicy.cancel)
            }

            Section("After a successful unrar") {
                // Permanent deletion bypasses the Trash, so the setting must NEVER hold (or
                // persist) .deletePermanently until the warning is confirmed — a quit while
                // the alert is up, or an extraction starting meanwhile, would otherwise act
                // on an unconfirmed destructive choice. The proxy binding routes that one
                // selection through the alert instead of the setting. (Phase 7 review)
                Picker("Segments:", selection: segmentDisposalProxy) {
                    Text("Move segments to the Trash").tag(SegmentDisposal.moveToTrash)
                    Text("Leave segments alone").tag(SegmentDisposal.leave)
                    Text("Delete segments permanently").tag(SegmentDisposal.deletePermanently)
                }
                .pickerStyle(.radioGroup)
            }

            Picker(
                "File name encoding (legacy archives):",
                selection: $settings.filenameEncodingIANAName
            ) {
                Text("Automatic (UTF-8, ask when unclear)").tag("")
                ForEach(Self.encodingChoices, id: \.iana) { choice in
                    Text(choice.label).tag(choice.iana)
                }
            }

            Section {
                // The UnRAR license's attribution obligation: ship this paragraph verbatim
                // in the app's documentation/acknowledgements. (ARCHITECTURE.md §1.4)
                Text(SettingsView.unrarAcknowledgement)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .alert("Delete segments permanently?", isPresented: $confirmingPermanentDelete) {
            Button("Delete Permanently", role: .destructive) {
                settings.segmentDisposal = .deletePermanently
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "After a successful extraction the archive segments will be deleted immediately, bypassing the Trash. This cannot be undone."
            )
        }
    }

    /// Reads the live setting; arming `.deletePermanently` is deferred to the alert's
    /// confirm button, so the radio shows the pending choice only while the alert is up.
    private var segmentDisposalProxy: Binding<SegmentDisposal> {
        Binding(
            get: {
                confirmingPermanentDelete ? .deletePermanently : settings.segmentDisposal
            },
            set: { choice in
                if choice == .deletePermanently {
                    confirmingPermanentDelete = true
                } else {
                    settings.segmentDisposal = choice
                }
            })
    }

    private func chooseFixedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder where extracted items will always be placed."
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = try? ScopedAccess.bookmark(for: url) else {
            // A silent dead end would leave the user staring at "None selected" — name the
            // failure (exotic network/ejectable volumes can refuse bookmarks).
            let alert = NSAlert()
            alert.messageText = "This folder cannot be used"
            alert.informativeText =
                "ModernPAR could not create a persistent grant for “\(url.lastPathComponent)”. Choose a folder on a local volume."
            alert.runModal()
            return
        }
        settings.unrarDestinationBookmark = bookmark
        settings.unrarDestinationDisplayName = url.lastPathComponent
    }

    /// Curated legacy-RAR name encodings (IANA names), mirroring the original's
    /// EncodingSelection table. (doc-01 §3.7)
    static let encodingChoices: [(iana: String, label: String)] = [
        ("windows-1252", "Western (Windows Latin 1)"),
        ("windows-1250", "Central European (Windows)"),
        ("windows-1251", "Cyrillic (Windows)"),
        ("ibm866", "Cyrillic (DOS)"),
        ("ibm437", "Latin-US (DOS)"),
        ("shift_jis", "Japanese (Shift JIS)"),
        ("euc-kr", "Korean (EUC)"),
        ("gb18030", "Chinese Simplified (GB18030)"),
        ("big5", "Chinese Traditional (Big5)"),
        ("windows-1253", "Greek (Windows)"),
        ("windows-1254", "Turkish (Windows)"),
        ("windows-1255", "Hebrew (Windows)"),
        ("windows-1256", "Arabic (Windows)"),
    ]
}

extension SettingsView {
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
