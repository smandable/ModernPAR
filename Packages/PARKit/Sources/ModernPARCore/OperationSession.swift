import Foundation
import Observation

/// Per-window, observable session driving one verify/repair/create/extract operation.
///
/// It consumes the engine's `AsyncStream<EngineEvent>` and folds COALESCED batches into the model,
/// so a 32 768-row table is never invalidated once per event. Cancellation cancels the consuming
/// `Task`, whose termination kills the child process / stops the native loop (reproduces Cmd-.).
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

    /// Fast id → index map kept in sync with `rows` so batch application stays O(events), not O(n²).
    private var indexByID: [UUID: Int] = [:]
    private var task: Task<Void, Never>?

    public init() {}

    public func start(_ route: SessionRoute, engine: any PAR2Engine) {
        cancel()
        reset()
        isBusy = true
        let stream = engine.run(route)
        task = Task { [weak self] in
            await self?.consume(stream)
            self?.isBusy = false
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        // The cancelled task's completion is discarded (`!Task.isCancelled` guard), so terminal
        // state must be restored here — otherwise the spinner sticks at busy/checking forever.
        if isBusy {
            isBusy = false
            if docStatus == .checking { docStatus = .waitingToStart }
        }
    }

    // MARK: - Opening a set (Phase 1: native parse, no engine)

    /// Opens a `.par2` / `.par` / `.pNN` file — or a folder containing one — and populates the
    /// file table and header from the native read-only parser. Verification is a separate,
    /// user-initiated step (auto-verify arrives with the engine in Phases 2–3).
    public func open(_ url: URL) {
        cancel()
        reset()
        isBusy = true
        docStatus = .checking
        task = Task { [weak self] in
            let outcome = await Self.parse(url: url)
            guard let self, !Task.isCancelled else { return }
            self.parSet = outcome.parSet
            self.rows = outcome.rows
            // first-wins, never trap: row ids are unique by construction, but they derive from
            // untrusted input — Dictionary(uniqueKeysWithValues:) would crash on a duplicate.
            self.indexByID = Dictionary(
                outcome.rows.enumerated().map { ($1.id, $0) },
                uniquingKeysWith: { first, _ in first })
            self.log.append(contentsOf: outcome.logLines)
            self.docStatus = outcome.docStatus
            self.isBusy = false
        }
    }

    private struct ParseOutcome: Sendable {
        var parSet: ParSet?
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

    private func reset() {
        rows.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        docStatus = .waitingToStart
        progress = 0
        log.removeAll(keepingCapacity: true)
        parSet = nil
    }

    private func consume(_ stream: AsyncStream<EngineEvent>) async {
        var batch: [EngineEvent] = []
        for await event in stream {
            batch.append(event)
            if batch.count >= 256 {
                apply(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { apply(batch) }
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
            case .finished:
                progress = 1
            }
        }
    }
}
