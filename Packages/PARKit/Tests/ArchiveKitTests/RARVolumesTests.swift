import Foundation
import Testing

@testable import ArchiveKit

/// Pure naming/placement logic (ROADMAP Phase 4: first-file forms `.rar` + `.rNN` and
/// `.partNN.rar`; output folder named after the archive with the extension stripped).
struct RARVolumesTests {

    // MARK: - Part-name parsing

    @Test func parsesNewStylePartNames() {
        #expect(RARVolumes.parsePartName("archive.part02.rar")! == ("archive", 2))
        #expect(RARVolumes.parsePartName("archive.part1.rar")! == ("archive", 1))
        #expect(RARVolumes.parsePartName("Archive.PART10.RAR")! == ("Archive", 10))
        #expect(RARVolumes.parsePartName("a.b.part003.rar")! == ("a.b", 3))
        #expect(RARVolumes.parsePartName("archive.rar") == nil)
        #expect(RARVolumes.parsePartName("archive.partX.rar") == nil)
        #expect(RARVolumes.parsePartName("archive.part02") == nil)
        #expect(RARVolumes.parsePartName("archive.r00") == nil)
    }

    @Test func recognizesOldStyleContinuations() {
        #expect(RARVolumes.isOldStyleContinuation("archive.r00"))
        #expect(RARVolumes.isOldStyleContinuation("archive.R99"))
        #expect(RARVolumes.isOldStyleContinuation("archive.s01"))  // after .r99
        #expect(!RARVolumes.isOldStyleContinuation("archive.rar"))
        #expect(!RARVolumes.isOldStyleContinuation("archive.r1"))
        #expect(!RARVolumes.isOldStyleContinuation("archive.q00"))
        #expect(!RARVolumes.isOldStyleContinuation("archive.txt"))
    }

    // MARK: - First-volume normalization

    /// Path equality across the /var → /private/var symlink.
    private func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rarvol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ name: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    @Test func normalizesPartVolumeToLowestPart() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let part1 = touch("set.part01.rar", in: dir)
        let part2 = touch("set.part02.rar", in: dir)
        _ = touch("other.part01.rar", in: dir)
        #expect(samePath(RARVolumes.firstVolume(for: part2), part1))
        #expect(samePath(RARVolumes.firstVolume(for: part1), part1))
    }

    @Test func partNormalizationSurvivesAMissingPartOne() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let part2 = touch("set.part02.rar", in: dir)
        _ = touch("set.part03.rar", in: dir)
        // No part01 on disk: the lowest existing part is the best anchor we have.
        #expect(samePath(RARVolumes.firstVolume(for: part2), part2))
    }

    @Test func normalizesOldStyleContinuationToDotRar() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rar = touch("set.rar", in: dir)
        let r00 = touch("set.r00", in: dir)
        #expect(samePath(RARVolumes.firstVolume(for: r00), rar))
        #expect(samePath(RARVolumes.firstVolume(for: rar), rar))
    }

    // MARK: - Output naming

    @Test func stripsVolumeSuffixesFromBaseName() {
        #expect(
            RARVolumes.baseName(for: URL(fileURLWithPath: "/x/archive.part01.rar")) == "archive")
        #expect(RARVolumes.baseName(for: URL(fileURLWithPath: "/x/archive.rar")) == "archive")
        #expect(RARVolumes.baseName(for: URL(fileURLWithPath: "/x/archive.r00")) == "archive")
        #expect(RARVolumes.baseName(for: URL(fileURLWithPath: "/x/no extension")) == "no extension")
    }

    @Test func uniqueDestinationCountsUpAndKeepsExtensions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(RARVolumes.uniqueDestination(for: folder).lastPathComponent == "Photos 2")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Photos 2"), withIntermediateDirectories: false)
        #expect(RARVolumes.uniqueDestination(for: folder).lastPathComponent == "Photos 3")

        let file = touch("report.pdf", in: dir)
        #expect(RARVolumes.uniqueDestination(for: file).lastPathComponent == "report 2.pdf")
        let fresh = dir.appendingPathComponent("untouched.txt")
        #expect(RARVolumes.uniqueDestination(for: fresh) == fresh)
    }
}
