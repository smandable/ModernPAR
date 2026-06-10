import Foundation
import Testing

@testable import ModernPARCore

/// Golden-fixture tests for the read-only PAR1 reader.
///
/// `Fixtures/par1/` holds a set created by MacPAR deLuxe's own Intel `par` helper (the original
/// 2002 tool, run under Rosetta 2) — `par a -n2 archive.par alpha.dat beta.dat`. This is the
/// ground truth ModernPAR must keep reading after Rosetta is gone.
struct Par1ParserTests {

    static let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        .appendingPathComponent("par1")

    @Test func readsTheIndexFile() throws {
        let archive = try Par1Parser.parse(
            fileURL: Self.fixtures.appendingPathComponent("archive.par"))
        #expect(archive.volumeNumber == 0)
        #expect(archive.controlHashVerified)
        #expect(archive.setHashVerified)
        #expect(archive.files.count == 2)

        let byName = Dictionary(uniqueKeysWithValues: archive.files.map { ($0.name, $0) })
        let alpha = try #require(byName["alpha.dat"])
        let beta = try #require(byName["beta.dat"])
        #expect(alpha.fileSize == 4000)
        #expect(beta.fileSize == 1500)
        #expect(alpha.isInParitySet && beta.isInParitySet)

        // Hashes must match the actual data files.
        for entry in [alpha, beta] {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(entry.name))
            #expect(MD5Digest.hash(data) == entry.fileMD5)
            #expect(MD5Digest.hash(data.prefix(16384)) == entry.md5of16k)
        }
    }

    @Test func readsParityVolumes() throws {
        let p01 = try Par1Parser.parse(
            fileURL: Self.fixtures.appendingPathComponent("archive.p01"))
        let p02 = try Par1Parser.parse(
            fileURL: Self.fixtures.appendingPathComponent("archive.p02"))
        #expect(p01.volumeNumber == 1)
        #expect(p02.volumeNumber == 2)
        #expect(p01.controlHashVerified && p02.controlHashVerified)
        // Volumes carry the same file list and set hash as the index.
        let index = try Par1Parser.parse(
            fileURL: Self.fixtures.appendingPathComponent("archive.par"))
        #expect(p01.setHash == index.setHash)
        #expect(p01.files.map(\.name) == index.files.map(\.name))
    }

    @Test func rejectsNonPar1Input() throws {
        #expect(throws: Par1Parser.ParseError.notPar1) {
            _ = try Par1Parser.parse(Data("PAR2\0PKTsomething".utf8))
        }
        #expect(throws: Par1Parser.ParseError.notPar1) {
            _ = try Par1Parser.parse(Data())
        }
    }

    @Test func detectsControlHashDamage() throws {
        var data = try Data(
            contentsOf: Self.fixtures.appendingPathComponent("archive.par"))
        data[data.startIndex + data.count - 1] ^= 0xFF  // damage the comment/list tail
        let archive = try Par1Parser.parse(data)
        #expect(archive.controlHashVerified == false)
    }

    @Test func bridgesToParSetForTheUI() throws {
        let archive = try Par1Parser.parse(
            fileURL: Self.fixtures.appendingPathComponent("archive.par"))
        let parSet = ParSet(par1: archive)
        #expect(parSet.kind == .par1)
        #expect(parSet.files.count == 2)
        #expect(parSet.files.allSatisfy { $0.status == .pending })
    }
}
