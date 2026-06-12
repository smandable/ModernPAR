import Foundation
import Observation

/// Per-window, observable session driving one verify/repair/create/extract operation.
///
/// It consumes the engine's `AsyncStream<EngineEvent>` and folds events into the model
/// (@Observable coalesces SwiftUI invalidation per runloop turn). Cancellation cancels the
/// consuming `Task`, whose termination stops the engine cooperatively (reproduces Cmd-.).
/// (ARCHITECTURE.md §4.2)
@MainActor
@Observable
public final class OperationSession {
    public private(set) var rows: [FileEntry] = []
    public private(set) var docStatus: DocStatus = .waitingToStart
    public private(set) var progress: Double = 0
    public private(set) var log: [String] = []
    public private(set) var isBusy = false
    /// The parsed set powering the header line — produced by the native read-only parser the
    /// moment a set is opened, before any engine runs. (ARCHITECTURE.md §1.3)
    public private(set) var parSet: ParSet?
    /// Set when an auto-verify wants to run but engine I/O needs a folder grant the session
    /// doesn't have — the UI presents the one-time powerbox panel and calls
    /// `folderGrantResolved`/`folderGrantDeclined`. (ROADMAP Phase 3)
    public private(set) var awaitingFolderGrant = false
    /// What to run once the folder grant resolves — verify (the Phase 3 flow) or extract
    /// (Phase 4; extraction writes its output into the granted folder).
    private enum PendingGrantAction {
        case verify(autoRepair: Bool)
        case extract(
            extractor: any ArchiveExtractor,
            options: ExtractOptions,
            password: any PasswordProvider,
            conflicts: any ConflictResolver,
            preservingHistory: Bool)
    }
    private var pendingGrantAction: PendingGrantAction?
    /// What the user opened (file or folder) and the `.par2`/`.par` it anchored to — kept so
    /// Verify can hand the engine a route with fresh security-scoped bookmarks.
    public private(set) var openedURL: URL?
    public private(set) var anchorURL: URL?
    /// Where extraction placed its output (ROADMAP Phase 4) — powers "Show in Finder".
    public private(set) var placedURL: URL?
    /// The terminal error of the last run, if it failed — the UI reacts to extraction's
    /// `.badPassword` / `.passwordNeeded` by re-prompting and re-running.
    public private(set) var lastError: EngineError?
    /// Bumped each time a VERIFY/REPAIR run ends in a green state — the post-processing
    /// trigger (ROADMAP Phase 5). Extraction runs never bump it, so a chained extraction's
    /// own green end state cannot re-fire the chain.
    public private(set) var postProcessReady = 0
    /// Bumped whenever the session reaches a point where no further work will START ITSELF:
    /// a run finished, an open parsed without chaining a verify, a folder grant was declined,
    /// or a busy run was cancelled. The one-by-one multi-open queue settles on this — after a
    /// runloop tick, so a chain/retry fired by the same event has already re-marked the
    /// session busy. (doc-01 §5.6 `SimultaneousProcessing`; ROADMAP Phase 7)
    public private(set) var runEnded = 0

    /// Which kind of operation the current/last run was — post-processing only chains off
    /// verify/repair, and the UI's archive affordances key off extraction.
    private enum RunKind { case verifyRepair, extract, create }
    private var runKind: RunKind = .verifyRepair

    /// Fast id → index map kept in sync with `rows` so batch application stays O(events), not O(n²).
    private var indexByID: [UUID: Int] = [:]
    private var task: Task<Void, Never>?

    public init() {}

    public func start(_ route: SessionRoute, engine: any PAR2Engine) {
        cancel()
        reset(keepingDocument: true)
        // Only a verify/repair run may arm the post-process chain — a future create run
        // (Phase 6) ending green over a roster that names the source archive must NOT
        // auto-extract the set the user just protected.
        runKind = route.mode == .verifyRepair ? .verifyRepair : .extract
        setBusy(true)
        let stream = engine.run(route)
        task = Task { [weak self] in
            await self?.consume(stream)
            // A superseded run must not clobber the replacing run's state.
            guard !Task.isCancelled else { return }
            self?.setBusy(false)
        }
    }

