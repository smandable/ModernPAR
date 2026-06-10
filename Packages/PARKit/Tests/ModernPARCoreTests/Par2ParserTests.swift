import Foundation
import Testing

@testable import ModernPARCore

/// Golden-fixture tests for the read-only PAR2 parser.
///
/// `Fixtures/par2cmdline/` holds a set created by par2cmdline 1.1.1 (`par2 create -s1000 -c7`)
/// over four deterministic data files. Cross-tool corpora (turbo, MultiPar, ParPar) join in
/// Phase 2 when the engine lands — reading them goes through this same suite.
struct Par2ParserTests {

    static let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        .appendingPathComponent("par2cmdline")
    var anchor: URL { Self.fixtures.appendingPathComponent("set.par2") }

    // MARK: Golden metadata round-trip

    @Test func indexFileAloneYieldsFullMetadata() throws {
        let set = try Par2Parser.assembleSet(from: [anchor])
        #expect(set.sliceSize == 1000)
        #expect(set.recoveryFileIDs.count == 4)
        #expect(set.nonRecoveryFileIDs.isEmpty)
        #expect(set.descriptions.count == 4)
        // The bare index carries no recovery slices.
        #expect(set.recoveryBlockCount == 0)
        #expect(set.setIDVerified)
        #expect(set.corruptPacketCount == 0)
        #expect(set.creator?.contains("par2cmdline") == true)
    }

    @Test func wholeSetYieldsRecoveryBlockCountAndRedundancy() throws {
        let set = try Par2Parser.loadSet(anchor: anchor)
        // file-a 10000→10, file-b 3000→3, naïve-ü 800→1, tiny 500→1 = 15 source blocks.
        #expect(set.sourceBlockCount == 15)
        // -c7 across vol0+1, vol1+2, vol3+4 = exponents 0...6.
        #expect(set.recoveryBlockCount == 7)
        #expect(set.recoveryExponents == Set(0..<7))
        #expect(abs(set.redundancyPercent - (7.0 / 15.0 * 100)) < 0.01)
        #expect(set.totalDataBytes == 10000 + 3000 + 800 + 500)
    }

