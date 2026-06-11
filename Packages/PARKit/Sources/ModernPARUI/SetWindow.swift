import ModernPARCore
import SwiftUI
import UniformTypeIdentifiers

/// One window per `SessionRoute`; owns the window's `OperationSession` and reproduces the core
/// MacPAR loop: open → auto-verify → auto-repair, with live per-file status and cancellation.
/// (ARCHITECTURE.md §7.2; ROADMAP Phase 3)
public struct SetWindow: View {
    @Environment(AppModel.self) private var model
    @State private var session = OperationSession()
    /// The par output pane is visible by default (owner preference, 2026-06-11); the toolbar
    /// button collapses it. Becomes a persisted preference with the Phase 7 Settings work.
    @State private var showOutput = true

    let route: SessionRoute?
    public init(route: SessionRoute?) { self.route = route }

    public var body: some View {
        VStack(spacing: 0) {
            if let set = session.parSet {
                SetHeader(set: set)
                Divider()
            }
            FileTable(rows: session.rows)

            if showOutput {
                Divider()
                ParOutputPane(lines: session.log)
            }

            Divider()
            StatusBar(
                docStatus: session.docStatus,
                progress: session.progress,
                isBusy: session.isBusy,
                onCancel: { session.cancel() }
            )
        }
        .frame(minWidth: 560, minHeight: 360)
        .navigationTitle(title)
        .focusedSceneValue(\.activeSession, session)
        .dropDestination(for: URL.self) { urls, _ in
            // No silent interruption: a stray drag must not abort a running repair.
            guard !session.isBusy, let url = urls.first else { return false }
            openUserInitiated(url)
            return true
        }
        .task(id: route?.id) {
            autoRunFromRoute()
        }
        .onChange(of: session.awaitingFolderGrant) { _, awaiting in
            guard awaiting else { return }
            presentFolderGrant()
        }
        .onDisappear {
            // Closing the document cancels its operation (the original's behavior) and frees
            // the quit gate; the engine unwinds cooperatively in the background.
            session.cancel()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let url = OpenSetPanel.present() { openUserInitiated(url) }
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open a .par2 / .par file or a folder containing a set")
                .disabled(session.isBusy)

                Button {
                    showOutput.toggle()
                } label: {
                    Label("par Output", systemImage: "text.alignleft")
                }
                .help(showOutput ? "Hide par Output" : "Show par Output")

                if session.docStatus == .repairNeeded {
                    Button {
                        session.requestVerify(using: model.par2Engine, autoRepair: true)
                    } label: {
                        Label("Repair", systemImage: "bandage")
                    }
                    .disabled(session.isBusy)
                    .help("Repair the damaged files using the available recovery data")
                } else {
                    Button {
                        session.requestVerify(
                            using: model.par2Engine, autoRepair: model.settings.autoRepair)
                    } label: {
                        Label("Verify", systemImage: "checkmark.shield")
                    }
                    .disabled(session.isBusy || session.anchorURL == nil)
                    .help(
                        model.settings.autoRepair
                            ? "Verify the open set (repairs automatically if damage is found)"
                            : "Verify the open set")
                }
            }
        }
        .background(OpenFilesClaimant(model: model, session: session, route: route))
    }

    /// A user-initiated open (drop, Open button, Cmd-O window): parse, then auto-verify —
    /// the MacPAR open → verify → repair loop.
    private func openUserInitiated(_ url: URL) {
        session.open(
            url, thenVerifyUsing: model.par2Engine, autoRepair: model.settings.autoRepair)
    }

    /// Windows arriving with a route (Cmd-O, Finder open, dock drop — or system restoration).
    /// Only routes minted THIS launch auto-run; a restored window re-opens its set read-only
    /// and waits for consent. (ROADMAP Phase 3 exit criterion)
    private func autoRunFromRoute() {
        guard let route, route.mode == .verifyRepair, session.parSet == nil, !session.isBusy
        else { return }
        guard let bookmark = route.anchorBookmark ?? route.folderBookmark else { return }
        guard let resolved = try? ScopedAccess.resolve(bookmark) else {
            if route.anchorBookmark != nil || route.folderBookmark != nil {
                session.reportOpenFailure(
                    "The set this window was showing can no longer be found (moved or deleted)."
                )
            }
            return
        }
        // The resolved grant stays active for the window's lifetime; the session re-bookmarks
        // for its own engine runs.
        if model.consumeFreshness(of: route.id) {
            session.open(
                resolved.url, thenVerifyUsing: model.par2Engine, autoRepair: route.autoRepair)
        } else {
            session.open(resolved.url)  // restored window: parse only, never auto-repair
        }
    }

    /// The one-time powerbox grant. Re-checks first (another window may have granted the same
    /// folder while this prompt was queued) and verifies the chosen folder actually covers the
    /// set — persisting a wrong grant would re-prompt forever while verifies run doomed.
    private func presentFolderGrant() {
        guard let anchor = session.anchorURL else {
            session.folderGrantDeclined()
            return
        }
        guard session.needsFolderGrant else {
            session.folderGrantResolved(using: model.par2Engine)
            return
        }
        let setFolder = anchor.deletingLastPathComponent().standardizedFileURL
        if let granted = FolderGrantPanel.present(suggestedFolder: setFolder) {
            let grantedPath = granted.standardizedFileURL.path
            let coversSet =
                setFolder.path == grantedPath
                || setFolder.path.hasPrefix(
                    grantedPath.hasSuffix("/") ? grantedPath : grantedPath + "/")
            guard coversSet else {
                session.folderGrantDeclined()
                session.reportOpenFailure(
                    "The granted folder does not contain this set — choose \(setFolder.lastPathComponent) (or a parent folder) and try again."
                )
                return
            }
            FolderAccessStore.remember(granted)
            session.folderGrantResolved(using: model.par2Engine)
        } else {
            session.folderGrantDeclined()
        }
    }

    private var title: String {
        switch route?.mode {
        case .createSet: return "New PAR Set"
        case .extractArchive: return "Extract Archive"
        case .verifyRepair, .none: return "ModernPAR"
        }
    }
}

/// Installs the Finder open-with / dock-drop handler. The most recently appeared window owns
/// it; a pristine window (nothing open, no route payload) claims the first URL itself so a
/// cold launch via double-click doesn't leave an extra empty window behind.
struct OpenFilesClaimant: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel
    let session: OperationSession
    let route: SessionRoute?

    var body: some View {
        Color.clear
            .onAppear {
                let isPristine =
                    route?.anchorBookmark == nil && route?.folderBookmark == nil
                OpenFilesBroker.installHandler { urls in
                    var remaining = urls[...]
                    if isPristine, session.parSet == nil, !session.isBusy,
                        let first = remaining.popFirst()
                    {
                        session.open(
                            first, thenVerifyUsing: model.par2Engine,
                            autoRepair: model.settings.autoRepair)
                    }
                    for url in remaining {
                        openWindow(value: model.makeRoute(opening: url))
                    }
                }
            }
    }
}
