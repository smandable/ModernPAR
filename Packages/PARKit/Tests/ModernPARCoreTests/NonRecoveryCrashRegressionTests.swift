import Foundation
import Par2Kit
import Testing

@testable import ModernPARCore

/// Regression tests for the vendored par2cmdline-turbo non-recovery-file crash class — the
/// "MODERNPAR PATCH" sites in `Packages/PARKit/Sources/Par2Cxx/vendor/src/par2repairer.cpp`
/// and `par2repairersourcefile.{h,cpp}` (recorded in that tree's `vendor/VENDORED.txt`).
///
/// A crafted or third-party `.par2` can list a file in the Main packet's NON-recovery set (an
/// "other file": it gets a FileDesc but `AllocateSourceBlocks` never assigns its source/target
/// DataBlock iterators, since only recoverable files are allocated). Upstream then dereferenced
/// that unassigned iterator during verification/repair and SIGSEGV'd on any non-recovery file
/// with size > 0. Because ModernPAR runs this engine IN-PROCESS (Par2Shim), that crash took down
/// the whole app. A separate logic bug counted an intact non-recovery file into completefilecount,
/// so a set with an intact "other" file plus a damaged recoverable file reported success without
/// repairing.
///
/// These drive the real `EmbeddedEngine` in-process, so reverting the vendor patch turns each
/// crash back into a hard test-process failure (a SIGSEGV, not a soft assertion).
///
/// The fixture `Fixtures/par2-nonrecovery/` is a real par2 set (real IFSC + recovery volumes,
/// built with par2cmdline) whose Main packet also lists `readme.txt` in the NON-recovery set;
/// `readme.txt` is present in the folder but only recorded, not protected.
struct NonRecoveryCrashRegressionTests {

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/par2-nonrecovery")

