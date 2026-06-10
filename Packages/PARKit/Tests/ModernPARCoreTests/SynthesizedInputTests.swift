import Foundation
import Testing

@testable import ModernPARCore

// MARK: - Byte-level builders for spec-legal and hostile inputs

/// Builds PAR2 packets/sets from raw parts, byte-exact per docs/research/03 §2.
enum Par2Builder {
    static func le32(_ v: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) })
    }
    static func le64(_ v: UInt64) -> Data {
        Data((0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) })
    }
    static func padded(_ data: Data) -> Data {
        var d = data
        while d.count % 4 != 0 { d.append(0) }
        return d
    }

    static func packet(type: Data, setID: Data, body: Data) -> Data {
        let body = padded(body)
        var afterMD5 = Data()  // bytes [32, length): setID ‖ type ‖ body
        afterMD5.append(setID)
        afterMD5.append(type)
        afterMD5.append(body)
        var packet = Data("PAR2\0PKT".utf8)
        packet.append(le64(UInt64(64 + body.count)))
        packet.append(MD5Digest.hash(afterMD5).bytes)
        packet.append(afterMD5)
        return packet
    }

    static func mainBody(sliceSize: UInt64, recoveryIDs: [Data], nonRecoveryIDs: [Data] = [])
        -> Data
    {
        var body = le64(sliceSize)
        body.append(le32(UInt32(recoveryIDs.count)))
        for id in recoveryIDs { body.append(id) }
        for id in nonRecoveryIDs { body.append(id) }
        return body
    }

    /// Returns the FileDesc body and the (correctly derived) File ID for a synthetic file.
    static func fileDesc(name: String, length: UInt64, contentSeed: UInt8) -> (
        body: Data, fileID: Data
    ) {
        let fakeMD5 = MD5Digest.hash(Data([contentSeed, 1])).bytes
        let fake16k = MD5Digest.hash(Data([contentSeed, 2])).bytes
        let nameBytes = Data(name.utf8)
        let fileID = MD5Digest.hash(parts: [fake16k, le64(length), nameBytes]).bytes
        var body = fileID
        body.append(fakeMD5)
        body.append(fake16k)
        body.append(le64(length))
        body.append(nameBytes)
        return (body, fileID)
    }

    /// A complete minimal index: Main + one FileDesc per file. setID = MD5(Main body).
    static func indexFile(
        sliceSize: UInt64,
        recoveryFiles: [(name: String, length: UInt64)],
        nonRecoveryFiles: [(name: String, length: UInt64)] = []
    ) -> (data: Data, setID: Data) {
        var seed: UInt8 = 0
        func descs(_ files: [(name: String, length: UInt64)]) -> [(body: Data, fileID: Data)] {
            files.map { file in
                seed += 1
                return fileDesc(name: file.name, length: file.length, contentSeed: seed)
            }
        }
        let recovery = descs(recoveryFiles)
        let nonRecovery = descs(nonRecoveryFiles)
        // Main-packet File IDs sort as little-endian 16-byte integers (03 §2.3).
        let sortLE = { (a: (body: Data, fileID: Data), b: (body: Data, fileID: Data)) in
            [UInt8](a.fileID.reversed()).lexicographicallyPrecedes([UInt8](b.fileID.reversed()))
        }
        let main = mainBody(
            sliceSize: sliceSize,
            recoveryIDs: recovery.sorted(by: sortLE).map(\.fileID),
            nonRecoveryIDs: nonRecovery.sorted(by: sortLE).map(\.fileID))
        let setID = MD5Digest.hash(main).bytes
        var data = packet(type: Par2Parser.PacketType.main, setID: setID, body: main)
        for d in recovery + nonRecovery {
            data.append(
                packet(type: Par2Parser.PacketType.fileDescription, setID: setID, body: d.body))
        }
        return (data, setID)
    }

    static func write(_ data: Data, name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("par2-synth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Builds PAR1 archives byte-exact per docs/research/03 §6 (header 0x60, self-sized entries).
enum Par1Builder {
    struct File {
        var name: String
        var size: UInt64
        var md5: Data
        var status: UInt64  // bit0 = in parity set
    }

    static func archive(files: [File], volumeNumber: UInt64 = 0, comment: String? = nil) -> Data {
        var fileList = Data()
        for f in files {
            let nameUTF16 = f.name.data(using: .utf16LittleEndian)!
            var entry = Par2Builder.le64(UInt64(0x38 + nameUTF16.count))
            entry.append(Par2Builder.le64(f.status))
            entry.append(Par2Builder.le64(f.size))
            entry.append(f.md5)
            entry.append(MD5Digest.hash(Data(f.name.utf8)).bytes)  // fake 16k hash
            entry.append(nameUTF16)
            fileList.append(entry)
        }
        let commentData = comment?.data(using: .utf16LittleEndian) ?? Data()

        let setHash = MD5Digest.hash(
            parts: files.filter { $0.status & 1 != 0 }.map(\.md5))
        // Everything the control hash covers: set hash → EOF.
        var tail = setHash.bytes
        tail.append(Par2Builder.le64(volumeNumber))
        tail.append(Par2Builder.le64(UInt64(files.count)))
        tail.append(Par2Builder.le64(0x60))  // file list offset
        tail.append(Par2Builder.le64(UInt64(fileList.count)))
        tail.append(Par2Builder.le64(UInt64(0x60 + fileList.count)))  // data offset
        tail.append(Par2Builder.le64(UInt64(commentData.count)))
        tail.append(fileList)
        tail.append(commentData)

        var data = Data([0x50, 0x41, 0x52, 0x00, 0x00, 0x00, 0x00, 0x00])
        data.append(Par2Builder.le32(0x0001_0000))  // version 1.0
        data.append(Par2Builder.le32(0x0000_0042))  // client id
        data.append(MD5Digest.hash(tail).bytes)  // control hash over 0x20..EOF
        data.append(tail)
        return data
    }
}

// MARK: - Hostile-input regressions (review findings: Int traps, overflow traps)

struct HostileInputTests {

    static let par1Fixture = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        .appendingPathComponent("par1/archive.par")

    private func mutated(_ data: Data, at offset: Int, with bytes: [UInt8]) -> Data {
        var d = data
        for (i, b) in bytes.enumerated() { d[d.startIndex + offset + i] = b }
        return d
    }

    @Test func par1HostileNumFilesThrowsInsteadOfTrapping() throws {
        let golden = try Data(contentsOf: Self.par1Fixture)
        // numFiles at 0x38 → UInt64.max. Must throw, not trap in Int()/reserveCapacity.
        let hostile = mutated(golden, at: 0x38, with: [UInt8](repeating: 0xFF, count: 8))
        #expect(throws: Par1Parser.ParseError.malformedFileList) {
            _ = try Par1Parser.parse(hostile)
        }
        // Huge-but-in-range numFiles must not attempt a giant allocation either.
        let big = mutated(golden, at: 0x38, with: [0, 0, 0, 0, 0, 1, 0, 0])  // 2^40
        #expect(throws: Par1Parser.ParseError.malformedFileList) {
            _ = try Par1Parser.parse(big)
        }
    }

    @Test func par1HostileDataOffsetDoesNotTrap() throws {
        let golden = try Data(contentsOf: Self.par1Fixture)
        var hostile = mutated(golden, at: 0x50, with: [UInt8](repeating: 0xFF, count: 8))
        hostile = mutated(hostile, at: 0x58, with: [1, 0, 0, 0, 0, 0, 0, 0])  // dataSize = 1
        let archive = try Par1Parser.parse(hostile)  // must not crash at Int(dataOffset)
        #expect(archive.comment == nil)
    }

    @Test func par1ErrorTaxonomy() {
        // Valid magic but truncated header → truncatedHeader, not notPar1.
        var truncated = Data([0x50, 0x41, 0x52, 0x00, 0x00, 0x00, 0x00, 0x00])
        truncated.append(Data(repeating: 0, count: 16))
        #expect(throws: Par1Parser.ParseError.truncatedHeader) {
            _ = try Par1Parser.parse(truncated)
        }
        // Wrong version → its own error.
        let archive = Par1Builder.archive(files: [])
        var wrongVersion = archive
        wrongVersion[wrongVersion.startIndex + 0x08] = 0x99
        #expect(throws: Par1Parser.ParseError.unsupportedVersion(0x0001_0099)) {
            _ = try Par1Parser.parse(wrongVersion)
        }
    }

    @Test func recoveryMathNeverTraps() {
        #expect(RecoveryMath.sourceBlocks(fileSize: .max, sliceSize: 4) > 0)
        #expect(RecoveryMath.sourceBlocks(fileSize: .max, sliceSize: 1) == Int.max)  // clamped
        #expect(RecoveryMath.sourceBlocks(fileSize: .max - 3, sliceSize: 4) == Int(UInt64.max / 4))
    }

    @Test func par2HostileFileLengthsDoNotTrap() throws {
        let dir = try Par2Builder.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let huge = UInt64.max - 2
        let (data, _) = Par2Builder.indexFile(
            sliceSize: 4,
            recoveryFiles: [("a.bin", huge), ("b.bin", huge)])
        let url = try Par2Builder.write(data, name: "huge.par2", in: dir)
        let set = try Par2Parser.assembleSet(from: [url])
        #expect(set.sourceBlockCount == Int.max)  // saturated, not trapped
        #expect(set.totalDataBytes == UInt64.max)  // saturated, not trapped
        let parSet = ParSet(par2: set)  // bridging must not trap either
        #expect(parSet.files.count == 2)
    }
}

