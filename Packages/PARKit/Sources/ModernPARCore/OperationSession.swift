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
    }

    private func reset() {
        rows.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        docStatus = .waitingToStart
        progress = 0
        log.removeAll(keepingCapacity: true)
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
                    uniqueKeysWithValues: files.enumerated().map { ($1.id, $0) }
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
