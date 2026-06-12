import Foundation
import ModernPARCore
import Testing

@testable import ArchiveKit

/// Phase 8 polish in the archive path: numeric-split (`.001`) and SFX (`.exe`) first-file
/// forms, and the per-run "Overwrite All" conflict answer. (ROADMAP Phase 8)
struct Phase8PolishTests {

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/rar")

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase8-polish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func runExtract(anchor: URL, folder: URL) async throws -> [EngineEvent] {
        let route = SessionRoute(
            mode: .extractArchive,
            folderBookmark: try? ScopedAccess.bookmark(for: folder),
            anchorBookmark: try ScopedAccess.bookmark(for: anchor))
        let stream = RARExtractor().extract(
            route, options: ExtractOptions(),
            password: CountingPasswordProvider(nil),
            conflicts: AutoConflictResolver(.cancel))
        var events: [EngineEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func succeeded(_ events: [EngineEvent]) -> Bool {
        for event in events.reversed() {
            if case .finished(let result) = event, case .success = result { return true }
        }
        return false
    }

    private func finalError(_ events: [EngineEvent]) -> EngineError? {
        for event in events.reversed() {
            if case .finished(let result) = event, case .failure(let error) = result {
                return error
            }
        }
        return nil
    }

    // MARK: - Numeric splits (`name.001`)

    /// Stages the old-style three-volume set under split names: rar → .001, r00 → .002,
    /// r01 → .003.
    private func stageNumericSplit(in dir: URL, includeFirst: Bool = true) throws {
        let mapping = [
            ("rar3-old.rar", "split.001"), ("rar3-old.r00", "split.002"),
            ("rar3-old.r01", "split.003"),
        ]
        for (source, target) in mapping {
            if !includeFirst, target == "split.001" { continue }
            try FileManager.default.copyItem(
                at: Self.fixtureDir.appendingPathComponent(source),
                to: dir.appendingPathComponent(target))
        }
    }

    @Test func numericSplitSetExtractsFromItsFirstPiece() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stageNumericSplit(in: dir)
        let events = try await runExtract(
            anchor: dir.appendingPathComponent("split.001"), folder: dir)
        #expect(succeeded(events), "got \(String(describing: finalError(events)))")
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("vols/bigfile.txt").path))
    }

    @Test func numericSplitMidPieceAnchorsOnTheFirst() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stageNumericSplit(in: dir)
        let events = try await runExtract(
            anchor: dir.appendingPathComponent("split.002"), folder: dir)
        #expect(succeeded(events))
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("vols/bigfile.txt").path))
    }

    @Test func numericSplitWithoutItsFirstPieceFailsFast() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stageNumericSplit(in: dir, includeFirst: false)
        let events = try await runExtract(
            anchor: dir.appendingPathComponent("split.002"), folder: dir)
        #expect(finalError(events) == .volumeMissing("split.001"))
    }

    // MARK: - SFX (`name.exe`)

    @Test func sfxExecutableExtracts() async throws {
        // A synthetic SFX: 4 KB of stub bytes, then a real RAR5 archive — the engine scans
        // past the stub for the signature, exactly like real WinRAR SFX output.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var bytes = Data([0x4D, 0x5A])  // "MZ"
        bytes.append(Data(repeating: 0x90, count: 4094))
        bytes.append(try Data(contentsOf: Self.fixtureDir.appendingPathComponent("rar5-crc.rar")))
        let sfx = dir.appendingPathComponent("selfextract.exe")
        try bytes.write(to: sfx)

        #expect(ArchiveFileTypes.isRARArchive(sfx))
        let events = try await runExtract(anchor: sfx, folder: dir)
        #expect(succeeded(events), "got \(String(describing: finalError(events)))")
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("selfextract/stest1.txt").path))
    }

    // MARK: - Routing sniffs (Core's ArchiveFileTypes)

    @Test func numericSplitRoutingRequiresTheRARSignature() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realSplit = dir.appendingPathComponent("real.001")
        try FileManager.default.copyItem(
            at: Self.fixtureDir.appendingPathComponent("rar3-old.rar"), to: realSplit)
        #expect(ArchiveFileTypes.isRARArchive(realSplit))

        let garbage = dir.appendingPathComponent("video.001")
        try Data(repeating: 0x42, count: 64).write(to: garbage)
        #expect(!ArchiveFileTypes.isRARArchive(garbage))

        let plainExe = dir.appendingPathComponent("tool.exe")
        try Data(repeating: 0x00, count: 2048).write(to: plainExe)
        #expect(!ArchiveFileTypes.isRARArchive(plainExe))
    }

    @Test func numericSplitVolumeNamingHelpers() {
        #expect(RARVolumes.numericSplitNumber("a.001") == 1)
        #expect(RARVolumes.numericSplitNumber("a.099") == 99)
        #expect(RARVolumes.numericSplitNumber("a.0001") == nil)
        #expect(RARVolumes.numericSplitNumber("a.r00") == nil)
        #expect(RARVolumes.baseName(for: URL(fileURLWithPath: "/x/split.001")) == "split")
        #expect(
            RARVolumes.belongsToSet(
                URL(fileURLWithPath: "/x/split.003"),
                firstVolume: URL(fileURLWithPath: "/x/split.001")))
        #expect(
            !RARVolumes.belongsToSet(
                URL(fileURLWithPath: "/x/other.003"),
                firstVolume: URL(fileURLWithPath: "/x/split.001")))
    }

    // MARK: - Overwrite All

    @Test func overwriteAllAnswersEveryLaterConflictInTheRun() async throws {
        final class CountingResolver: ConflictResolver, @unchecked Sendable {
            let calls = ValueBox<Int>(0)
            func resolve(conflictAt url: URL) async -> ConflictPolicy {
                calls.set(calls.get() + 1)
                return .overwriteAll
            }
        }
        let resolver = CountingResolver()
        let broker = ConflictBroker(resolver: resolver, token: ExtractCancelToken())
        let url = URL(fileURLWithPath: "/tmp/x")
        #expect(broker.resolveSync(conflictAt: url) == .overwrite)
        #expect(broker.resolveSync(conflictAt: url) == .overwrite)
        #expect(broker.resolveSync(conflictAt: url) == .overwrite)
        #expect(resolver.calls.get() == 1, "Overwrite All must suppress every later dialog")
    }
}
