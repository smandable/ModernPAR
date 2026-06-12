import Foundation
import ModernPARCore
import Testing

@testable import ArchiveKit

/// Segment disposal after extraction (ROADMAP Phase 7; doc-01 §5.4 "delete segments after
/// extraction"): only a FULLY successful run may dispose of the set's volumes, only the
/// volumes the engine actually used, and never the placed output. `swift test` runs
/// unsandboxed, so `FileManager.trashItem` is exercised for real.
struct SegmentDisposalTests {

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/rar")

    private func stage(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unrar-disposal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.copyItem(
                at: Self.fixtureDir.appendingPathComponent(name),
                to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func runExtract(
        anchor: String,
        in folder: URL,
        disposal: SegmentDisposal,
        password: String? = nil,
        conflicts: ConflictPolicy = .cancel
    ) async throws -> [EngineEvent] {
        let route = SessionRoute(
            mode: .extractArchive,
            folderBookmark: try? ScopedAccess.bookmark(for: folder),
            anchorBookmark: try ScopedAccess.bookmark(for: folder.appendingPathComponent(anchor)))
        let stream = RARExtractor().extract(
            route, options: ExtractOptions(segmentDisposal: disposal),
            password: CountingPasswordProvider(password),
            conflicts: AutoConflictResolver(conflicts))
        var events: [EngineEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func succeeded(_ events: [EngineEvent]) -> Bool {
        for event in events.reversed() {
            if case .finished(let result) = event {
                if case .success = result { return true }
            }
        }
        return false
    }

    private func logLines(_ events: [EngineEvent]) -> [String] {
        events.compactMap {
            if case .logLine(let line) = $0 { return line }
            return nil
        }
    }

    private func exists(_ name: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    // MARK: - Disposal on full success

    @Test func trashDisposalMovesEveryVolumeOfAnOldStyleSetToTheTrash() async throws {
        let volumes = ["rar3-old.rar", "rar3-old.r00", "rar3-old.r01"]
        let folder = try stage(volumes)
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(
            anchor: "rar3-old.rar", in: folder, disposal: .moveToTrash)
        #expect(succeeded(events))
        for volume in volumes {
            #expect(!exists(volume, in: folder), "\(volume) should have been trashed")
        }
        #expect(exists("vols/bigfile.txt", in: folder))
        #expect(logLines(events).contains("Moved 3 segment(s) to the Trash."))
    }

    @Test func permanentDisposalDeletesEveryVolumeOfANewStyleSet() async throws {
        let volumes = ["rar5-vols.part1.rar", "rar5-vols.part2.rar", "rar5-vols.part3.rar"]
        let folder = try stage(volumes)
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(
            anchor: "rar5-vols.part1.rar", in: folder, disposal: .deletePermanently)
        #expect(succeeded(events))
        for volume in volumes {
            #expect(!exists(volume, in: folder), "\(volume) should have been deleted")
        }
        #expect(exists("vols/bigfile.txt", in: folder))
        #expect(exists("vols/smallfile.txt", in: folder))
        #expect(logLines(events).contains("Deleted 3 segment(s)."))
    }

    @Test func leaveDisposalTouchesNothing() async throws {
        let volumes = ["rar5-vols.part1.rar", "rar5-vols.part2.rar", "rar5-vols.part3.rar"]
        let folder = try stage(volumes)
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(
            anchor: "rar5-vols.part1.rar", in: folder, disposal: .leave)
        #expect(succeeded(events))
        for volume in volumes {
            #expect(exists(volume, in: folder), "\(volume) must be left in place")
        }
        #expect(!logLines(events).contains { $0.contains("segment(s)") })
    }

    @Test func singleVolumeArchiveIsDisposedToo() async throws {
        let folder = try stage(["rar5-crc.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(
            anchor: "rar5-crc.rar", in: folder, disposal: .deletePermanently)
        #expect(succeeded(events))
        #expect(!exists("rar5-crc.rar", in: folder))
        #expect(exists("rar5-crc/stest1.txt", in: folder))
        #expect(logLines(events).contains("Deleted 1 segment(s)."))
    }

    // MARK: - Never on anything but full success

    @Test func perFileFailureLeavesEveryVolumeInPlace() async throws {
        // corrupt-middle: one damaged file mid-archive — output IS placed, but the run is
        // not a full success, so the archive must survive for a repair-and-retry.
        let folder = try stage(["corrupt-middle.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(
            anchor: "corrupt-middle.rar", in: folder, disposal: .deletePermanently)
        #expect(!succeeded(events))
        #expect(exists("corrupt-middle.rar", in: folder))
        #expect(!logLines(events).contains { $0.contains("segment(s)") })
    }

    @Test func wrongPasswordLeavesEveryVolumeInPlace() async throws {
        // The UI re-prompts and re-runs after a bad password — the volumes must still exist
        // for that retry.
        let folder = try stage(["rar5-psw.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(
            anchor: "rar5-psw.rar", in: folder, disposal: .moveToTrash,
            password: "wrong-password")
        #expect(!succeeded(events))
        #expect(exists("rar5-psw.rar", in: folder))
        #expect(!logLines(events).contains { $0.contains("segment(s)") })
    }

    @Test func missingVolumeLeavesThePresentVolumesInPlace() async throws {
        let folder = try stage(["rar5-vols.part1.rar", "rar5-vols.part2.rar"])  // part3 absent
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(
            anchor: "rar5-vols.part1.rar", in: folder, disposal: .deletePermanently)
        #expect(!succeeded(events))
        #expect(exists("rar5-vols.part1.rar", in: folder))
        #expect(exists("rar5-vols.part2.rar", in: folder))
        #expect(!logLines(events).contains { $0.contains("segment(s)") })
    }

    // MARK: - The placed output is sacrosanct

    @Test func disposalNeverTouchesThePlacedOutput() async throws {
        // Extensionless archive named exactly like its would-be output folder: placement
        // renames the output to "rar5-crc 2", disposal then deletes the archive itself —
        // and must leave the renamed output alone.
        let folder = try stage(["rar5-crc.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensionless = folder.appendingPathComponent("rar5-crc")
        try FileManager.default.moveItem(
            at: folder.appendingPathComponent("rar5-crc.rar"), to: extensionless)
        let events = try await runExtract(
            anchor: "rar5-crc", in: folder, disposal: .deletePermanently,
            conflicts: .overwrite)
        #expect(succeeded(events))
        #expect(!exists("rar5-crc", in: folder), "the archive itself should be disposed")
        #expect(exists("rar5-crc 2/stest1.txt", in: folder), "the placed output must survive")
        #expect(exists("rar5-crc 2/stest2.txt", in: folder))
    }

    // MARK: - Partial delivery never disposes (Phase 7 review)

    @Test func skippedEntriesLeaveEveryVolumeInPlace() async throws {
        // rar5-symlink-unix.rar succeeds with its unsafe symlink SKIPPED (warning-class) —
        // a partially-delivered run must keep the volumes, even under permanent deletion.
        let folder = try stage(["rar5-symlink-unix.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(
            anchor: "rar5-symlink-unix.rar", in: folder, disposal: .deletePermanently)
        #expect(succeeded(events))
        #expect(exists("rar5-symlink-unix.rar", in: folder), "skipped entries → keep segments")
        #expect(
            logLines(events).contains { $0.contains("Leaving the archive segments in place") })
    }

    // MARK: - Fixed destination staleness (Phase 7 review)

    private func runFixedDestination(
        archive: String, in folder: URL, bookmark: Data
    ) async throws -> [EngineEvent] {
        let route = SessionRoute(
            mode: .extractArchive,
            folderBookmark: try? ScopedAccess.bookmark(for: folder),
            anchorBookmark: try ScopedAccess.bookmark(
                for: folder.appendingPathComponent(archive)))
        let stream = RARExtractor().extract(
            route, options: ExtractOptions(destination: .fixed(bookmark: bookmark)),
            password: CountingPasswordProvider(nil),
            conflicts: AutoConflictResolver(.cancel))
        var events: [EngineEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func movedFixedDestinationFallsBackBesideTheArchive() async throws {
        // A security-scoped bookmark follows its folder by file ID (into the Trash, or
        // anywhere) and resolves STALE — extraction must not chase it.
        let folder = try stage(["rar3-comment-plain.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let chosen = folder.appendingPathComponent("ChosenDest")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
        let bookmark = try ScopedAccess.bookmark(for: chosen)
        let moved = folder.appendingPathComponent("MovedDest")
        try FileManager.default.moveItem(at: chosen, to: moved)

        let events = try await runFixedDestination(
            archive: "rar3-comment-plain.rar", in: folder, bookmark: bookmark)
        #expect(succeeded(events))
        #expect(
            exists("rar3-comment-plain/file1.txt", in: folder),
            "output must land beside the archive, not chase the moved folder")
        #expect(
            (try? FileManager.default.contentsOfDirectory(atPath: moved.path))?.isEmpty == true,
            "nothing may be extracted into the moved destination")
        #expect(logLines(events).contains { $0.contains("unavailable or has moved") })
    }

    @Test func deletedFixedDestinationFallsBackBesideTheArchive() async throws {
        let folder = try stage(["rar3-comment-plain.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let chosen = folder.appendingPathComponent("GoneDest")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
        let bookmark = try ScopedAccess.bookmark(for: chosen)
        try FileManager.default.removeItem(at: chosen)

        let events = try await runFixedDestination(
            archive: "rar3-comment-plain.rar", in: folder, bookmark: bookmark)
        #expect(succeeded(events))
        #expect(exists("rar3-comment-plain/file1.txt", in: folder))
        #expect(logLines(events).contains { $0.contains("unavailable or has moved") })
    }
}
