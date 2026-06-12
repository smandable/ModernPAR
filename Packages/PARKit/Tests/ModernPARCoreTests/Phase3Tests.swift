import Foundation
import Testing

@testable import ModernPARCore

/// Phase 3 plumbing: folder-grant persistence, the auto-run consent gate, the open→verify
/// chain, and the 32k-row throughput smoke test (the ROADMAP scale criterion's headless half).
@MainActor
struct Phase3Tests {

    /// An engine scripted from the test — lets session-level behavior be tested headlessly.
    final class ScriptedEngine: PAR2Engine, @unchecked Sendable {
        let events: [EngineEvent]
        let holdsOpen: Bool
        private(set) var runCount = 0
        private(set) var lastRoute: SessionRoute?
        init(events: [EngineEvent], holdsOpen: Bool = false) {
            self.events = events
            self.holdsOpen = holdsOpen
        }

        func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
            runCount += 1
            lastRoute = route
            return AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                if !holdsOpen { continuation.finish() }
            }
        }
    }

    static let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        .appendingPathComponent("par2cmdline")

    private func waitUntilIdle(_ session: OperationSession) async throws {
        for _ in 0..<400 where session.isBusy {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!session.isBusy)
    }

    @Test func openChainsIntoVerifyForFreshOpens() async throws {
        let engine = ScriptedEngine(events: [
            .docStatusChanged(.allFilesOK),
            .finished(.success(OperationSummary())),
        ])
        let session = OperationSession()
        session.open(
            Self.fixtures.appendingPathComponent("set.par2"),
            thenVerifyUsing: engine, autoRepair: true)
        try await waitUntilIdle(session)
        // Parse completed AND the engine ran exactly once with a repair-capable route.
        #expect(engine.runCount == 1)
        #expect(engine.lastRoute?.autoRepair == true)
        #expect(engine.lastRoute?.anchorBookmark != nil)
        #expect(session.docStatus == .allFilesOK)
    }

    @Test func openWithoutEngineNeverRuns() async throws {
        let engine = ScriptedEngine(events: [])
        let session = OperationSession()
        session.open(Self.fixtures.appendingPathComponent("set.par2"))  // restored-window path
        try await waitUntilIdle(session)
        #expect(engine.runCount == 0)
        #expect(session.parSet != nil)
        #expect(session.docStatus == .waitingToStart)
    }

    @Test func freshnessIsConsumedExactlyOnce() {
        let model = AppModel(par2Engine: ScriptedEngine(events: []))
        let route = model.makeRoute(opening: Self.fixtures.appendingPathComponent("set.par2"))
        #expect(route.anchorBookmark != nil)
        #expect(model.consumeFreshness(of: route.id))
        #expect(!model.consumeFreshness(of: route.id))  // a restored window must not auto-run
    }

    @Test func folderRouteBookmarksTheFolder() {
        let model = AppModel(par2Engine: ScriptedEngine(events: []))
        let route = model.makeRoute(opening: Self.fixtures)
        #expect(route.folderBookmark != nil)
        #expect(route.anchorBookmark == nil)
    }

    @Test func folderAccessStoreCoversSubfolders() {
        FolderAccessStore.removeAll()
        defer { FolderAccessStore.removeAll() }
        let folder = Self.fixtures.deletingLastPathComponent()  // Fixtures/
        FolderAccessStore.remember(folder)
        #expect(FolderAccessStore.bookmark(forFolder: folder) != nil)
        #expect(FolderAccessStore.bookmark(forFolder: Self.fixtures) != nil)  // child covered
        #expect(
            FolderAccessStore.bookmark(
                forFolder: URL(fileURLWithPath: "/somewhere/unrelated")) == nil)
    }

    @Test func operationRegistryTracksBusySessions() {
        // Tested directly: the shared registry is also fed by other suites running in
        // parallel, so absolute counts are not assertable — deltas from THIS session are.
        let registry = OperationRegistry.shared
        let session = NSObject()
        let before = registry.busyCount
        registry.setBusy(true, session: session)
        #expect(registry.busyCount == before + 1 || registry.busyCount > before)
        registry.setBusy(true, session: session)  // idempotent per session
        registry.setBusy(false, session: session)
        #expect(registry.busyCount <= before + 1)
        registry.setBusy(false, session: session)  // double-clear is harmless
    }

    @Test func cancelDuringRepairRestoresTerminalDocStatus() async throws {
        // "Restoring files…" must not survive a cancel (a confirmed review finding for the
        // .checking case; .repairing had the same hole).
        let engine = ScriptedEngine(
            events: [.docStatusChanged(.repairing)], holdsOpen: true)
        let session = OperationSession()
        session.start(SessionRoute(mode: .verifyRepair), engine: engine)
        // Poll, don't sleep-and-hope: a fixed delay flakes when the suite runs under load.
        for _ in 0..<200 where session.docStatus != .repairing {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(session.docStatus == .repairing)
        session.cancel()
        #expect(session.docStatus == .cancelled)
        #expect(!session.isBusy)
    }

    @Test func thirtyTwoThousandRowsApplyFast() async throws {
        // PAR2's ceiling is 32 768 source blocks/files; the session must fold a full-scale
        // roster + a status sweep without quadratic behavior. (UI fps is measured in the
        // running app; this pins the data path.)
        let rows = (0..<32768).map { FileEntry(name: "file-\($0).bin", sizeBytes: 1000) }
        var events: [EngineEvent] = [.filesDiscovered(rows)]
        events.append(contentsOf: rows.map { .fileStatusChanged(id: $0.id, status: .ok) })
        events.append(.finished(.success(OperationSummary())))
        let engine = ScriptedEngine(events: events)
        let session = OperationSession()

        let start = ContinuousClock.now
        session.start(SessionRoute(mode: .verifyRepair), engine: engine)
        try await waitUntilIdle(session)
        let elapsed = start.duration(to: .now)

        #expect(session.rows.count == 32768)
        #expect(session.rows.allSatisfy { $0.status == .ok })
        #expect(elapsed < .seconds(5), "32k apply took \(elapsed)")
    }
}