// MARK: - Multi-set folders, Main selection, RecvSlic validation (review findings)

struct Par2AssemblyEdgeTests {

    static let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        .appendingPathComponent("par2cmdline")

    /// Copies the golden fixture set into a temp folder, optionally damaging the index's Main.
    private func stageGoldenSet(in dir: URL, damageIndexMain: Bool = false) throws -> URL {
        var index = try Data(contentsOf: Self.fixtures.appendingPathComponent("set.par2"))
        if damageIndexMain {
            // The fixture's first packet is Main (par2cmdline writes it first): flip a body byte.
            index[index.startIndex + 70] ^= 0xFF
        }
        let anchor = try Par2Builder.write(index, name: "set.par2", in: dir)
        for vol in ["set.vol0+1.par2", "set.vol1+2.par2", "set.vol3+4.par2"] {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(vol))
            _ = try Par2Builder.write(data, name: vol, in: dir)
        }
        return anchor
    }

    @Test func foreignSetInFolderCannotHijackAssembly() throws {
        let dir = try Par2Builder.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let anchor = try stageGoldenSet(in: dir)
        // Foreign set, alphabetically FIRST so it would win any naive ordering.
        let foreign = Par2Builder.indexFile(
            sliceSize: 8, recoveryFiles: [("foreign.bin", 64)])
        let foreignURL = try Par2Builder.write(foreign.data, name: "aaa.par2", in: dir)

        let set = try Par2Parser.loadSet(anchor: anchor)
        #expect(set.sliceSize == 1000)
        #expect(set.descriptions.count == 4)
        #expect(set.recoveryBlockCount == 7)
        #expect(!set.sourceFiles.contains { $0.lastPathComponent == foreignURL.lastPathComponent })
    }

    @Test func corruptAnchorMainStillResolvesOwnSetNotForeign() throws {
        let dir = try Par2Builder.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let anchor = try stageGoldenSet(in: dir, damageIndexMain: true)
        let foreign = Par2Builder.indexFile(sliceSize: 8, recoveryFiles: [("foreign.bin", 64)])
        _ = try Par2Builder.write(foreign.data, name: "aaa.par2", in: dir)

        // The anchor's FileDesc/IFSC packets still carry set A's ID; Main copies live in the
        // volume files. Assembly must recover set A, not adopt the foreign set.
        let set = try Par2Parser.loadSet(anchor: anchor)
        #expect(set.sliceSize == 1000)
        #expect(set.descriptions.count == 4)
    }

    @Test func undecodableFirstMainFallsBackToAValidOne() throws {
        let dir = try Par2Builder.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = Par2Builder.indexFile(sliceSize: 1000, recoveryFiles: [("x.bin", 1500)])
        // MD5-valid but semantically broken Main: slice size not a multiple of 4.
        let brokenBody = Par2Builder.mainBody(sliceSize: 6, recoveryIDs: [])
        var file = Par2Builder.packet(
            type: Par2Parser.PacketType.main,
            setID: MD5Digest.hash(brokenBody).bytes,
            body: brokenBody)
        file.append(good.data)
        let url = try Par2Builder.write(file, name: "mixed.par2", in: dir)
        let set = try Par2Parser.assembleSet(from: [url])
        #expect(set.sliceSize == 1000)
        #expect(set.descriptions.count == 1)
    }

    @Test func nonRecoveryFilesDecodeAndBridgeAsNotInSet() throws {
        let dir = try Par2Builder.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let synth = Par2Builder.indexFile(
            sliceSize: 100,
            recoveryFiles: [("protected.bin", 250)],
            nonRecoveryFiles: [("extra.txt", 40)])
        let url = try Par2Builder.write(synth.data, name: "mixed.par2", in: dir)
        let set = try Par2Parser.assembleSet(from: [url])
        #expect(set.recoveryFileIDs.count == 1)
        #expect(set.nonRecoveryFileIDs.count == 1)
        #expect(set.sourceBlockCount == 3)  // only the protected file counts
        let parSet = ParSet(par2: set)
        #expect(parSet.files.count == 2)
        #expect(parSet.files.first { $0.name == "protected.bin" }?.status == .pending)
        #expect(parSet.files.first { $0.name == "extra.txt" }?.status == .notInSet)
    }

    @Test func missingFileDescriptionYieldsPlaceholderNotSilence() throws {
        let dir = try Par2Builder.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Main references two files; only one FileDesc is present.
        let known = Par2Builder.fileDesc(name: "known.bin", length: 500, contentSeed: 9)
        let ghostID = MD5Digest.hash(Data("ghost".utf8)).bytes
        let main = Par2Builder.mainBody(sliceSize: 100, recoveryIDs: [known.fileID, ghostID])
        let setID = MD5Digest.hash(main).bytes
        var data = Par2Builder.packet(type: Par2Parser.PacketType.main, setID: setID, body: main)
        data.append(
            Par2Builder.packet(
                type: Par2Parser.PacketType.fileDescription, setID: setID, body: known.body))
        let url = try Par2Builder.write(data, name: "partial.par2", in: dir)

        let set = try Par2Parser.assembleSet(from: [url])
        #expect(set.missingDescriptionIDs.count == 1)
        let parSet = ParSet(par2: set)
        #expect(parSet.files.count == 2)
        #expect(parSet.files.contains { $0.status == .possibleError })
    }

    @Test func malformedRecoverySlicesAreNotCountedAsBlocks() throws {
        let dir = try Par2Builder.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let synth = Par2Builder.indexFile(sliceSize: 100, recoveryFiles: [("x.bin", 250)])
        var data = synth.data
        // Valid recovery slice: exponent 0 + exactly sliceSize bytes of data.
        var goodBody = Par2Builder.le32(0)
        goodBody.append(Data(repeating: 0xCD, count: 100))
        data.append(
            Par2Builder.packet(
                type: Par2Parser.PacketType.recoverySlice, setID: synth.setID, body: goodBody))
        // Wrong data size (counts as damage, not a block).
        var shortBody = Par2Builder.le32(1)
        shortBody.append(Data(repeating: 0xCD, count: 96))
        data.append(
            Par2Builder.packet(
                type: Par2Parser.PacketType.recoverySlice, setID: synth.setID, body: shortBody))
        // Exponent outside GF(2^16).
        var hugeExponent = Par2Builder.le32(70000)
        hugeExponent.append(Data(repeating: 0xCD, count: 100))
        data.append(
            Par2Builder.packet(
                type: Par2Parser.PacketType.recoverySlice, setID: synth.setID, body: hugeExponent))
        let url = try Par2Builder.write(data, name: "recv.par2", in: dir)

        let set = try Par2Parser.assembleSet(from: [url])
        #expect(set.recoveryExponents == [0])
        #expect(set.recoveryBlockCount == 1)
    }

    @Test func par2CommentPacketIsSurfaced() throws {
        let dir = try Par2Builder.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let synth = Par2Builder.indexFile(sliceSize: 100, recoveryFiles: [("x.bin", 100)])
        var data = synth.data
        data.append(
            Par2Builder.packet(
                type: Par2Parser.PacketType.asciiComment,
                setID: synth.setID,
                body: Data("posted by tests".utf8)))
        let url = try Par2Builder.write(data, name: "comment.par2", in: dir)
        let set = try Par2Parser.assembleSet(from: [url])
        #expect(set.comment == "posted by tests")
    }
}

