import Foundation
import Testing

@testable import ModernPARCore

/// The file table's "Blocks needed" column (report of 2026-09-15: `FileEntry.blocksNeeded` was
/// never assigned, so every row showed "—"). Session folding and clearing against a scripted
/// engine, plus the native PAR1 engine's counts. The PAR2 engines are covered in Par2KitTests
/// (TurboOutputParserTests, Par2BlocksNeededTests).
@MainActor
struct BlocksNeededTests {

    private func run(_ events: [EngineEvent]) async throws -> OperationSession {
        let session = OperationSession()
        session.start(
            SessionRoute(mode: .verifyRepair), engine: Phase3Tests.ScriptedEngine(events: events))
        for _ in 0..<400 where session.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.isBusy)
        return session
    }

    private func counts(_ session: OperationSession) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: session.rows.map { ($0.name, $0.blocksNeeded) })
    }

    // MARK: - Session

    @Test func verdictCountsLandOnTheirRows() async throws {
        let damaged = FileEntry(name: "a.rar", sizeBytes: 1)
        let missing = FileEntry(name: "b.rar", sizeBytes: 1)
        let fine = FileEntry(name: "c.rar", sizeBytes: 1)
        let session = try await run([
            .filesDiscovered([damaged, missing, fine]),
            .fileStatusChanged(id: fine.id, status: .ok),
            .fileStatusChanged(id: damaged.id, status: .recoverableCorrupt),
            .fileBlocksNeeded(id: damaged.id, blocks: 9),
            .fileStatusChanged(id: missing.id, status: .unrecoverableMissing),
            .fileBlocksNeeded(id: missing.id, blocks: 100),
            .fileBlocksNeeded(id: UUID(), blocks: 5),  // not a row: ignored
            .fileBlocksNeeded(id: fine.id, blocks: 3),  // an OK row never carries a count
            .docStatusChanged(.needMoreRecovery(blocks: 7)),
            .finished(.success(OperationSummary(stillMissing: 2))),
        ])
        #expect(counts(session) == ["a.rar": 9, "b.rar": 100, "c.rar": 0])
    }

    @Test func leavingTheDamagedStatesClearsTheCount() async throws {
        let rows = ["recovered", "renamed", "rechecked", "downgraded", "negative"].map {
            FileEntry(name: $0, sizeBytes: 1)
        }
        var events: [EngineEvent] = [.filesDiscovered(rows)]
        for row in rows {
            events.append(.fileStatusChanged(id: row.id, status: .recoverableCorrupt))
            events.append(.fileBlocksNeeded(id: row.id, blocks: 4))
        }
        events += [
            .fileStatusChanged(id: rows[0].id, status: .recovered),  // a successful repair
            .fileStatusChanged(id: rows[1].id, status: .renamed(from: "x")),
            .fileStatusChanged(id: rows[2].id, status: .checking),  // post-repair re-verify
            .fileStatusChanged(id: rows[3].id, status: .unrecoverableCorrupt),  // still damaged
            .fileBlocksNeeded(id: rows[4].id, blocks: -3),
            .finished(.success(OperationSummary())),
        ]
        let session = try await run(events)
        #expect(
            counts(session) == [
                "recovered": 0, "renamed": 0, "rechecked": 0, "downgraded": 4, "negative": 0,
            ])
    }

    // MARK: - Native PAR1 engine

    static let par1Fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        .appendingPathComponent("par1")

    private func stagePar1(_ subdir: String) throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("par1-blocks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(
            at: Self.par1Fixtures.appendingPathComponent(subdir), to: scratch)
        return scratch
    }

    private func par1Counts(anchor: URL, autoRepair: Bool) async throws -> [String: Int] {
        var route = SessionRoute(mode: .verifyRepair, autoRepair: autoRepair)
        let folder = anchor.deletingLastPathComponent()
        route.folderBookmark = try? ScopedAccess.bookmark(for: folder)
        route.anchorBookmark = try ScopedAccess.bookmark(for: anchor)
        var names: [UUID: String] = [:]
        var counts: [String: Int] = [:]
        for await event in Par1Engine().run(route) {
            if case .filesDiscovered(let files) = event {
                for file in files { names[file.id] = file.name }
            } else if case .fileBlocksNeeded(let id, let blocks) = event {
                counts[names[id] ?? "?"] = blocks
            }
        }
        return counts
    }

    @Test func par1DamagedInSetFilesNeedOneBlockEach() async throws {
        // A PAR1 volume is exactly one recovery block covering every in-set file.
        let folder = try stagePar1("five-files")
        defer { try? FileManager.default.removeItem(at: folder) }
        let corrupt = folder.appendingPathComponent("three.dat")
        var data = try Data(contentsOf: corrupt)
        data[5] ^= 0xFF
        try data.write(to: corrupt)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("five.dat"))

        let counts = try await par1Counts(
            anchor: folder.appendingPathComponent("fivefiles.par"), autoRepair: false)
        #expect(counts == ["three.dat": 1, "five.dat": 1])
    }

    @Test func par1NonContributingFilesGetNoCount() async throws {
        // A file that never contributed to the parity can't be rebuilt by any volume.
        let folder = try stagePar1("noncontrib")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("extra.dat"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("p.dat"))

        let counts = try await par1Counts(
            anchor: folder.appendingPathComponent("noncontrib.par"), autoRepair: false)
        #expect(counts == ["p.dat": 1])
    }

    @Test func par1SessionClearsCountsAfterARepair() async throws {
        let folder = try stagePar1("five-files")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("two.dat"))
        let session = OperationSession()
        // PAR1 runs share one engine queue with the other PAR1 suites — deadline, not a count.
        func waitUntil(_ done: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(120)
            while !done(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        session.open(
            folder.appendingPathComponent("fivefiles.par"), thenVerifyUsing: Par1Engine(),
            autoRepair: false)
        try await waitUntil { !session.isBusy && session.docStatus == .repairNeeded }
        #expect(session.rows.first { $0.name == "two.dat" }?.blocksNeeded == 1)

        session.startVerify(using: Par1Engine(), autoRepair: true)
        try await waitUntil { !session.isBusy }
        #expect(session.docStatus == .restoredSuccessfully)
        #expect(session.rows.allSatisfy { $0.blocksNeeded == 0 })
    }
}
