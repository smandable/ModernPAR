import Foundation
import Testing

@testable import ModernPARCore

/// Create-side math and validation (ROADMAP Phase 6): block-size derivation, source/recovery
/// block counts, and the original's validation bounds.
struct CreateOptionsTests {

    // MARK: - Source / recovery block math

    @Test func sourceBlocksRoundUpPerFileNotOverTheTotal() {
        // Two 1-byte files at a 1000-byte block = 2 blocks, NOT ceil(2/1000)=1.
        #expect(RecoveryMath.sourceBlockCount(fileSizes: [1, 1], blockSize: 1000) == 2)
        #expect(RecoveryMath.sourceBlockCount(fileSizes: [1000, 1500], blockSize: 1000) == 3)
        #expect(RecoveryMath.sourceBlockCount(fileSizes: [], blockSize: 1000) == 0)
        #expect(RecoveryMath.sourceBlockCount(fileSizes: [1000], blockSize: 0) == 0)
    }

    @Test func recoveryBlockCountFollowsRedundancy() {
        #expect(RecoveryMath.recoveryBlockCount(sourceBlocks: 1000, redundancyPercent: 10) == 100)
        #expect(RecoveryMath.recoveryBlockCount(sourceBlocks: 1000, redundancyPercent: 5) == 50)
        // Rounds, and never drops to 0 when redundancy is requested over real data.
        #expect(RecoveryMath.recoveryBlockCount(sourceBlocks: 3, redundancyPercent: 10) == 1)
        #expect(RecoveryMath.recoveryBlockCount(sourceBlocks: 0, redundancyPercent: 10) == 0)
        #expect(RecoveryMath.recoveryBlockCount(sourceBlocks: 1000, redundancyPercent: 0) == 0)
        // Clamps to the 65535 ceiling (70000 × 100% would be 70000).
        #expect(
            RecoveryMath.recoveryBlockCount(sourceBlocks: 70_000, redundancyPercent: 100)
                == 65_535)
    }

    @Test func automaticBlockSizeTargetsAHealthyBlockCountAndIsMultipleOfFour() {
        let size = RecoveryMath.automaticBlockSize(totalBytes: 200_000_000)  // 200 MB
        #expect(size % 4 == 0)
        let blocks = RecoveryMath.sourceBlockCount(fileSizes: [200_000_000], blockSize: size)
        #expect(blocks >= 1500 && blocks <= 2500, "≈2000 target, got \(blocks)")
        // Tiny / empty input floors at 4.
        #expect(RecoveryMath.automaticBlockSize(totalBytes: 0) == 4)
        #expect(RecoveryMath.automaticBlockSize(totalBytes: 100) == 4)
    }

    @Test func blockSizeIsRaisedUntilSourceBlocksFitThePAR2Ceiling() {
        // A 1 GiB file at a 4-byte block would be 268M blocks — must be bumped under 32768.
        let big: UInt64 = 1 << 30
        let size = RecoveryMath.blockSizeFitting(
            fileSizes: [big], preferred: 4, maxSourceBlocks: 32_768)
        #expect(size % 4 == 0)
        #expect(RecoveryMath.sourceBlockCount(fileSizes: [big], blockSize: size) <= 32_768)
    }

    // MARK: - effectiveBlockSize / validation

    @Test func effectiveBlockSizeHonorsManualAndFitsTheCeiling() {
        let opts = CreateOptions(blockSize: .kilobytes(64))
        #expect(opts.effectiveBlockSize(fileSizes: [1_000_000]) == 64 * 1024)

        // A 1-KB manual block over a 1 GiB file would exceed 32768 blocks → auto-raised.
        let tiny = CreateOptions(blockSize: .kilobytes(1))
        let size = tiny.effectiveBlockSize(fileSizes: [1 << 30])
        #expect(RecoveryMath.sourceBlockCount(fileSizes: [1 << 30], blockSize: size) <= 32_768)
    }

    @Test func validationReproducesTheOriginalBounds() {
        let files: [UInt64] = [1_000_000]
        #expect(CreateOptions(redundancyPercent: 10).validationErrors(fileSizes: files).isEmpty)

        #expect(
            CreateOptions(redundancyPercent: 0).validationErrors(fileSizes: files)
                .contains { $0.contains("between 1 and 100") })
        #expect(
            CreateOptions(redundancyPercent: 101).validationErrors(fileSizes: files)
                .contains { $0.contains("between 1 and 100") })
        #expect(
            CreateOptions(blockSize: .kilobytes(0)).validationErrors(fileSizes: files)
                .contains { $0.contains("between 1 and 419430") })
        #expect(
            CreateOptions(blockSize: .kilobytes(419_431)).validationErrors(fileSizes: files)
                .contains { $0.contains("between 1 and 419430") })
        #expect(
            CreateOptions().validationErrors(fileSizes: []).contains {
                $0.contains("at least one non-empty file")
            })
        #expect(
            CreateOptions().validationErrors(fileSizes: [0, 0]).contains {
                $0.contains("at least one non-empty file")
            })
    }

    @Test func validationValidatesTheEffectiveBlockSizeConsistently() {
        // A too-small MANUAL block over one big file is RAISED to fit (effectiveBlockSize),
        // so it validates clean — no contradiction with the window's preview. (Phase 6 review)
        #expect(
            CreateOptions(blockSize: .kilobytes(1)).validationErrors(fileSizes: [1 << 30]).isEmpty)
        // The ceiling is genuinely unfittable only when there are more files than blocks —
        // and that now fails in EVERY mode, including automatic.
        let manyFiles = Array(repeating: UInt64(1), count: 40_000)
        #expect(
            CreateOptions(blockSize: .automatic).validationErrors(fileSizes: manyFiles)
                .contains { $0.contains("at most 32768") })
        #expect(
            CreateOptions(blockSize: .kilobytes(64)).validationErrors(fileSizes: manyFiles)
                .contains { $0.contains("at most 32768") })
    }

    @Test func optionsRoundTripThroughCodable() throws {
        let original = CreateOptions(
            redundancyPercent: 7, blockSize: .kilobytes(128), fileScheme: .uniform)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CreateOptions.self, from: data) == original)
    }
}
