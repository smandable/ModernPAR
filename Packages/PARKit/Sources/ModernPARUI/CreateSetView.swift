import AppKit
import ModernPARCore
import SwiftUI
import UniformTypeIdentifiers

/// The build-a-set window (ROADMAP Phase 6): add source files (all in one folder), pick
/// redundancy / block size / scheme, and Create → a `.par2` index + recovery volumes land in
/// the source folder. Runs through the same `OperationSession` + `EngineEvent` machinery as
/// verify/extract, so progress, the output pane, and cancellation are identical.
struct CreateSetView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: OperationSession
    @State private var create = CreateModel()
    @State private var selection: Set<URL> = []
    @State private var outputName: String = ""
    @State private var showOutput = true

    var body: some View {
        @Bindable var create = create
        VStack(spacing: 0) {
            fileList
            Divider()
            optionsForm
            if showOutput {
                Divider()
                ParOutputPane(lines: session.log)
            }
            Divider()
            StatusBar(
                docStatus: session.docStatus, progress: session.progress,
                isBusy: session.isBusy, onCancel: { session.cancel() })
        }
        .frame(minWidth: 560, minHeight: 460)
        .navigationTitle("New PAR Set")
        .focusedSceneValue(\.activeSession, session)
        .dropDestination(for: URL.self) { urls, _ in
            guard !session.isBusy else { return false }
            create.add(urls)
            return true
        }
        .onChange(of: session.docStatus) { _, status in
            // Reveal the created set in Finder on success (the original's behavior).
            guard status == .createdSuccessfully, let placed = session.placedURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([placed])
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let urls = AddFilesPanel.present(startingIn: create.folder) {
                        create.add(urls)
                    }
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .help("Add source files to protect (all must be in one folder)")
                .disabled(session.isBusy)

                Button {
                    showOutput.toggle()
                } label: {
                    Label("par Output", systemImage: "text.alignleft")
                }
                .help(showOutput ? "Hide par Output" : "Show par Output")

                if session.placedURL != nil && session.docStatus == .createdSuccessfully {
                    Button {
                        if let placed = session.placedURL {
                            NSWorkspace.shared.activateFileViewerSelecting([placed])
                        }
                    } label: {
                        Label("Show in Finder", systemImage: "magnifyingglass")
                    }
                    .help("Reveal the created recovery set in Finder")
                }

                Button {
                    runCreate()
                } label: {
                    Label("Create", systemImage: "shield.lefthalf.filled")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(session.isBusy || !create.canCreate)
                .help("Create the PAR2 recovery set (⇧⌘S)")
            }
        }
    }

    // MARK: - File list

    private var fileList: some View {
        Table(create.items, selection: $selection) {
            TableColumn("Name", value: \.name)
            TableColumn("Size") { item in
                Text(item.sizeBytes.formatted(.byteCount(style: .file)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: URL.self) { _ in
            Button("Remove", role: .destructive) { removeSelected() }
        }
        .onDeleteCommand { removeSelected() }
        .overlay {
            if create.items.isEmpty {
                ContentUnavailableView(
                    "No files yet",
                    systemImage: "doc.badge.plus",
                    description: Text(
                        "Add or drop the files to protect. They must all be in one folder."))
            }
        }
        .frame(minHeight: 160)
    }

    // MARK: - Options

    private var optionsForm: some View {
        @Bindable var create = create
        return Form {
            Section {
                LabeledContent("Output name") {
                    TextField("name", text: $outputName, prompt: Text(create.defaultParName))
                        .frame(maxWidth: 220)
                        .disabled(session.isBusy)
                }
                Stepper(
                    value: $create.options.redundancyPercent,
                    in: CreateOptions.redundancyRange
                ) {
                    LabeledContent("Redundancy", value: "\(create.options.redundancyPercent)%")
                }
                .disabled(session.isBusy)

                Picker("Block size", selection: blockSizeMode) {
                    Text("Automatic").tag(BlockSizeMode.automatic)
                    Text("Manual (KB)").tag(BlockSizeMode.manual)
                }
                .disabled(session.isBusy)
                if case .manual = blockSizeMode.wrappedValue {
                    TextField("KB", value: manualKilobytes, format: .number)
                        .frame(maxWidth: 120)
                        .disabled(session.isBusy)
                }

                Picker("Recovery files", selection: $create.options.fileScheme) {
                    Text("Limit to largest data file").tag(CreateOptions.FileScheme.limitToLargest)
                    Text("Uniform size").tag(CreateOptions.FileScheme.uniform)
                }
                .disabled(session.isBusy)
            }

            if !create.items.isEmpty {
                Section {
                    LabeledContent(
                        "Set",
                        value:
                            "\(create.items.count) file(s), \(create.totalBytes.formatted(.byteCount(style: .file)))"
                    )
                    LabeledContent(
                        "Blocks",
                        value:
                            "\(create.sourceBlockCount) source + \(create.recoveryBlockCount) recovery · \(create.effectiveBlockSize.formatted(.byteCount(style: .file))) block"
                    )
                }
            }

            if let rejection = create.lastRejection {
                Text(rejection).font(.callout).foregroundStyle(.orange)
            }
            ForEach(create.validationErrors, id: \.self) { error in
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Block-size binding glue

    private enum BlockSizeMode: Hashable { case automatic, manual }

    private var blockSizeMode: Binding<BlockSizeMode> {
        Binding(
            get: {
                if case .kilobytes = create.options.blockSize {
                    return .manual
                } else {
                    return .automatic
                }
            },
            set: { mode in
                switch mode {
                case .automatic: create.options.blockSize = .automatic
                case .manual: create.options.blockSize = .kilobytes(currentManualKB())
                }
            })
    }

    private var manualKilobytes: Binding<Int> {
        Binding(
            get: { currentManualKB() },
            set: { create.options.blockSize = .kilobytes(max(1, $0)) })
    }

    private func currentManualKB() -> Int {
        if case .kilobytes(let kb) = create.options.blockSize { return kb }
        // Seed the manual field from the current automatic size, ROUNDED to the nearest KB
        // (truncating would seed a smaller block than the automatic preview just showed).
        return max(1, Int((create.effectiveBlockSize + 512) / 1024))
    }

    // MARK: - Actions

    private func removeSelected() {
        create.remove(selection)
        selection.removeAll()
    }

    private func runCreate() {
        guard create.canCreate, let folder = create.folder,
            let creator = model.par2Creator
        else { return }

        // Acquire read-write access covering the source folder. A remembered grant may be the
        // folder itself OR an ancestor — pass that bookmark straight through (re-minting a
        // child bookmark would need the scope open). The OUTPUT, however, must always go in
        // the SOURCE folder, never the granted ancestor, or the recovery files separate from
        // the data they protect and record subdirectory-prefixed names. (Phase 6 review)
        let folderBookmark: Data?
        if let remembered = FolderAccessStore.bookmark(forFolder: folder) {
            folderBookmark = remembered
        } else if let chosen = FolderGrantPanel.present(suggestedFolder: folder) {
            FolderAccessStore.remember(chosen)
            folderBookmark = try? ScopedAccess.bookmark(for: chosen)
        } else {
            session.note("Create cancelled — folder access is needed to write the recovery files.")
            return
        }

        let parFile = folder.appendingPathComponent(sanitizedParName())
        session.startCreate(
            create.makeRequest(parFile: parFile, folderBookmark: folderBookmark), using: creator)
    }

    /// The output file name as a `.par2`, defaulting to the set's folder/first-file name.
    private func sanitizedParName() -> String {
        var base = outputName.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = create.defaultParName }
        // Single safe path component, always `.par2`.
        base = (base as NSString).lastPathComponent
        if base.lowercased().hasSuffix(".par2") {
            base = String(base.dropLast(5))
        }
        // Reject names that reduce to nothing meaningful (".", "..", "/", all-dots, hidden)
        // so we never produce ".par2" or "..par2" in the user's folder.
        let stripped = base.trimmingCharacters(in: CharacterSet(charactersIn: ". /"))
        if stripped.isEmpty { base = create.defaultParName }
        if base.trimmingCharacters(in: CharacterSet(charactersIn: ". /")).isEmpty {
            base = "recovery"
        }
        return base + ".par2"
    }
}

/// Open panel for adding source files to a new set. Files only; when a folder is already
/// established, it opens there so the "one folder" rule is easy to satisfy. (ROADMAP Phase 6)
@MainActor
enum AddFilesPanel {
    static func present(startingIn folder: URL?) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true  // a folder adds all its files
        panel.allowsMultipleSelection = true
        panel.message = "Choose the files to protect (they must all be in one folder)."
        panel.prompt = "Add"
        if let folder { panel.directoryURL = folder }
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