    /// Runs the engine against whatever `open(_:)` loaded, minting fresh security-scoped
    /// bookmarks for the route. `autoRepair: false` is the awaiting-consent path (restored
    /// windows; explicit "Verify" runs) — the engine then stops at the verdict.
    public func startVerify(using engine: any PAR2Engine, autoRepair: Bool = true) {
        guard let anchorURL else { return }
        var route = SessionRoute(mode: .verifyRepair, autoRepair: autoRepair)
        mintBookmarks(into: &route, anchor: anchorURL)
        start(route, engine: engine)
    }

    /// Mints the route's folder + anchor bookmarks. CRITICAL: the anchor bookmark is created
    /// WHILE the folder grant's security scope is active. When folder access comes from a
    /// FolderAccessStore bookmark remembered in a PREVIOUS launch (the second-launch flow:
    /// double-click data.par2 after the folder was granted once), the anchor file is reachable
    /// only inside that scope — minting its bookmark outside the scope returns nil and the run
    /// dies with "session has no anchor bookmark". (Phase 5 review)
    private func mintBookmarks(into route: inout SessionRoute, anchor: URL) {
        let folderBookmark = folderGrantBookmark()
        route.folderBookmark = folderBookmark
        if let folderBookmark, let scope = try? ScopedAccess.resolve(folderBookmark) {
            defer { if scope.didStart { scope.url.stopAccessingSecurityScopedResource() } }
            route.anchorBookmark = try? ScopedAccess.bookmark(for: anchor)
        } else {
            route.anchorBookmark = try? ScopedAccess.bookmark(for: anchor)
        }
    }

