import ModernPARCore
import SwiftUI
import UniformTypeIdentifiers

/// One window per `SessionRoute`; owns the window's `OperationSession` and reproduces the core
/// MacPAR loop: open → auto-verify → auto-repair, with live per-file status and cancellation.
/// (ARCHITECTURE.md §7.2; ROADMAP Phase 3)
public struct SetWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var session = OperationSession()
    /// The par output pane visibility follows the last toolbar choice (persisted; visible by
    /// default — owner preference, 2026-06-11). Read once per window at creation.
    @State private var showOutput: Bool?
    /// Armed when the automatic post-process chain starts and `AutoCloseDocument` is on —
    /// the window closes once that extraction ends green. (doc-01 §5.1)
    @State private var closeWhenExtracted = false
    /// This window's place in the one-by-one multi-open queue (nil when processing
    /// simultaneously or the window wasn't a fresh auto-run). (doc-01 §5.6)
    @State private var queueTicket: MultiOpenQueue.Ticket?
    /// Table selection — powers Edit ▸ Copy (file names) and Select All Non-OK.
    @State private var selection: Set<UUID> = []

    let route: SessionRoute?
    public init(route: SessionRoute?) { self.route = route }

    public var body: some View {
        if route?.mode == .createSet {
            // A create window can be the app's ONLY window (DefaultPar = create), so it must
            // host the Finder open-with handler too — claimed documents open proper
            // verify/extract windows; a create window never ingests a .par2 itself.
            // (Phase 7 review)
            CreateSetView(session: session)
                .environment(model)
                .background(
                    OpenFilesClaimant(
                        model: model, session: session, route: route,
                        openFirst: { openWindow(value: model.makeRoute(opening: $0)) }))
        } else {
            verifyExtractBody
        }
    }

    private var verifyExtractBody: some View {
        VStack(spacing: 0) {
            if let set = session.parSet {
                SetHeader(set: set)
                Divider()
            }
            FileTable(rows: session.rows, selection: $selection)

            if isOutputShown {
                Divider()
                ParOutputPane(lines: session.log)
            }

            Divider()
            StatusBar(
                docStatus: session.docStatus,
                progress: session.progress,
                isBusy: session.isBusy,
                onCancel: {
                    // Cancelling a chained extraction means "keep this window" — a stale
                    // armed flag would close it after a LATER successful extraction.
                    closeWhenExtracted = false
                    session.cancel()
                }
            )
        }
        .frame(minWidth: 560, minHeight: 360)
        .onAppear {
            // Read the persisted pane preference ONCE per window — toggling it in another
            // window must not collapse this one's pane mid-use.
            if showOutput == nil { showOutput = model.settings.showParOutput }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            // New windows open at the last-used size (the system restores the frames of
            // RESTORED windows itself). (ROADMAP Phase 7 "window size persistence")
            model.settings.lastWindowWidth = size.width
            model.settings.lastWindowHeight = size.height
        }
        .navigationTitle(title)
        .focusedSceneValue(\.activeSession, session)
        .focusedSceneValue(
            \.fileTableActions,
            FileTableActions(selectAllNonOK: {
                selection = Set(session.rows.filter(\.status.isNonOK).map(\.id))
            })
        )
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
        .onChange(of: session.docStatus) { _, status in
            // Unattended operation reports terminal failures as notifications — the run
            // already avoided dialogs (declined passwords, keep-both conflicts). (doc-01 §5.1)
            if model.settings.unattendedOperation, status.isFailureEndState {
                ExtractionNotifier.shared.notifyFailure(
                    documentName: session.openedURL?.lastPathComponent ?? "this set",
                    status: status.label)
            }
            if status == .extractionFailed {
                closeWhenExtracted = false
            }
            // Notify only on the green end state — a partial/failed extraction may still
            // place output, and a success notification for it would be a lie.
            guard status == .extractedSuccessfully, let placed = session.placedURL else {
                return
            }
            ExtractionNotifier.shared.notifyExtractionFinished(of: placed)
            // AutoCloseDocument: the automatic post-process chain just finished green —
            // the document's work is done. (doc-01 §5.1)
            if closeWhenExtracted {
                closeWhenExtracted = false
                dismiss()
            }
        }
        .onChange(of: session.lastError) { _, error in
            // An engine-reported cancel (destination-conflict Cancel, declined prompts)
            // disarms auto-close like the status-bar Cancel does. NOT keyed on docStatus ==
            // .waitingToStart — the chained run itself passes through that state right after
            // the flag is armed. (Phase 7 review)
            if error == .cancelled { closeWhenExtracted = false }
            // Wrong password → re-prompt and re-run (the prompt-once cache lives per run).
            // A declined prompt (.passwordNeeded) deliberately does NOT loop.
            guard error == .badPassword, !session.isBusy else { return }
            startExtraction(retryAfterFailure: true)
        }
        .onChange(of: session.postProcessReady) { _, generation in
            // A verify/repair just ended green. AutoDeletePnn first (the pars are no longer
            // needed), then chain into the first matching rule — the hands-off MacPAR/
            // SABnzbd pipeline. (ROADMAP Phase 5; Phase 7 prefs)
            guard generation > 0 else { return }
            if model.settings.autoDeleteParFiles {
                // Only after an actual RESTORE — a plain all-OK verify of a set the user
                // means to keep must not sweep its pars. (doc-01 §5.1; Phase 7 review)
                session.trashParFilesAfterSuccessfulRestore()
            }
            guard model.settings.autoPostProcess else { return }
            let outcome = PostProcessor.apply(session: session, model: model, manual: false)
            if model.settings.autoCloseAfterPostProcess {
                switch outcome {
                case .opened: dismiss()
                case .chained: closeWhenExtracted = true
                case .none: break
                }
            }
        }
        .onChange(of: session.runEnded) { _, _ in
            // Settle the multi-open ticket one runloop tick later: a post-process chain or a
            // wrong-password retry fired by this same event has set the session busy again by
            // then, and the queue keeps waiting. Settling twice is harmless (no-op).
            guard let ticket = queueTicket else { return }
            Task { @MainActor in
                if !session.isBusy, !session.awaitingFolderGrant {
                    model.openQueue.settle(ticket)
                }
            }
        }
        .onDisappear {
            // Closing the document cancels its operation (the original's behavior) and frees
            // the quit gate; the engine unwinds cooperatively in the background. A queued or
            // active ticket is released so the next window can proceed.
            session.cancel()
            if let ticket = queueTicket {
                model.openQueue.settle(ticket)
                queueTicket = nil
            }
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
                    let next = !isOutputShown
                    showOutput = next
                    model.settings.showParOutput = next
                } label: {
                    Label("par Output", systemImage: "text.alignleft")
                }
                .help(isOutputShown ? "Hide par Output" : "Show par Output")

                if isArchiveSession {
                    Button {
                        startExtraction()
                    } label: {
                        Label("Extract", systemImage: "archivebox")
                    }
                    .disabled(session.isBusy || session.anchorURL == nil)
                    .help("Extract the open archive")
                } else if session.docStatus == .repairNeeded {
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
        .background(
            OpenFilesClaimant(
                model: model, session: session, route: route,
                openFirst: { claimFirstOpen($0) }))
    }

    /// A pristine window claiming the first Finder-opened URL takes a queue ticket like any
    /// other fresh auto-run — otherwise file 1 (claimed) and file 2 (fresh window) of a
    /// multi-open would run their pipelines concurrently under one-by-one mode.
    /// (doc-01 §5.6; Phase 7 review)
    private func claimFirstOpen(_ url: URL) {
        if model.settings.simultaneousProcessing {
            openUserInitiated(url)
        } else {
            _ = model.openQueue.enqueue { ticket in
                queueTicket = ticket
                // The window may have been taken over while the claim waited its turn.
                guard session.parSet == nil, session.anchorURL == nil, !session.isBusy else {
                    releaseQueueTicket()
                    return
                }
                performOpen(url)
            }
        }
    }

    /// Settles and forgets this window's queue ticket (no-op without one). Settling an
    /// already-settled ticket is harmless by contract.
    private func releaseQueueTicket() {
        if let ticket = queueTicket {
            model.openQueue.settle(ticket)
            queueTicket = nil
        }
    }

    /// The window's pane state overrides the persisted default once the user toggles it.
    private var isOutputShown: Bool { showOutput ?? model.settings.showParOutput }

    /// Whether this window is currently showing an archive extraction. The session's anchor
    /// wins over the route mode: window content can change after creation (a PAR set opened
    /// into a Cmd-U window must get Verify/Repair back, and vice versa).
    private var isArchiveSession: Bool {
        if let anchor = session.anchorURL { return ArchiveFileTypes.isArchive(anchor) }
        return route?.mode == .extractArchive
    }

    /// A user-initiated open (drop, Open button, Cmd-O window): archives (.rar/.zip) go to
    /// the extraction flow; PAR files parse, then auto-verify — the MacPAR open → verify →
    /// repair loop.
    private func openUserInitiated(_ url: URL) {
        // The user took this window over — withdraw any queued auto-run so it can never
        // fire later and cancel this run, and drop a stale auto-close from prior content.
        // (Phase 7 review)
        releaseQueueTicket()
        closeWhenExtracted = false
        performOpen(url)
    }

    /// The open body shared by user opens and the queued claimant path (which must keep its
    /// ticket, settling it only on a failure exit).
    private func performOpen(_ url: URL) {
        let isDirectory =
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if !isDirectory, let extractor = model.extractor(forArchiveAt: url) {
            guard let run = ExtractionRunSupport.makeRun(model: model) else {
                // Cancelled destination panel: nothing will run — release the queue.
                releaseQueueTicket()
                return
            }
            session.openArchive(
                url, using: extractor, options: run.options,
                password: run.password, conflicts: run.conflicts)
        } else {
            session.open(
                url, thenVerifyUsing: model.par2Engine, autoRepair: model.settings.autoRepair)
        }
    }

    /// Starts (or restarts) extraction of the opened archive. (ROADMAP Phase 4)
    private func startExtraction(retryAfterFailure: Bool = false) {
        guard let anchor = session.anchorURL,
            let extractor = model.extractor(forArchiveAt: anchor),
            let run = ExtractionRunSupport.makeRun(
                model: model, retryAfterFailure: retryAfterFailure)
        else { return }
        session.requestExtract(
            using: extractor, options: run.options,
            password: run.password,
            conflicts: run.conflicts,
            // A wrong-password retry is a continuation of the same operation — keep the log
            // (including a chained post-process's verify history). (Phase 5 review)
            preservingHistory: retryAfterFailure)
    }

    /// Windows arriving with a route (Cmd-O, Cmd-U, Finder open, dock drop — or system
    /// restoration). Only routes minted THIS launch auto-run; a restored window re-opens its
    /// content read-only and waits for consent. (ROADMAP Phase 3 exit criterion)
    private func autoRunFromRoute() {
        guard let route, session.parSet == nil, session.anchorURL == nil, !session.isBusy
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
        let isFresh = model.consumeFreshness(of: route.id)
        guard route.mode == .extractArchive || route.mode == .verifyRepair else { return }
        if isFresh {
            // One-by-one multi-open (doc-01 §5.6): a fresh auto-run waits its turn unless
            // SimultaneousProcessing is on. Restored windows parse read-only and never queue.
            let url = resolved.url
            let mode = route.mode
            let autoRepair = route.autoRepair
            if model.settings.simultaneousProcessing {
                startFreshRun(url, mode: mode, autoRepair: autoRepair)
            } else {
                _ = model.openQueue.enqueue { ticket in
                    queueTicket = ticket
                    // Re-check at FIRE time: the window sat idle while queued, and the user
                    // may have dropped/opened something into it — the delayed auto-run must
                    // not cancel that work. (Phase 7 review)
                    guard session.parSet == nil, session.anchorURL == nil, !session.isBusy
                    else {
                        releaseQueueTicket()
                        return
                    }
                    startFreshRun(url, mode: mode, autoRepair: autoRepair)
                }
            }
            return
        }
        if route.mode == .extractArchive {
            // Restored extraction window: never re-extract without consent (the Extract
            // button re-runs it). Surface what the window was showing.
            if model.extractor(forArchiveAt: resolved.url) != nil {
                session.noteRestoredArchive(resolved.url)
            }
        } else {
            // The resolved grant stays active for the window's lifetime; the session
            // re-bookmarks for its own engine runs.
            session.open(resolved.url)  // restored window: parse only, never auto-repair
        }
    }

    /// The fresh-route auto-run body — called directly (simultaneous) or when the multi-open
    /// queue reaches this window's ticket.
    private func startFreshRun(_ url: URL, mode: SessionRoute.Mode, autoRepair: Bool) {
        if mode == .extractArchive {
            guard let extractor = model.extractor(forArchiveAt: url) else {
                releaseQueueTicket()
                return
            }
            guard let run = ExtractionRunSupport.makeRun(model: model) else {
                // Cancelled destination panel: no run starts and no runEnded will ever
                // arrive — the queue must be released here or every window behind this
                // one waits forever. (Phase 7 review)
                session.noteRestoredArchive(url)
                releaseQueueTicket()
                return
            }
            session.openArchive(
                url, using: extractor, options: run.options,
                password: run.password, conflicts: run.conflicts)
        } else {
            session.open(url, thenVerifyUsing: model.par2Engine, autoRepair: autoRepair)
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
        // Unattended operation never shows dialogs (doc-01 §5.1): decline the grant and
        // notify, like every other prompt. The guard sits AFTER the re-check so a grant
        // remembered by another window still resolves silently. A declined grant leaves
        // docStatus untouched, so the failure-notification path would not fire on its own.
        if model.settings.unattendedOperation {
            session.folderGrantDeclined()
            ExtractionNotifier.shared.notifyFailure(
                documentName: session.openedURL?.lastPathComponent ?? "this set",
                status: "Folder access not granted — grant it once while attended.")
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
    /// Routes a claimed URL the same way the window's own opens do (PAR vs archive).
    let openFirst: (URL) -> Void

    var body: some View {
        Color.clear
            .onAppear {
                let isPristine =
                    route?.anchorBookmark == nil && route?.folderBookmark == nil
                OpenFilesBroker.installHandler { urls in
                    var remaining = urls[...]
                    if isPristine, session.parSet == nil, session.anchorURL == nil,
                        !session.isBusy, let first = remaining.popFirst()
                    {
                        openFirst(first)
                    }
                    for url in remaining {
                        openWindow(value: model.makeRoute(opening: url))
                    }
                }
            }
    }
}