    @Test func fileDescriptionsMatchTheDataOnDisk() throws {
        let set = try Par2Parser.loadSet(anchor: anchor)
        let byName = Dictionary(
            uniqueKeysWithValues: set.descriptions.values.map { ($0.preferredName, $0) })
        let expected: [(String, UInt64, Int)] = [
            ("file-a.bin", 10000, 10), ("file-b.bin", 3000, 3),
            ("naïve-ü.bin", 800, 1), ("tiny.bin", 500, 1),
        ]
        for (name, size, blocks) in expected {
            let d = try #require(byName[name], "missing \(name)")
            #expect(d.length == size)
            #expect(d.fileIDVerified, "File ID = MD5(16k‖len‖name) must reproduce for \(name)")
            #expect(
                RecoveryMath.sourceBlocks(fileSize: d.length, sliceSize: set.sliceSize) == blocks)
            // Full-file MD5 must match the actual bytes on disk.
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
            #expect(MD5Digest.hash(data) == d.fileMD5)
            // And every file has a complete IFSC slice-checksum list.
            #expect(set.sliceChecksums[d.fileID]?.count == blocks)
        }
    }

    @Test func recoveryFileIDOrderingIsCanonicalAndSorted() throws {
        let set = try Par2Parser.loadSet(anchor: anchor)
        // Main-packet File IDs are sorted numerically ascending — and "numerically" means the
        // 16 bytes interpreted as a little-endian integer (par2cmdline compares from the last
        // byte down), NOT memcmp order. Verified against the golden fixture. (03 §2.3)
        let littleEndianOrder = set.recoveryFileIDs.map { [UInt8]($0.bytes.reversed()) }
        #expect(
            littleEndianOrder
                == littleEndianOrder.sorted { $0.lexicographicallyPrecedes($1) })
    }

    // MARK: Corruption tolerance

    @Test func corruptPacketIsSkippedNotFatal() throws {
        var data = try Data(contentsOf: anchor)
        // Flip one byte inside the body of the *second* packet so the first stays valid.
        let second = try #require(
            data.firstRange(
                of: Par2Parser.packetMagic,
                in: (data.startIndex + 1)..<data.endIndex)
        )
        data[second.lowerBound + 70] ^= 0xFF
        let scan = Par2Parser.scan(data)
        #expect(scan.corruptCandidates >= 1)
        // Damaging one packet costs exactly one packet.
        let intact = Par2Parser.scan(try Data(contentsOf: anchor))
        #expect(scan.packets.count == intact.packets.count - 1)
    }

    @Test func corruptMainInOneFileIsRecoveredFromVolumeCopies() throws {
        // Damage every packet in the index file, then assemble with the volume files — the
        // duplicated metadata packets must still produce the full set.
        var broken = try Data(contentsOf: anchor)
        for i in stride(from: 0, to: broken.count, by: 61) {
            broken[broken.startIndex + i] ^= 0xA5
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-\(UUID().uuidString).par2")
        try broken.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vols = ["set.vol0+1.par2", "set.vol1+2.par2", "set.vol3+4.par2"].map {
            Self.fixtures.appendingPathComponent($0)
        }
        let set = try Par2Parser.assembleSet(from: [tmp] + vols)
        #expect(set.sourceBlockCount == 15)
        #expect(set.descriptions.count == 4)
        #expect(set.recoveryBlockCount == 7)
    }

    @Test func garbagePrependedAndAppendedIsTolerated() throws {
        var data = Data(repeating: 0x55, count: 137)  // unaligned garbage before the first magic
        data.append(try Data(contentsOf: anchor))
        data.append(Data(repeating: 0xAA, count: 99))
        let scan = Par2Parser.scan(data)
        let intact = Par2Parser.scan(try Data(contentsOf: anchor))
        #expect(scan.packets.count == intact.packets.count)
    }

    @Test func emptyAndNonParInputsThrow() throws {
        #expect(throws: Par2Parser.ParseError.noValidPackets) {
            _ = try Par2Parser.assembleSet(from: [])
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-par-\(UUID().uuidString).par2")
        try Data("just some text, no packets here".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(throws: Par2Parser.ParseError.noValidPackets) {
            _ = try Par2Parser.assembleSet(from: [tmp])
        }
    }

    // MARK: Display math & bridging

    @Test func needMoreBlocksMath() {
        #expect(
            RecoveryMath.additionalBlocksNeeded(missingSourceBlocks: 9, availableRecoveryBlocks: 7)
                == 2)
        #expect(
            RecoveryMath.additionalBlocksNeeded(missingSourceBlocks: 7, availableRecoveryBlocks: 7)
                == 0)
        #expect(
            RecoveryMath.additionalBlocksNeeded(missingSourceBlocks: 0, availableRecoveryBlocks: 7)
                == 0)
        #expect(RecoveryMath.sourceBlocks(fileSize: 0, sliceSize: 1000) == 0)
        #expect(RecoveryMath.sourceBlocks(fileSize: 1, sliceSize: 1000) == 1)
        #expect(RecoveryMath.sourceBlocks(fileSize: 1000, sliceSize: 1000) == 1)
        #expect(RecoveryMath.sourceBlocks(fileSize: 1001, sliceSize: 1000) == 2)
    }

    @Test func volumeNameParsing() {
        let vol = Par2VolumeName.parse(filename: "set.vol3+4.par2")
        #expect(
            vol == Par2VolumeName(baseName: "set", role: .volume(firstExponent: 3, blockCount: 4)))
        let padded = Par2VolumeName.parse(filename: "My Stuff.vol007+08.PAR2")
        #expect(
            padded
                == Par2VolumeName(
                    baseName: "My Stuff", role: .volume(firstExponent: 7, blockCount: 8)))
        // Case-insensitivity of the "vol" marker itself.
        #expect(
            Par2VolumeName.parse(filename: "x.VOL003+04.par2")
                == Par2VolumeName(baseName: "x", role: .volume(firstExponent: 3, blockCount: 4)))
        #expect(Par2VolumeName.parse(filename: "set.par2")?.role == .index)
        #expect(Par2VolumeName.parse(filename: "set.par2")?.baseName == "set")
        #expect(Par2VolumeName.parse(filename: "movie.mkv") == nil)
        // ".vol" inside a base name (the $-anchored suffix match is load-bearing: a wrong
        // classification would flip which file anchors a folder open).
        #expect(Par2VolumeName.parse(filename: "my.vol.backup.par2")?.role == .index)
        #expect(Par2VolumeName.parse(filename: "a.vol1+2.extra.par2")?.role == .index)
        #expect(Par2VolumeName.parse(filename: "x.vol1.par2")?.role == .index)
        // Digit overflow falls back to index rather than trapping.
        #expect(
            Par2VolumeName.parse(filename: "x.vol99999999999999999999+1.par2")?.role == .index)
    }

    @Test func bridgesToParSetForTheUI() throws {
        let set = try Par2Parser.loadSet(anchor: anchor)
        let parSet = ParSet(par2: set)
        #expect(parSet.kind == .par2)
        #expect(parSet.files.count == 4)
        #expect(parSet.sliceSizeBytes == 1000)
        #expect(parSet.sourceBlockCount == 15)
        #expect(parSet.recoveryBlocksAvailable == 7)
        #expect(parSet.files.allSatisfy { $0.status == .pending })
        // Stable row identity: the UUID is the 16-byte PAR2 File ID.
        let ids = Set(parSet.files.map(\.id))
        #expect(ids.count == 4)
    }
}
