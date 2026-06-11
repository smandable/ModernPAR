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
    private var pendingVerifyAutoRepair: Bool?
    /// What the user opened (file or folder) and the `.par2`/`.par` it anchored to — kept so
    /// Verify can hand the engine a route with fresh security-scoped bookmarks.
    public private(set) var openedURL: URL?
    public private(set) var anchorURL: URL?

    /// Fast id → index map kept in sync with `rows` so batch application stays O(events), not O(n²).
    private var indexByID: [UUID: Int] = [:]
    private var task: Task<Void, Never>?

    public init() {}

    public func start(_ route: SessionRoute, engine: any PAR2Engine) {
        cancel()
        reset(keepingDocument: true)
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
        route.anchorBookmark = try? ScopedAccess.bookmark(for: anchorURL)
        route.folderBookmark = folderGrantBookmark()
        start(route, engine: engine)
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
            if docStatus == .checking || docStatus == .repairing {
                docStatus = .waitingToStart
            }
        }
    }

    /// The grant-aware verify entry point — menus, toolbar, and the open-chain all route
    /// through here so the one-time folder-grant flow can never be bypassed. (ROADMAP Phase 3)
    public func requestVerify(using engine: any PAR2Engine, autoRepair: Bool) {
        guard anchorURL != nil, !isBusy else { return }
        if needsFolderGrant {
            pendingVerifyAutoRepair = autoRepair
            awaitingFolderGrant = true
        } else {
            startVerify(using: engine, autoRepair: autoRepair)
        }
    }

    /// Surface an open/restore failure that happens before any parse can run (e.g. a restored
    /// window whose bookmark no longer resolves).
    public func reportOpenFailure(_ message: String) {
        docStatus = .notValid
        log.append(message)
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
                    self.pendingVerifyAutoRepair = autoRepair
                    self.awaitingFolderGrant = true
                } else {
                    self.startVerify(using: engine, autoRepair: autoRepair)
                }
            }
        }
    }

    /// The folder grant was given (and persisted by the caller); run the deferred verify.
    public func folderGrantResolved(using engine: any PAR2Engine) {
        awaitingFolderGrant = false
        startVerify(using: engine, autoRepair: pendingVerifyAutoRepair ?? true)
        pendingVerifyAutoRepair = nil
    }

    /// The user declined the folder grant; stay open in parse-only mode.
    public func folderGrantDeclined() {
        awaitingFolderGrant = false
        pendingVerifyAutoRepair = nil
        log.append(
            "Folder access not granted — verify would report every data file as missing. Use the Verify button after granting access, or open the enclosing folder."
        )
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
    /// (the engine re-emits the roster; the document identity does not change).
    private func reset(keepingDocument: Bool = false) {
        rows.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        docStatus = .waitingToStart
        progress = 0
        log.removeAll(keepingCapacity: true)
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
            case .finished(let result):
                progress = 1
                if case .failure(let error) = result {
                    switch error {
                    case .cancelled:
                        break  // cancel() already restored terminal state
                    case .notImplemented:
                        docStatus = .internalError
                        log.append("Operation failed: not implemented yet.")
                    case .launchFailed(let reason):
                        docStatus = .notValid
                        log.append("Could not start the operation: \(reason)")
                    case .engine(let code, let message):
                        if docStatus == .checking || docStatus == .repairing {
                            docStatus = .internalError
                        }
                        log.append("Engine failed (code \(code)): \(message)")
                    }
                }
            }
        }
    }
}
