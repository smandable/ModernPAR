import Foundation
import Testing

@testable import ModernPARCore

/// One-by-one multi-open processing (doc-01 §5.6 `SimultaneousProcessing` off — the
/// original's default): FIFO queue, a ticket holds its place until settled, closing a queued
/// window withdraws it, and the session's `runEnded` signal marks every settlement point.
/// (ROADMAP Phase 7)
@MainActor
struct MultiOpenQueueTests {

    @Test func firstTicketStartsImmediatelyOthersWait() {
        let queue = MultiOpenQueue()
        var started: [String] = []
        let first = queue.enqueue { _ in started.append("a") }
        queue.enqueue { _ in started.append("b") }
        queue.enqueue { _ in started.append("c") }
        #expect(started == ["a"])

        queue.settle(first)
        #expect(started == ["a", "b"])
    }

    @Test func ticketsRunInFIFOOrder() {
        let queue = MultiOpenQueue()
        var started: [String] = []
        let a = queue.enqueue { _ in started.append("a") }
        let b = queue.enqueue { _ in started.append("b") }
        let c = queue.enqueue { _ in started.append("c") }
        queue.settle(a)
        queue.settle(b)
        queue.settle(c)
        #expect(started == ["a", "b", "c"])
    }

    @Test func settlingAQueuedTicketWithdrawsItWithoutRunningIt() {
        let queue = MultiOpenQueue()
        var started: [String] = []
        let a = queue.enqueue { _ in started.append("a") }
        let b = queue.enqueue { _ in started.append("b") }
        let c = queue.enqueue { _ in started.append("c") }

        // Window B closed while still waiting — its work must never run.
        queue.settle(b)
        queue.settle(a)
        #expect(started == ["a", "c"])
        queue.settle(c)
    }

    @Test func settlingTwiceIsHarmless() {
        let queue = MultiOpenQueue()
        var started: [String] = []
        let a = queue.enqueue { _ in started.append("a") }
        queue.settle(a)
        // Windows settle defensively from several events (run end, close) — the second
        // settle must not disturb the next active ticket.
        let b = queue.enqueue { _ in started.append("b") }
        queue.settle(a)
        #expect(started == ["a", "b"])
        queue.settle(b)
    }

    @Test func enqueueAfterEverythingSettledStartsImmediately() {
        let queue = MultiOpenQueue()
        var started: [String] = []
        let a = queue.enqueue { _ in started.append("a") }
        queue.settle(a)
        queue.enqueue { _ in started.append("b") }
        #expect(started == ["a", "b"])
    }

    @Test func aTicketCanSettleItselfDuringItsOwnSynchronousStart() {
        // A failure exit inside the start closure (cancelled destination panel) settles the
        // ticket it received — the queue must not stay poisoned. The ticket arrives as a
        // closure PARAMETER because a synchronous start runs before enqueue even returns.
        // (Phase 7 review HIGH)
        let queue = MultiOpenQueue()
        var started: [String] = []
        queue.enqueue { ticket in
            started.append("a")
            queue.settle(ticket)
        }
        queue.enqueue { _ in started.append("b") }
        #expect(started == ["a", "b"], "the self-settled ticket must not block the queue")
    }

    // MARK: - The session's settlement signal

