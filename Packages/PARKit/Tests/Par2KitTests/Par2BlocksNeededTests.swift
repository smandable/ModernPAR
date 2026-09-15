import Foundation
import ModernPARCore
import Testing

@testable import Par2Kit

/// The file table's "Blocks needed" column against the real embedded engine (report of
/// 2026-09-15: every damaged or missing row showed "—"). Counts must match what par2cmdline
/// reports per file, add up to the engine's own set-level shortfall, and clear once a repair
/// succeeds. The helper-process parity case lives in HelperProcessEngineTests (serialized).
struct Par2BlocksNeededTests {

    private func route(for set: DamagedVolumeSet) throws -> SessionRoute {
        SessionRoute(
            mode: .verifyRepair,
            folderBookmark: try? ScopedAccess.bookmark(for: set.folder),
            anchorBookmark: try ScopedAccess.bookmark(for: set.parFile))
    }

    private func verify(_ set: DamagedVolumeSet, repairs: Bool = false) async throws
        -> [EngineEvent]
    {
        var events: [EngineEvent] = []
        for await event in EmbeddedEngine(repairsAutomatically: repairs).run(try route(for: set)) {
            events.append(event)
        }
        return events
    }

    private func finalStatuses(_ events: [EngineEvent]) -> [UUID: FileStatus] {
        var statuses: [UUID: FileStatus] = [:]
        for case .fileStatusChanged(let id, let status) in events { statuses[id] = status }
        return statuses
    }

    @Test func verifyReportsEachDamagedVolumesBlocksNeeded() async throws {
        let set = try DamagedVolumeSet.make()
        defer { set.remove() }
        try set.applyReportedDamage()

        let events = try await verify(set)
        #expect(try set.blocksNeeded(in: events) == DamagedVolumeSet.reportedDamage)
        #expect(DamagedVolumeSet.missingDataBlocks(in: events) == 110)
        let ids = try set.rowIDs()
        let statuses = finalStatuses(events)
        #expect(statuses[try #require(ids["movie.part03.rar"])] == .recoverableMissing)
        #expect(statuses[try #require(ids["movie.part05.rar"])] == .recoverableCorrupt)
        #expect(statuses[try #require(ids["movie.part08.rar"])] == .recoverableCorrupt)
    }

    @Test func blocksHeldByOtherFilesCountTowardTheirTarget() async throws {
        let set = try DamagedVolumeSet.make()
        defer { set.remove() }
        try set.applyForeignDamage()

        let events = try await verify(set)
        let counts = try set.blocksNeeded(in: events)
        #expect(counts == DamagedVolumeSet.foreignDamage)
        // The per-file attribution reconciles exactly with the engine's own total.
        #expect(counts.values.reduce(0, +) == DamagedVolumeSet.missingDataBlocks(in: events))
    }

    @Test func interruptedRepairLeftoversCountOnce() async throws {
        let set = try DamagedVolumeSet.make()
        defer { set.remove() }
        try set.applyInterruptedRepairShape()

        let events = try await verify(set)
        #expect(try set.blocksNeeded(in: events) == DamagedVolumeSet.interruptedRepair)
        #expect(DamagedVolumeSet.missingDataBlocks(in: events) == 10)
    }

    @Test func zeroedRegionMatchingAnotherTargetsZeroBlockStaysClose() async throws {
        // a.bin's zeroed blocks match missing b.bin's all-zero block, so the engine prints
        // `damaged, found 18 data blocks from several target files` with no per-target split.
        // Truth is a.bin 3 / b.bin 4; the holder-owns-all rule gives 2 / 5 — never "all 20" —
        // and the per-file counts still add up to the engine's shortfall.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocks-mixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let block = DamagedVolumeSet.blockSize
        func random(_ count: Int) -> Data {
            var bytes = [UInt8](repeating: 0, count: count)
            arc4random_buf(&bytes, count)
            return Data(bytes)
        }
        let a = folder.appendingPathComponent("a.bin")
        let b = folder.appendingPathComponent("b.bin")
        try random(block * 20).write(to: a)
        try (random(block * 2) + Data(count: block) + random(block * 2)).write(to: b)
        let parFile = folder.appendingPathComponent("mixed.par2")
        try Par2Create.createSet(
            parFile: parFile, files: [a, b], blockSize: UInt64(block), recoveryBlockCount: 10)
        try FileManager.default.removeItem(at: b)
        var damaged = try Data(contentsOf: a)
        damaged.replaceSubrange(block * 5..<block * 8, with: Data(count: block * 3))
        try damaged.write(to: a)

        var events: [EngineEvent] = []
        let route = SessionRoute(
            mode: .verifyRepair, folderBookmark: try? ScopedAccess.bookmark(for: folder),
            anchorBookmark: try ScopedAccess.bookmark(for: parFile))
        for await event in EmbeddedEngine(repairsAutomatically: false).run(route) {
            events.append(event)
        }
        let set = try Par2Parser.loadSet(anchor: parFile)
        let names = Dictionary(
            uniqueKeysWithValues: set.descriptions.values.map { ($0.fileID.uuid, $0.preferredName) }
        )
        var counts: [String: Int] = [:]
        for case .fileBlocksNeeded(let id, let blocks) in events {
            counts[names[id] ?? "?"] = blocks
        }
        #expect(counts == ["a.bin": 2, "b.bin": 5])
        #expect(DamagedVolumeSet.missingDataBlocks(in: events) == 7)
    }

