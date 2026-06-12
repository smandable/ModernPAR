import Foundation
import Testing

@testable import ModernPARCore

/// The GF(2⁸)/Reed-Solomon core under PAR1. The decisive suite is the GOLDEN ORACLE check:
/// parity we compute must byte-match parity produced by the original Intel `par` binary —
/// that pins the field polynomial (0x11D) and the Vandermonde coefficient scheme (j^(v-1))
/// against the only ground truth that matters for compatibility. (ROADMAP Phase 8)
struct Par1MathTests {

    static let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        .appendingPathComponent("par1")

    // MARK: - Field axioms

    @Test func expAndLogRoundTrip() {
        for a in 1...255 {
            #expect(Int(GF256.exp[Int(GF256.log[a])]) == a)
        }
        #expect(GF256.exp[0] == 1)
        #expect(GF256.exp[1] == 2)
        // The generator's order is exactly 255 (primitive for 0x11D).
        #expect(GF256.exp[255] == 1)
    }

    @Test func multiplicationIsCommutativeAndDistributes() {
        // Sampled, not exhaustive-cubed: 256² products + distributivity over a stride.
        for a in stride(from: 0, through: 255, by: 7) {
            for b in stride(from: 0, through: 255, by: 5) {
                let ab = GF256.mul(UInt8(a), UInt8(b))
                #expect(ab == GF256.mul(UInt8(b), UInt8(a)))
                for c in stride(from: 1, through: 255, by: 51) {
                    let left = GF256.mul(UInt8(a), UInt8(b) ^ UInt8(c))
                    let right = GF256.mul(UInt8(a), UInt8(b)) ^ GF256.mul(UInt8(a), UInt8(c))
                    #expect(left == right)
                }
            }
        }
    }

    @Test func divisionInvertsMultiplication() {
        for a in 1...255 {
            for b in stride(from: 1, through: 255, by: 3) {
                let product = GF256.mul(UInt8(a), UInt8(b))
                #expect(GF256.div(product, UInt8(b)) == UInt8(a))
            }
        }
    }

    @Test func powMatchesRepeatedMultiplication() {
        for base in [1, 2, 3, 5, 17, 254, 255] {
            var acc: UInt8 = 1
            for power in 0...20 {
                #expect(GF256.pow(UInt8(base), power) == acc)
                acc = GF256.mul(acc, UInt8(base))
            }
        }
    }

    @Test func accumulateMatchesScalarDefinition() {
        let src: [UInt8] = (0...255).map { UInt8($0) }
        for coeff in [0, 1, 2, 0x53, 255] {
            var dst = [UInt8](repeating: 0xA5, count: src.count)
            GF256.accumulate(&dst, src: src, coefficient: UInt8(coeff))
            for i in 0..<src.count {
                #expect(dst[i] == 0xA5 ^ GF256.mul(UInt8(coeff), src[i]))
            }
        }
    }

    // MARK: - The golden oracle (Intel par binary parity, byte-for-byte)

    /// Computes volume `v` over padded in-set file bytes exactly as the engine will.
    private func computeVolume(_ volume: Int, files: [[UInt8]]) -> [UInt8] {
        let size = files.map(\.count).max() ?? 0
        var out = [UInt8](repeating: 0, count: size)
        for (index, file) in files.enumerated() {
            var padded = file
            padded.append(contentsOf: repeatElement(0, count: size - file.count))
            GF256.accumulate(
                &out, src: padded,
                coefficient: Par1RS.coefficient(volume: volume, fileIndex: index + 1))
        }
        return out
    }

