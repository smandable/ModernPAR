import Foundation
import Testing

@testable import ModernPARCore

/// Regression tests for the confirmed findings of the Phase 6 adversarial review.
@MainActor
struct CreateReviewRegressionTests {

    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("createrr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Finding (MEDIUM): automatic block size let a >32768-file set through canCreate; the engine
    // then rejected it. validationErrors must catch it in EVERY block-size mode.
    @Test func tooManyFilesFailsValidationInAutomaticMode() {
        let manyFiles = Array(repeating: UInt64(1), count: 40_000)
        let auto = CreateOptions(redundancyPercent: 10, blockSize: .automatic)
        let errors = auto.validationErrors(fileSizes: manyFiles)
        #expect(errors.contains { $0.contains("at most 32768") }, "got \(errors)")

        // A normal set still validates clean in automatic mode.
        #expect(
            CreateOptions(blockSize: .automatic)
                .validationErrors(fileSizes: [200_000_000]).isEmpty)
    }

    // Finding (MEDIUM): the over-32768 error and the preview's effective block size must agree.
    // For an oversized-but-raisable MANUAL size, effectiveBlockSize raises it to fit → NO error.
    @Test func oversizedManualBlockRaisesInsteadOfContradicting() {
        let opts = CreateOptions(blockSize: .kilobytes(1))
        let big: [UInt64] = [1 << 30]  // 1 GiB
        // effectiveBlockSize raises the 1 KB block until source blocks fit the ceiling.
        let effective = opts.effectiveBlockSize(fileSizes: big)
        let blocks = RecoveryMath.sourceBlockCount(fileSizes: big, blockSize: effective)
        #expect(blocks <= CreateOptions.maxSourceBlocks)
        // ...and because it fits, validation reports NO contradiction.
        #expect(opts.validationErrors(fileSizes: big).isEmpty, "raisable size must validate clean")
    }

    // Finding (LOW): the one-folder rule must resolve symlinks so /tmp and /private/tmp (or any
    // aliased path) count as the same folder.
    @Test func oneFolderRuleResolvesSymlinks() throws {
        let real = try makeFolder()
        defer { try? FileManager.default.removeItem(at: real) }
        try Data("a".utf8).write(to: real.appendingPathComponent("a.bin"))
        try Data("b".utf8).write(to: real.appendingPathComponent("b.bin"))

        // A symlink to the same folder, added as a second "different" path.
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }

        let model = CreateModel()
        model.add([real.appendingPathComponent("a.bin")])
        let added = model.add([link.appendingPathComponent("b.bin")])  // same folder via symlink
        #expect(added == ["b.bin"], "symlinked path to the same folder must be accepted")
        #expect(model.items.count == 2)
    }

    // Finding (LOW): a dropped folder with subfolders must warn (not silently drop nested files).
    @Test func droppedFolderWithSubfolderWarnsAboutSkippedContent() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("top".utf8).write(to: dir.appendingPathComponent("top.bin"))
        let sub = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: sub.appendingPathComponent("deep.bin"))

        let model = CreateModel()
        model.add([dir])
        #expect(model.items.map(\.name) == ["top.bin"], "only top-level files added")
        #expect(model.lastRejection?.contains("subfolders were skipped") == true)
    }
}