// MARK: - Synthesized PAR1 coverage (out-of-set files, comments, duplicate content)

struct Par1SynthesizedTests {

    @Test func fileOutsideParitySetIsDecodedAndBridged() throws {
        let archive = Par1Builder.archive(files: [
            .init(name: "in.dat", size: 100, md5: MD5Digest.hash(Data([1])).bytes, status: 0b11),
            .init(name: "out.dat", size: 50, md5: MD5Digest.hash(Data([2])).bytes, status: 0b0),
        ])
        let parsed = try Par1Parser.parse(archive)
        #expect(parsed.controlHashVerified)
        #expect(parsed.setHashVerified)  // set hash covers ONLY the in-set file
        #expect(parsed.filesInParitySet.map(\.name) == ["in.dat"])
        let parSet = ParSet(par1: parsed)
        #expect(parSet.files.first { $0.name == "out.dat" }?.status == .notInSet)
        #expect(parSet.files.first { $0.name == "in.dat" }?.status == .pending)
    }

    @Test func commentRoundTrips() throws {
        let archive = Par1Builder.archive(
            files: [
                .init(name: "a.dat", size: 10, md5: MD5Digest.hash(Data([3])).bytes, status: 1)
            ],
            comment: "Hello PAR1")
        let parsed = try Par1Parser.parse(archive)
        #expect(parsed.comment == "Hello PAR1")
        // Parity volumes carry parity bytes in the data area, never a comment.
        let volume = Par1Builder.archive(
            files: [
                .init(name: "a.dat", size: 10, md5: MD5Digest.hash(Data([3])).bytes, status: 1)
            ],
            volumeNumber: 1, comment: "not a comment")
        #expect(try Par1Parser.parse(volume).comment == nil)
    }

    @Test func duplicateContentFilesGetUniqueRowIDs() throws {
        let md5 = MD5Digest.hash(Data([7])).bytes
        let archive = Par1Builder.archive(files: [
            .init(name: "copy1.dat", size: 10, md5: md5, status: 1),
            .init(name: "copy1.dat", size: 10, md5: md5, status: 1),  // same name AND content
        ])
        let parSet = ParSet(par1: try Par1Parser.parse(archive))
        #expect(Set(parSet.files.map(\.id)).count == 2)
    }

    @Test func hostileNameWithPathComponentsIsStripped() throws {
        let archive = Par1Builder.archive(files: [
            .init(
                name: "../../escape.dat", size: 10, md5: MD5Digest.hash(Data([8])).bytes,
                status: 1)
        ])
        let parsed = try Par1Parser.parse(archive)
        #expect(parsed.files[0].name == "escape.dat")
    }
}