    /// Copy the fixture into a scratch dir so damage/removal doesn't touch the committed files.
    private func stageFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonrec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(
            at: Self.fixtureDir, includingPropertiesForKeys: nil)
        {
            try FileManager.default.copyItem(
                at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
        return dir
    }

    private func route(anchor: URL, folder: URL) throws -> SessionRoute {
        SessionRoute(
            mode: .verifyRepair,
            folderBookmark: try? ScopedAccess.bookmark(for: folder),
            anchorBookmark: try ScopedAccess.bookmark(for: anchor))
    }

    private func collect(_ stream: AsyncStream<EngineEvent>) async -> [EngineEvent] {
        var events: [EngineEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func finalStatuses(in events: [EngineEvent]) -> [UUID: FileStatus] {
        var statuses: [UUID: FileStatus] = [:]
        for case .fileStatusChanged(let id, let status) in events { statuses[id] = status }
        return statuses
    }

    private func docStatuses(in events: [EngineEvent]) -> [DocStatus] {
        events.compactMap { if case .docStatusChanged(let s) = $0 { return s } else { return nil } }
    }

    private func roster(in events: [EngineEvent]) -> [FileEntry]? {
        events.compactMap { if case .filesDiscovered(let f) = $0 { return f } else { return nil } }
            .first
    }

    private func terminalIsSuccess(_ events: [EngineEvent]) -> Bool {
        if case .finished(.success)? = events.last { return true }
        return false
    }

    /// Row id for a file by its display name (matches how OperationSession keys rows).
    private func id(of name: String, anchor: URL) throws -> UUID {
        let set = try Par2Parser.loadSet(anchor: anchor)
        return try #require(
            set.descriptions.values.first { $0.preferredName == name }?.fileID.uuid)
    }

    private func damageFirstBytes(_ url: URL, count: Int = 1200) throws {
        var data = try Data(contentsOf: url)
        for i in 0..<min(count, data.count) { data[i] ^= 0xA5 }
        try data.write(to: url)
    }

    // MARK: - The crash (site 1): non-recovery file present & matching (the reported repro)

    @Test func intactSetWithNonRecoveryFileVerifiesWithoutCrashing() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let anchor = dir.appendingPathComponent("set.par2")

        let engine = EmbeddedEngine(repairsAutomatically: false)
        let events = await collect(engine.run(try route(anchor: anchor, folder: dir)))

        #expect(terminalIsSuccess(events))  // completed, no SIGSEGV

        // The roster shows the non-recovery file as "not in set".
        let files = try #require(roster(in: events))
        #expect(files.count == 3)
        #expect(files.first { $0.name == "readme.txt" }?.status == .notInSet)

        // Both recoverable files verify OK; the whole set is correct.
        let statuses = finalStatuses(in: events)
        #expect(statuses[try id(of: "data.bin", anchor: anchor)] == .ok)
        #expect(statuses[try id(of: "good.bin", anchor: anchor)] == .ok)
        #expect(docStatuses(in: events).contains(.allFilesOK))
    }

    // MARK: - The logic bug: an intact non-recovery file must not mask a damaged recoverable one

    @Test func damagedRecoverableFileIsNotMaskedByIntactNonRecoveryFile() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let anchor = dir.appendingPathComponent("set.par2")
        // Remove the recovery volumes so repair is genuinely impossible, then damage a
        // recoverable file. readme.txt stays intact. Before the fix, counting the intact
        // non-recovery file into completefilecount reached RecoverableFileCount() and made the
        // engine report "All files are correct" (eSuccess) despite the damaged data.bin.
        for file in try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        where file.lastPathComponent.contains(".vol") {
            try FileManager.default.removeItem(at: file)
        }
        try damageFirstBytes(dir.appendingPathComponent("data.bin"))

        let engine = EmbeddedEngine(repairsAutomatically: false)
        let events = await collect(engine.run(try route(anchor: anchor, folder: dir)))

        #expect(terminalIsSuccess(events))  // eRepairNotPossible is a clean terminal, not a crash
        // The damaged recoverable file is correctly flagged (NOT masked by the intact readme).
        #expect(
            finalStatuses(in: events)[try id(of: "data.bin", anchor: anchor)]
                == .unrecoverableCorrupt)
        // And the verdict is NOT "all files correct".
        #expect(!docStatuses(in: events).contains(.allFilesOK))
    }

    // MARK: - The repair path (sites 4/5): repair with a non-recovery file present

    @Test func repairSucceedsAndLeavesNonRecoveryFileUntouched() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let anchor = dir.appendingPathComponent("set.par2")
        let readme = dir.appendingPathComponent("readme.txt")
        let readmeBefore = try Data(contentsOf: readme)
        let dataURL = dir.appendingPathComponent("data.bin")
        let dataOriginal = try Data(contentsOf: dataURL)
        try damageFirstBytes(dataURL)

        let engine = EmbeddedEngine()  // auto-repair
        let events = await collect(engine.run(try route(anchor: anchor, folder: dir)))

        #expect(terminalIsSuccess(events))
        #expect(finalStatuses(in: events)[try id(of: "data.bin", anchor: anchor)] == .recovered)
        #expect(docStatuses(in: events).contains(.restoredSuccessfully))
        #expect(try Data(contentsOf: dataURL) == dataOriginal)  // byte-identical restoration
        #expect(try Data(contentsOf: readme) == readmeBefore)  // non-recovery file untouched
    }

    // MARK: - The crash (site 3): non-recovery file present but corrupt

    @Test func corruptNonRecoveryFileVerifiesWithoutCrashing() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let anchor = dir.appendingPathComponent("set.par2")
        try damageFirstBytes(dir.appendingPathComponent("readme.txt"), count: 64)

        let engine = EmbeddedEngine(repairsAutomatically: false)
        let events = await collect(engine.run(try route(anchor: anchor, folder: dir)))

        #expect(terminalIsSuccess(events))  // no SIGSEGV
        // The recoverable files verify OK; a corrupt NON-recovery file must not be flagged as a
        // recoverable problem, but it is honestly surfaced as "only non-recoverable missing"
        // rather than overstating "all files are correct".
        let statuses = finalStatuses(in: events)
        #expect(statuses[try id(of: "data.bin", anchor: anchor)] == .ok)
        #expect(statuses[try id(of: "good.bin", anchor: anchor)] == .ok)
        #expect(!statuses.values.contains(.recoverableCorrupt))
        #expect(docStatuses(in: events).contains(.onlyNonRecoverableMissing))
        #expect(!docStatuses(in: events).contains(.allFilesOK))
    }

    // MARK: - Reporting: a missing non-recovery file is "only non-recoverable missing", not "all OK"

    @Test func missingNonRecoveryFileIsReportedAsOnlyNonRecoverableMissing() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let anchor = dir.appendingPathComponent("set.par2")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("readme.txt"))

        let engine = EmbeddedEngine(repairsAutomatically: false)
        let events = await collect(engine.run(try route(anchor: anchor, folder: dir)))

        #expect(terminalIsSuccess(events))  // no SIGSEGV, no recreated file
        // The recoverable files are OK; the missing "other" file is neither counted as a missing
        // set member nor left "all correct" — it maps to the original's DocStatus13.
        #expect(finalStatuses(in: events)[try id(of: "data.bin", anchor: anchor)] == .ok)
        #expect(finalStatuses(in: events)[try id(of: "good.bin", anchor: anchor)] == .ok)
        #expect(docStatuses(in: events).contains(.onlyNonRecoverableMissing))
        #expect(!docStatuses(in: events).contains(.allFilesOK))
        // The non-recovery row stays "not in set" — never a dangling "checking"/"missing".
        #expect(finalStatuses(in: events)[try id(of: "readme.txt", anchor: anchor)] == .notInSet)
        #expect(
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent("readme.txt").path))
    }
}