    /// The best available folder grant for engine I/O: the opened folder itself, or a
    /// previously remembered powerbox grant covering the anchor's folder. (ROADMAP Phase 3)
    private func folderGrantBookmark() -> Data? {
        if let openedURL,
            (try? openedURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        {
            return try? ScopedAccess.bookmark(for: openedURL)
        }
        guard let anchorURL else { return nil }
        return FolderAccessStore.bookmark(forFolder: anchorURL.deletingLastPathComponent())
    }

    /// Whether engine I/O would need a folder grant the session does not have — the trigger
    /// for the one-time "grant this folder" powerbox flow in the UI.
    public var needsFolderGrant: Bool {
        guard let anchorURL else { return false }
        if let openedURL,
            (try? openedURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        {
            return false
        }
        let folder = anchorURL.deletingLastPathComponent()
        if FolderAccessStore.bookmark(forFolder: folder) != nil { return false }
        return !FileManager.default.isReadableFile(atPath: folder.path)
    }

    public func cancel() {
        task?.cancel()
        task = nil
        // The cancelled task's completion is discarded (`!Task.isCancelled` guard), so terminal
        // state must be restored here — otherwise the spinner sticks at busy/checking forever.
        if isBusy {
            setBusy(false)
            if docStatus == .checking || docStatus == .repairing || docStatus == .extracting
                || docStatus == .creating
            {
                docStatus = .waitingToStart
            }
            // A cancelled run ends the pipeline; the multi-open queue must not wait forever.
            runEnded += 1
        }
    }

    /// Starts an archive extraction (ROADMAP Phase 4). The roster, progress, statuses, and the
    /// placed-output URL all arrive through the same `EngineEvent` stream verify/repair uses,
    /// so the window renders extraction with the identical machinery.
    public func startExtract(
        _ route: SessionRoute,
        using extractor: any ArchiveExtractor,
        options: ExtractOptions = ExtractOptions(),
        password: any PasswordProvider,
        conflicts: any ConflictResolver,
        preservingHistory: Bool = false
    ) {
        cancel()
        reset(keepingDocument: true, keepingLog: preservingHistory)
        runKind = .extract
        if let data = route.anchorBookmark, let resolved = try? ScopedAccess.resolve(data) {
            // Record what we're extracting for the title bar / re-runs; the extractor manages
            // its own scoped access, so balance the resolve immediately.
            openedURL = resolved.url
            anchorURL = resolved.url
            if resolved.didStart { resolved.url.stopAccessingSecurityScopedResource() }
        }
        setBusy(true)
        // docStatus stays .waitingToStart until the engine's own .docStatusChanged(.extracting)
        // arrives — RAR runs serialize process-wide, so this run may be QUEUED behind another
        // window's extraction and must not claim to be extracting while it waits.
        let stream = extractor.extract(
            route, options: options, password: password, conflicts: conflicts)
        task = Task { [weak self] in
            await self?.consume(stream)
            guard !Task.isCancelled else { return }
            self?.setBusy(false)
        }
    }

    /// Starts a PAR2 create operation (ROADMAP Phase 6). Streams the same `EngineEvent`s as
    /// verify/repair, so the window renders progress with identical machinery; on success the
    /// created `.par2` becomes `placedURL` (powering "Show in Finder").
    public func startCreate(_ request: CreateRequest, using creator: any Par2Creator) {
        cancel()
        reset(keepingDocument: true)
        runKind = .create
        openedURL = request.parFile
        anchorURL = request.parFile
        setBusy(true)
        // The engine emits .extractionPlaced(parFile) on success, which sets placedURL for
        // "Show in Finder" — the same machinery extraction uses.
        let stream = creator.create(request)
        task = Task { [weak self] in
            await self?.consume(stream)
            guard !Task.isCancelled else { return }
            self?.setBusy(false)
        }
    }

    /// The grant-aware verify entry point — menus, toolbar, and the open-chain all route
    /// through here so the one-time folder-grant flow can never be bypassed. (ROADMAP Phase 3)
    public func requestVerify(using engine: any PAR2Engine, autoRepair: Bool) {
        guard anchorURL != nil, !isBusy else { return }
        if needsFolderGrant {
            pendingGrantAction = .verify(autoRepair: autoRepair)
            awaitingFolderGrant = true
        } else {
            startVerify(using: engine, autoRepair: autoRepair)
        }
    }

    /// Opens a RAR archive and chains into extraction through the same one-time folder-grant
    /// flow verify uses — extraction reads sibling volumes and writes output into the
    /// archive's folder, so a single-file grant is not enough. (ROADMAP Phase 4)
    public func openArchive(
        _ url: URL,
        using extractor: any ArchiveExtractor,
        options: ExtractOptions = ExtractOptions(),
        password: any PasswordProvider,
        conflicts: any ConflictResolver
    ) {
        cancel()
        reset()
        openedURL = url
        anchorURL = url
        log.append("Opened archive \(url.lastPathComponent).")
        requestExtract(using: extractor, options: options, password: password, conflicts: conflicts)
    }

    /// The grant-aware extraction entry point (mirror of `requestVerify`).
    public func requestExtract(
        using extractor: any ArchiveExtractor,
        options: ExtractOptions = ExtractOptions(),
        password: any PasswordProvider,
        conflicts: any ConflictResolver,
        preservingHistory: Bool = false
    ) {
        guard anchorURL != nil, !isBusy else { return }
        if needsFolderGrant {
            pendingGrantAction = .extract(
                extractor: extractor, options: options, password: password, conflicts: conflicts,
                preservingHistory: preservingHistory)
            awaitingFolderGrant = true
        } else {
            startExtractFromAnchor(
                using: extractor, options: options, password: password, conflicts: conflicts,
                preservingHistory: preservingHistory)
        }
    }

    /// Post-processing: chains the just-verified set into extracting its archive payload
    /// WITHIN this session — the anchor moves to the archive, the log carries over, and the
    /// extraction streams through the same event machinery. (ROADMAP Phase 5)
    public func chainIntoArchive(
        _ archiveURL: URL,
        ruleName: String,
        using extractor: any ArchiveExtractor,
        options: ExtractOptions = ExtractOptions(),
        password: any PasswordProvider,
        conflicts: any ConflictResolver
    ) {
        guard !isBusy else { return }
        anchorURL = archiveURL
        log.append("Post-processing (\(ruleName)): extracting \(archiveURL.lastPathComponent).")
        requestExtract(
            using: extractor, options: options, password: password, conflicts: conflicts,
            preservingHistory: true)
    }

    /// Runs the extractor against the opened archive, minting fresh security-scoped bookmarks.
    private func startExtractFromAnchor(
        using extractor: any ArchiveExtractor,
        options: ExtractOptions = ExtractOptions(),
        password: any PasswordProvider,
        conflicts: any ConflictResolver,
        preservingHistory: Bool = false
    ) {
        guard let anchorURL else { return }
        var route = SessionRoute(mode: .extractArchive)
        mintBookmarks(into: &route, anchor: anchorURL)
        startExtract(
            route, using: extractor, options: options, password: password, conflicts: conflicts,
            preservingHistory: preservingHistory)
    }

    /// Surface an open/restore failure that happens before any parse can run (e.g. a restored
    /// window whose bookmark no longer resolves).
    public func reportOpenFailure(_ message: String) {
        docStatus = .notValid
        log.append(message)
    }

    /// Appends an informational line to the output pane (post-process decisions, etc.).
    public func note(_ line: String) {
        log.append(line)
    }

    /// The `AutoDeletePnn` trigger: par files are swept only after an actual RESTORE — a
    /// plain all-OK verify of a set the user means to keep must leave them alone (the
    /// preference's own label: "after a successful restore"). (doc-01 §5.1; Phase 7 review)
    public func trashParFilesAfterSuccessfulRestore() {
        guard docStatus == .restoredSuccessfully || docStatus == .restoredWithRenames else {
            return
        }
        trashParFiles()
    }

    /// `AutoDeletePnn` (doc-01 §5.1): moves the set's contributing par files to the Trash
    /// after a successful restore. Trash-only by design — when the Trash is unavailable
    /// (some network volumes), files are LEFT IN PLACE and logged, never permanently deleted.
    /// The UI calls this on the green verify/repair end when the preference is on.
    public func trashParFiles() {
        guard let parFiles = parSet?.parFiles, !parFiles.isEmpty else { return }
        // The par files live beside the data files — bracket in the same folder grant the
        // engine runs use (the open scope may have lapsed by the time the verify ends).
        var scopeURL: URL?
        if let bookmark = folderGrantBookmark(), let scope = try? ScopedAccess.resolve(bookmark),
            scope.didStart
        {
            scopeURL = scope.url
        }
        defer { scopeURL?.stopAccessingSecurityScopedResource() }

        var trashed = 0
        var failed = 0
        for url in parFiles {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashed += 1
            } catch {
                failed += 1
            }
        }
        if trashed > 0 {
            log.append("Moved \(trashed) par file\(trashed == 1 ? "" : "s") to the Trash.")
        }
        if failed > 0 {
            log.append(
                "\(failed) par file\(failed == 1 ? "" : "s") could not be moved to the Trash and were left in place."
            )
        }
    }

    /// A restored extraction window: surface what it was showing, but never re-extract
    /// without consent (the same principle as restored verify windows; ROADMAP Phase 3).
    public func noteRestoredArchive(_ url: URL) {
        openedURL = url
        anchorURL = url
        log.append(
            "Archive \(url.lastPathComponent) — use the Extract button to extract it again.")
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        OperationRegistry.shared.setBusy(busy, session: self)
    }

    // MARK: - Opening a set (native parse, then optional auto-verify)

    /// Opens a `.par2` / `.par` / `.pNN` file — or a folder containing one — and populates the
    /// file table and header from the native read-only parser. When `thenVerifyUsing` is given
    /// (fresh user-initiated opens), a verify chains automatically after a successful parse —
    /// the MacPAR open → verify → repair loop. Restored windows pass nil: they must never
    /// auto-fire a destructive repair without consent. (ROADMAP Phase 3)
    public func open(
        _ url: URL,
        thenVerifyUsing engine: (any PAR2Engine)? = nil,
        autoRepair: Bool = true
    ) {
        cancel()
        reset()
        setBusy(true)
        docStatus = .checking
        task = Task { [weak self] in
            let outcome = await Self.parse(url: url)
            guard let self, !Task.isCancelled else { return }
            self.parSet = outcome.parSet
            self.openedURL = url
            self.anchorURL = outcome.anchorURL
            self.rows = outcome.rows
            // first-wins, never trap: row ids are unique by construction, but they derive from
            // untrusted input — Dictionary(uniqueKeysWithValues:) would crash on a duplicate.
            self.indexByID = Dictionary(
                outcome.rows.enumerated().map { ($1.id, $0) },
                uniquingKeysWith: { first, _ in first })
            self.log.append(contentsOf: outcome.logLines)
            self.docStatus = outcome.docStatus
            self.setBusy(false)
            if let engine, outcome.parSet != nil, self.parSet?.kind == .par2 {
                if self.needsFolderGrant {
                    // The UI presents the one-time "grant this folder" powerbox panel.
                    self.pendingGrantAction = .verify(autoRepair: autoRepair)
                    self.awaitingFolderGrant = true
                } else {
                    self.startVerify(using: engine, autoRepair: autoRepair)
                }
            } else {
                // Parse-only end (no engine, parse failure, or PAR1): nothing else will
                // start itself — the multi-open queue may move on.
                self.runEnded += 1
            }
        }
    }

    /// The folder grant was given (and persisted by the caller); run the deferred action.
    public func folderGrantResolved(using engine: any PAR2Engine) {
        awaitingFolderGrant = false
        let action = pendingGrantAction
        pendingGrantAction = nil
        switch action {
        case .extract(let extractor, let options, let password, let conflicts, let history):
            startExtractFromAnchor(
                using: extractor, options: options, password: password, conflicts: conflicts,
                preservingHistory: history)
        case .verify(let autoRepair):
            startVerify(using: engine, autoRepair: autoRepair)
        case nil:
            startVerify(using: engine, autoRepair: true)
        }
    }

    /// The user declined the folder grant; stay open in parse-only mode.
    public func folderGrantDeclined() {
        awaitingFolderGrant = false
        let wasExtract =
            if case .extract = pendingGrantAction { true } else { false }
        pendingGrantAction = nil
        log.append(
            wasExtract
                ? "Folder access not granted — extraction needs access to the archive's folder to read all volumes and write the output."
                : "Folder access not granted — verify would report every data file as missing. Use the Verify button after granting access, or open the enclosing folder."
        )
        // The declined grant ends this window's pipeline.
        runEnded += 1
    }

    private struct ParseOutcome: Sendable {
        var parSet: ParSet?
        var anchorURL: URL?
        var rows: [FileEntry] = []
        var docStatus: DocStatus = .waitingToStart
        var logLines: [String] = []
    }

    /// Runs off the main actor. Brackets the work in a security-scoped grant (drag-drop and
    /// dock-open URLs are not auto-scoped — ARCHITECTURE.md §5.2), then dispatches on file type.
    private nonisolated static func parse(url: URL) async -> ParseOutcome {
        let scope = beginScopedAccess(url)
        defer { scope.end() }

        var outcome = ParseOutcome()
        do {
            guard let anchor = anchorFile(for: scope.url) else {
                outcome.docStatus = .notValid
                outcome.logLines = ["No PAR file found at \(scope.url.lastPathComponent)."]
                return outcome
            }
            outcome.anchorURL = anchor
            if anchor.pathExtension.lowercased() == "par2" {
                let set = try Par2Parser.loadSet(anchor: anchor)
                let parSet = ParSet(par2: set)
                outcome.parSet = parSet
                outcome.rows = parSet.files
                outcome.logLines.append(
                    "Loaded PAR2 set \(set.setID) from \(set.sourceFiles.count) file(s).")
                if let creator = set.creator { outcome.logLines.append("Creator: \(creator)") }
                if set.corruptPacketCount > 0 {
                    outcome.logLines.append(
                        "Skipped \(set.corruptPacketCount) corrupt packet candidate(s) in the folder's .par2 files."
                    )
                }
                let missing = set.missingDescriptionIDs.count
                if missing > 0 {
                    outcome.logLines.append(
                        "\(missing) file(s) in the recovery set have no surviving description — totals are a lower bound."
                    )
                }
            } else {
                let archive = try Par1Parser.parse(fileURL: anchor)
                let parSet = ParSet(par1: archive)
                outcome.parSet = parSet
                outcome.rows = parSet.files
                outcome.logLines.append(
                    "Loaded PAR1 archive (\(archive.files.count) file(s), volume \(archive.volumeNumber))."
                )
                if !archive.controlHashVerified {
                    outcome.logLines.append("Warning: control hash does not match — file damaged?")
                }
            }
            outcome.docStatus = .waitingToStart
        } catch {
            outcome.docStatus = .notValid
            outcome.logLines.append("Could not read PAR data: \(error)")
        }
        return outcome
    }

    /// A dropped/opened folder anchors on the first index-looking `.par2` inside it (then any
    /// `.par2`, then a PAR1 `.par`); a file anchors on itself when it has a PAR extension.
    private nonisolated static func anchorFile(for url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            let ext = url.pathExtension.lowercased()
            let isPar1Volume =
                ext.count == 3 && ext.first == "p" && ext.dropFirst().allSatisfy(\.isNumber)
            return (ext == "par2" || ext == "par" || isPar1Volume) ? url : nil
        }
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)
        else { return nil }
        // contentsOfDirectory order is unspecified — sort first so which set anchors a
        // folder-open is deterministic.
        let par2s = entries.filter { $0.pathExtension.lowercased() == "par2" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let index = par2s.first(where: {
            Par2VolumeName.parse(filename: $0.lastPathComponent)?.role == .index
        }) {
            return index
        }
        if let any = par2s.first {
            return any
        }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first { $0.pathExtension.lowercased() == "par" }
    }