    @Test func computedParityMatchesTheIntelBinaryByteForByte() throws {
        let alpha = try [UInt8](Data(contentsOf: Self.fixtures.appendingPathComponent("alpha.dat")))
        let beta = try [UInt8](Data(contentsOf: Self.fixtures.appendingPathComponent("beta.dat")))
        for (volume, name) in [(1, "archive.p01"), (2, "archive.p02")] {
            let volumeData = try Data(
                contentsOf: Self.fixtures.appendingPathComponent(name))
            let golden = try #require(Par1Parser.dataArea(volumeData))
            let computed = computeVolume(volume, files: [alpha, beta])
            #expect(
                computed == [UInt8](golden),
                "\(name): our RS math must reproduce the Intel binary's parity exactly")
        }
    }

    // MARK: - Recovery

    @Test func decoderRecoversErasedFilesFromParity() {
        // Five synthetic "files" of assorted sizes, three volumes, erase two files.
        let files: [[UInt8]] = [
            Array("first file".utf8),
            Array("the second file is longer".utf8),
            Array("third".utf8),
            [UInt8]((0..<64).map { UInt8(truncatingIfNeeded: $0 &* 7) }),
            Array("fifth and final".utf8),
        ]
        let size = files.map(\.count).max()!
        let padded = files.map { $0 + [UInt8](repeating: 0, count: size - $0.count) }
        let volumes = [1, 2, 3].map { computeVolume($0, files: files) }

        let missing = [2, 4]
        let intact = [1, 3, 5]
        let decoder = Par1RS.Decoder(
            missing: missing, intact: intact, availableVolumes: [1, 2, 3], fileCount: 5)!
        let recovered = decoder.recoverChunk(
            intactChunks: [1: padded[0], 3: padded[2], 5: padded[4]],
            volumeChunks: [1: volumes[0], 2: volumes[1], 3: volumes[2]],
            chunkSize: size)!
        #expect(recovered[0] == padded[1])
        #expect(recovered[1] == padded[3])
    }

    @Test func decoderUsesOnlyAsManyVolumesAsNeeded() {
        let files: [[UInt8]] = [Array("aaaa".utf8), Array("bbbb".utf8), Array("cccc".utf8)]
        let volumes = [1, 2].map { computeVolume($0, files: files) }
        // One missing file, two volumes available — volume 1 suffices.
        let decoder = Par1RS.Decoder(
            missing: [3], intact: [1, 2], availableVolumes: [1, 2], fileCount: 3)!
        #expect(decoder.usedVolumes == [1])
        let recovered = decoder.recoverChunk(
            intactChunks: [1: files[0], 2: files[1]],
            volumeChunks: [1: volumes[0]],
            chunkSize: 4)!
        #expect(recovered[0] == files[2])
    }

    @Test func decoderRefusesWhenVolumesAreInsufficient() {
        #expect(
            Par1RS.Decoder(missing: [1, 2], intact: [3], availableVolumes: [1], fileCount: 3)
                == nil)
    }

    @Test func decoderRecoversWithNonContiguousVolumeNumbers() {
        // Volume 1 lost, volumes 2 and 3 survive; recover two files from them.
        let files: [[UInt8]] = [
            Array("data one".utf8), Array("data two".utf8), Array("data 333".utf8),
        ]
        let v2 = computeVolume(2, files: files)
        let v3 = computeVolume(3, files: files)
        let decoder = Par1RS.Decoder(
            missing: [1, 3], intact: [2], availableVolumes: [2, 3], fileCount: 3)!
        let recovered = decoder.recoverChunk(
            intactChunks: [2: files[1]],
            volumeChunks: [2: v2, 3: v3],
            chunkSize: 8)!
        #expect(recovered[0] == files[0])
        #expect(recovered[1] == files[2])
    }

    @Test func matrixInversionRoundTrips() {
        // A Vandermonde-derived matrix and its inverse multiply to identity.
        let n = 6
        var matrix = [[UInt8]]()
        for v in 1...n {
            matrix.append((1...n).map { Par1RS.coefficient(volume: v, fileIndex: $0) })
        }
        let inverse = Par1RS.invert(matrix)!
        for i in 0..<n {
            for j in 0..<n {
                var sum: UInt8 = 0
                for k in 0..<n { sum ^= GF256.mul(matrix[i][k], inverse[k][j]) }
                #expect(sum == (i == j ? 1 : 0))
            }
        }
    }

    @Test func singularMatrixReturnsNilNotACrash() {
        // Two identical rows — singular by construction.
        let matrix: [[UInt8]] = [[1, 2, 3], [1, 2, 3], [4, 5, 6]]
        #expect(Par1RS.invert(matrix) == nil)
    }

    @Test func parityOfEqualLengthFilesVolume1IsPlainXOR() {
        let a: [UInt8] = [0xFF, 0x00, 0x55]
        let b: [UInt8] = [0x0F, 0xF0, 0xAA]
        #expect(computeVolume(1, files: [a, b]) == [0xF0, 0xF0, 0xFF])
    }
}