    final class ScriptedEngine: PAR2Engine, @unchecked Sendable {
        let events: [EngineEvent]
        init(events: [EngineEvent]) { self.events = events }
        func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
            AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    static let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    private func waitForRunEnd(_ session: OperationSession, from before: Int) async throws {
        for _ in 0..<200 where session.runEnded == before {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(session.runEnded > before, "the pipeline never signalled settlement")
    }

    @Test func finishedRunBumpsRunEnded() async throws {
        let session = OperationSession()
        let engine = ScriptedEngine(events: [
            .docStatusChanged(.allFilesOK),
            .finished(.success(OperationSummary())),
        ])
        let before = session.runEnded
        session.open(
            Self.fixtures.appendingPathComponent("par2cmdline/set.par2"),
            thenVerifyUsing: engine, autoRepair: true)
        try await waitForRunEnd(session, from: before)
        #expect(!session.isBusy)
    }

    @Test func parseOnlyOpenBumpsRunEnded() async throws {
        let session = OperationSession()
        let before = session.runEnded
        // No engine passed — a restored window's parse-only open must still settle.
        session.open(Self.fixtures.appendingPathComponent("par2cmdline/set.par2"))
        try await waitForRunEnd(session, from: before)
    }

    @Test func failedParseBumpsRunEnded() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-garbage-\(UUID().uuidString).par2")
        try Data(repeating: 0x13, count: 64).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let session = OperationSession()
        let before = session.runEnded
        session.open(tmp, thenVerifyUsing: ScriptedEngine(events: []), autoRepair: true)
        try await waitForRunEnd(session, from: before)
        #expect(session.docStatus == .notValid)
    }

    @Test func cancellingABusyRunBumpsRunEnded() async throws {
        let session = OperationSession()
        let before = session.runEnded
        session.open(Self.fixtures.appendingPathComponent("par2cmdline/set.par2"))
        #expect(session.isBusy)
        session.cancel()
        #expect(session.runEnded > before)
    }

    @Test func declinedFolderGrantBumpsRunEnded() {
        let session = OperationSession()
        let before = session.runEnded
        session.folderGrantDeclined()
        #expect(session.runEnded == before + 1)
    }

    @Test func fileTableUsesFinderStyleNameOrdering() {
        // ".sit.2" before ".sit.10" — numeric-aware, not lexicographic.
        let rows = ["archive.sit.10", "archive.sit.2", "b.dat", "A.dat"].map {
            FileEntry(name: $0, sizeBytes: 1)
        }
        let sorted = OperationSession.displaySorted(rows).map(\.name)
        #expect(sorted == ["A.dat", "archive.sit.2", "archive.sit.10", "b.dat"])
    }

    @Test func sortOrderIsConsistentForNonASCIIDigits() {
        // Fullwidth digits produced a comparator CYCLE (92 < b < ５ < 92) — every input
        // rotation of the same set must now sort identically. (Phase 8 review)
        let names = ["92.dat", "b.dat", "\u{FF15}.dat"]
        var results = Set<[String]>()
        for rotation in 0..<names.count {
            let rotated = Array(names[rotation...] + names[..<rotation])
            let sorted = OperationSession.displaySorted(
                rotated.map { FileEntry(name: $0, sizeBytes: 1) }
            ).map(\.name)
            results.insert(sorted)
        }
        #expect(results.count == 1, "a strict weak ordering sorts every rotation the same")
        #expect(results.first == ["\u{FF15}.dat", "92.dat", "b.dat"])
    }

    @Test func paddedDigitTiesFollowFinderOrdering() {
        // Numerically equal runs break ties on padding: "a1" before "a01" (Finder).
        let sorted = OperationSession.displaySorted(
            ["a01.dat", "a1.dat", "file 002", "file 2"].map { FileEntry(name: $0, sizeBytes: 1) }
        ).map(\.name)
        #expect(sorted == ["a1.dat", "a01.dat", "file 2", "file 002"])
    }

    @Test func nonOKSelectionCoversExactlyTheProblemStates() {
        #expect(FileStatus.recoverableMissing.isNonOK)
        #expect(FileStatus.recoverableCorrupt.isNonOK)
        #expect(FileStatus.unrecoverableMissing.isNonOK)
        #expect(FileStatus.unrecoverableCorrupt.isNonOK)
        #expect(FileStatus.possibleError.isNonOK)
        #expect(!FileStatus.ok.isNonOK)
        #expect(!FileStatus.recovered.isNonOK)
        #expect(!FileStatus.renamed(from: "x").isNonOK)
        #expect(!FileStatus.pending.isNonOK)
        #expect(!FileStatus.checking.isNonOK)
        #expect(!FileStatus.notInSet.isNonOK)
    }
}