    @Test func insufficientRecoveryStillReportsPerFileCounts() async throws {
        let set = try DamagedVolumeSet.make(recoveryBlocks: 20)
        defer { set.remove() }
        try set.applyReportedDamage()

        let events = try await verify(set, repairs: true)
        #expect(try set.blocksNeeded(in: events) == DamagedVolumeSet.reportedDamage)
        let docStatuses = events.compactMap { event -> DocStatus? in
            if case .docStatusChanged(let status) = event { return status }
            return nil
        }
        #expect(docStatuses.last == .needMoreRecovery(blocks: 90))
        let statuses = finalStatuses(events)
        #expect(
            statuses[try #require(try set.rowIDs()["movie.part03.rar"])] == .unrecoverableMissing)
    }

    @Test func zeroFilledVolumeIsRepairedAndCountedAsRepaired() async throws {
        // The engine reports a target holding none of its blocks as `File: "…" - no data
        // found.`, not a Target line: it must still go damaged → recovered and count.
        let set = try DamagedVolumeSet.make()
        defer { set.remove() }
        let victim = "movie.part10.rar"
        let original = try set.contents(victim)
        try Data(count: original.count).write(to: set.url(victim))

        let events = try await verify(set, repairs: true)
        let id = try #require(try set.rowIDs()[victim])
        let trail = events.compactMap { event -> FileStatus? in
            if case .fileStatusChanged(id, let status) = event { return status }
            return nil
        }
        #expect(trail.contains(.recoverableCorrupt))
        #expect(trail.last == .recovered)
        #expect(try set.blocksNeeded(in: events) == [victim: 100])
        guard case .finished(.success(let summary))? = events.last else {
            Issue.record("expected a successful finish, got \(String(describing: events.last))")
            return
        }
        #expect(summary.repaired == 1)
        #expect(try set.contents(victim) == original)
    }

    @MainActor
    @Test func sessionShowsCountsAfterVerifyAndClearsThemAfterRepair() async throws {
        let set = try DamagedVolumeSet.make()
        defer { set.remove() }
        try set.applyReportedDamage()
        let session = OperationSession()

        // Generous deadlines: engine runs process-wide are one at a time, so these can queue
        // behind other suites' big creates and repairs on a loaded CI runner.
        func waitUntil(_ done: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(180)
            while !done(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        // A restored window's consent-first path: verify only, then repair on request.
        session.open(set.parFile, thenVerifyUsing: EmbeddedEngine(), autoRepair: false)
        try await waitUntil { !session.isBusy && session.docStatus == .repairNeeded }
        #expect(session.docStatus == .repairNeeded)
        let shown = Dictionary(
            uniqueKeysWithValues: session.rows.filter { $0.blocksNeeded > 0 }.map {
                ($0.name, $0.blocksNeeded)
            })
        #expect(shown == DamagedVolumeSet.reportedDamage)

        session.startVerify(using: EmbeddedEngine(), autoRepair: true)
        try await waitUntil { !session.isBusy }
        #expect(session.docStatus == .restoredSuccessfully)
        #expect(session.rows.allSatisfy { $0.blocksNeeded == 0 })
        #expect(session.rows.filter { $0.status == .recovered }.count == 3)
    }
}
