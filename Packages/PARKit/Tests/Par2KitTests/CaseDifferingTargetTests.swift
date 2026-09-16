import Foundation
import ModernPARCore
import Testing

@testable import Par2Kit

/// A damaged target whose on-disk name differs from the set's only by case (or by Unicode
/// normalization) must still repair.
///
/// The app hands the engine every data file in the folder as an extra file, which is what finds
/// renamed data and interrupted-repair backups. The engine drops a target from that list only on
/// an exact path match, so on a case-insensitive volume — the macOS default — the damaged file is
/// scanned twice: once as `Movie.part01.rar`, once as `movie.part01.rar`. Its surviving blocks
/// are then counted twice ("You have 20 out of 20 data blocks available" with 5 of 10 damaged),
/// the engine calls the repair possible, and the repair fails with engine code 5. Reproduced with
/// the vendored CLI before the fix; `extraFiles` now drops an entry that is the same FILE as a
/// target, by file identity rather than by spelling.
struct CaseDifferingTargetTests {

    /// True when two spellings of one name reach the same file here (APFS/HFS+ default).
    private func volumeIsCaseInsensitive(_ dir: URL) -> Bool {
        let upper = dir.appendingPathComponent("CaseProbe.tmp")
        try? Data([0x41]).write(to: upper)
        defer { try? FileManager.default.removeItem(at: upper) }
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("caseprobe.tmp").path)
    }

    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casetarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pattern(_ size: Int, seed: UInt32) -> Data {
        var state = seed
        return Data(
            (0..<size).map { _ in
                state = state &* 1_664_525 &+ 1_013_904_223
                return UInt8(truncatingIfNeeded: state >> 24)
            })
    }

    @Test func aTargetUnderADifferentCaseIsNotAlsoScannedAsAnExtraFile() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #require(volumeIsCaseInsensitive(dir), "needs a case-insensitive volume")

        try pattern(4096, seed: 1).write(to: dir.appendingPathComponent("movie.part01.rar"))
        try pattern(4096, seed: 2).write(to: dir.appendingPathComponent("other.bin"))
        let anchor = dir.appendingPathComponent("set.par2")
        try Data([0]).write(to: anchor)

        // The set names the file with a capital M; the folder holds the same file in lower case.
        let extras = EngineRunSupport.extraFiles(
            near: anchor, targetNames: ["Movie.part01.rar", "Missing.bin"])
        #expect(extras.map(\.lastPathComponent) == ["other.bin"])

        // Without the target names (the old behavior) the duplicate comes back.
        #expect(
            EngineRunSupport.extraFiles(near: anchor).map(\.lastPathComponent)
                == ["movie.part01.rar", "other.bin"])
    }

    @Test func aDamagedTargetUnderADifferentCaseStillRepairs() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #require(volumeIsCaseInsensitive(dir), "needs a case-insensitive volume")

        let original = pattern(40960, seed: 7)
        let capitalised = dir.appendingPathComponent("Movie.part01.rar")
        try original.write(to: capitalised)
        let second = dir.appendingPathComponent("Movie.part02.rar")
        try pattern(40960, seed: 8).write(to: second)
        let anchor = dir.appendingPathComponent("set.par2")
        // createSet blocks; keep it off the cooperative pool (Par2Create's own contract).
        let created: Bool = await withCheckedContinuation { continuation in
            EngineRunSupport.serialQueue.async {
                do {
                    try Par2Create.createSet(
                        parFile: anchor, files: [capitalised, second], blockSize: 4096,
                        recoveryBlockCount: 6)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
        try #require(created)

        // Rename to the spelling a downloader or a copy might leave, then damage 5 of 10 blocks.
        let lowercased = dir.appendingPathComponent("movie.part01.rar")
        try FileManager.default.moveItem(at: capitalised, to: lowercased)
        var damaged = try Data(contentsOf: lowercased)
        for index in (4096 * 2)..<(4096 * 7) { damaged[index] ^= 0xA5 }
        try damaged.write(to: lowercased)

        let route = SessionRoute(
            mode: .verifyRepair, folderBookmark: try? ScopedAccess.bookmark(for: dir),
            anchorBookmark: try ScopedAccess.bookmark(for: anchor))
        var events: [EngineEvent] = []
        for await event in EmbeddedEngine(repairsAutomatically: true).run(route) {
            events.append(event)
        }

        // Before the fix: the blocks were counted twice, so the engine promised a repair it
        // could not make and finished with "Repair Failed." (engine code 5).
        let docStatuses = events.compactMap {
            if case .docStatusChanged(let status) = $0 { return status }
            return nil
        }
        #expect(docStatuses.contains { $0.isGreenEndState })
        #expect(!docStatuses.contains(.internalError))
        #expect(try Data(contentsOf: lowercased) == original)
    }
}