    private struct Scope: Sendable {
        let url: URL
        let didStart: Bool
        func end() {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
    }

    private nonisolated static func beginScopedAccess(_ url: URL) -> Scope {
        // Round-trip through a security-scoped bookmark when possible (dropped URLs need it);
        // fall back to direct access (fileImporter URLs are scoped already).
        if let bookmark = try? ScopedAccess.bookmark(for: url),
            let resolved = try? ScopedAccess.resolve(bookmark)
        {
            return Scope(url: resolved.url, didStart: resolved.didStart)
        }
        return Scope(url: url, didStart: url.startAccessingSecurityScopedResource())
    }

    /// `keepingDocument` preserves the parsed set, header, and anchor across an engine run
    /// (the engine re-emits the roster; the document identity does not change). `keepingLog`
    /// carries the output pane across a CHAINED operation (verify → post-process extraction)
    /// so the user sees the whole pipeline's history. (ROADMAP Phase 5)
    private func reset(keepingDocument: Bool = false, keepingLog: Bool = false) {
        rows.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        docStatus = .waitingToStart
        progress = 0
        if !keepingLog {
            log.removeAll(keepingCapacity: true)
        }
        placedURL = nil
        lastError = nil
        if !keepingDocument {
            parSet = nil
            openedURL = nil
            anchorURL = nil
        }
    }

    /// Events are applied as they arrive — @Observable already coalesces SwiftUI invalidation
    /// per main-runloop turn, so count-based batching only delayed the first paint (the roster
    /// sat unapplied until 256 events accumulated). If profiling at the 32k-row scale test
    /// (Phase 3) shows pressure, reintroduce a TIME-based flush, never a count threshold.
    private func consume(_ stream: AsyncStream<EngineEvent>) async {
        for await event in stream {
            guard !Task.isCancelled else { return }
            apply([event])
        }
    }

    /// Fold one coalesced batch of events into the model in a single pass. (ARCHITECTURE.md §4.2)
    private func apply(_ batch: [EngineEvent]) {
        for event in batch {
            switch event {
            case .scanningStarted:
                docStatus = .checking
            case .filesDiscovered(let files):
                rows = files
                indexByID = Dictionary(
                    files.enumerated().map { ($1.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            case .fileStatusChanged(let id, let status):
                if let i = indexByID[id] { rows[i].status = status }
            case .overallProgress(let fraction):
                progress = fraction
            case .logLine(let line):
                log.append(line)
            case .docStatusChanged(let status):
                docStatus = status
            case .extractionPlaced(let url):
                placedURL = url
            case .finished(let result):
                progress = 1
                if case .failure(let error) = result {
                    lastError = error
                    switch error {
                    case .cancelled:
                        // Either cancel() already restored terminal state (task cancellation),
                        // or the ENGINE reported a user-cancel (e.g. Cancel at the destination-
                        // conflict dialog) — then the running status must be cleared here or
                        // the window shows "Extracting files…" forever.
                        if docStatus == .checking || docStatus == .repairing
                            || docStatus == .extracting || docStatus == .creating
                        {
                            docStatus = .waitingToStart
                        }
                    case .notImplemented:
                        docStatus = .internalError
                        log.append("Operation failed: not implemented yet.")
                    case .launchFailed(let reason):
                        // The create engine already published .createFailed as the authoritative
                        // terminal status; don't override it with the parse-failure status.
                        if docStatus != .createFailed { docStatus = .notValid }
                        log.append("Could not start the operation: \(reason)")
                    case .engine(let code, let message):
                        if docStatus == .checking || docStatus == .repairing {
                            docStatus = .internalError
                        } else if docStatus == .extracting {
                            docStatus = .extractionFailed
                        } else if docStatus == .creating || docStatus == .createFailed {
                            docStatus = .createFailed
                        }
                        log.append("Engine failed (code \(code)): \(message)")
                    case .passwordNeeded:
                        docStatus = .extractionFailed
                        log.append(
                            "This archive is password-protected — enter the password to extract it."
                        )
                    case .badPassword:
                        docStatus = .extractionFailed
                        log.append("The password is wrong (or the encrypted data is damaged).")
                    case .volumeMissing(let name):
                        docStatus = .extractionFailed
                        log.append("A required volume is missing: \(name)")
                    }
                }
                // Terminal state must be atomic from an observer's perspective: the UI's
                // retry-on-badPassword fires on lastError and guards on !isBusy, so busy must
                // clear in the SAME main-actor job that published the error (the post-consume
                // setBusy(false) is a backstop that runs a suspension point later).
                setBusy(false)
                // A green verify/repair end is the post-processing trigger (ROADMAP Phase 5).
                // Extraction runs never bump it — a chained extraction must not re-chain.
                if case .success = result, runKind == .verifyRepair, docStatus.isGreenEndState {
                    postProcessReady += 1
                }
                // Settlement signal LAST: by the time the queue's deferred check runs, any
                // chain or retry the UI fires off this event has already re-marked busy.
                runEnded += 1
            }
        }
    }
}
