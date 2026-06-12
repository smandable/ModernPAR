import Foundation
import Testing

@testable import ModernPARCore

/// Native PAR1 authoring. The decisive checks: parity data areas BYTE-IDENTICAL to what the
/// original Intel `par` binary produced for the same inputs, round-trip repairability through
/// our own engine, and (locally, when the binary exists) the Intel binary accepting our sets.
/// (ROADMAP Phase 8 exit criterion: cross-checks against a reference implementation)
@MainActor
struct Par1CreateTests {

    static let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        .appendingPathComponent("par1")
    static let intelPar = URL(
        fileURLWithPath: "/Applications/MacPAR deLuxe.app/Contents/Helpers/par")

    /// Copies only the DATA files of a fixture set into a scratch folder.
    private func stageData(from subdir: String, names: [String]) throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("par1-create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.copyItem(
                at: Self.fixtures.appendingPathComponent(subdir).appendingPathComponent(name),
                to: scratch.appendingPathComponent(name))
        }
        return scratch
    }

    private func runCreate(
        parFile: URL, files: [URL], volumes: Int
    ) async throws -> [EngineEvent] {
        let request = CreateRequest(
            parFile: parFile, files: files, options: CreateOptions(),
            folderBookmark: try? ScopedAccess.bookmark(
                for: parFile.deletingLastPathComponent()),
            par1VolumeCount: volumes)
        var events: [EngineEvent] = []
        for await event in Par1CreateEngine().create(request) { events.append(event) }
        return events
    }

    private func finalStatus(_ events: [EngineEvent]) -> DocStatus? {
        var status: DocStatus?
        for event in events {
            if case .docStatusChanged(let s) = event { status = s }
        }
        return status
    }

    // MARK: - The oracle cross-check (byte-for-byte)

    @Test func createdParityIsByteIdenticalToTheIntelBinary() async throws {
        let names = ["one.dat", "two.dat", "three.dat", "four.dat", "five.dat"]
        let folder = try stageData(from: "five-files", names: names)
        defer { try? FileManager.default.removeItem(at: folder) }
        let parFile = folder.appendingPathComponent("fivefiles.par")

        let events = try await runCreate(
            parFile: parFile, files: names.map(folder.appendingPathComponent), volumes: 3)
        #expect(finalStatus(events) == .createdSuccessfully)

        for volume in 1...3 {
            let name = String(format: "fivefiles.p%02d", volume)
            let ours = try Data(contentsOf: folder.appendingPathComponent(name))
            let golden = try Data(
                contentsOf: Self.fixtures.appendingPathComponent("five-files/\(name)"))
            #expect(
                Par1Parser.dataArea(ours) == Par1Parser.dataArea(golden),
                "\(name): parity must byte-match the Intel binary's")
        }

        // The index round-trips through our parser with verified hashes and the same roster
        // facts the golden index records (sorted order, sizes, MD5s → identical set hash).
        let ourIndex = try Par1Parser.parse(Data(contentsOf: parFile))
        let goldenIndex = try Par1Parser.parse(
            Data(contentsOf: Self.fixtures.appendingPathComponent("five-files/fivefiles.par")))
        #expect(ourIndex.controlHashVerified)
        #expect(ourIndex.setHashVerified)
        #expect(ourIndex.files.map(\.name) == goldenIndex.files.map(\.name))
        #expect(ourIndex.files.map(\.fileMD5) == goldenIndex.files.map(\.fileMD5))
        #expect(ourIndex.files.map(\.md5of16k) == goldenIndex.files.map(\.md5of16k))
        #expect(ourIndex.setHash == goldenIndex.setHash)
    }

    @Test func intelBinaryAcceptsOurSets() async throws {
        // Local-only: CI runners have no MacPAR deLuxe install (and no Rosetta guarantee).
        guard FileManager.default.fileExists(atPath: Self.intelPar.path) else { return }
        let names = ["one.dat", "two.dat", "three.dat"]
        let folder = try stageData(from: "five-files", names: names)
        defer { try? FileManager.default.removeItem(at: folder) }
        let parFile = folder.appendingPathComponent("ours.par")
        let events = try await runCreate(
            parFile: parFile, files: names.map(folder.appendingPathComponent), volumes: 2)
        #expect(finalStatus(events) == .createdSuccessfully)

        let process = Process()
        process.executableURL = Self.intelPar
        process.arguments = ["c", parFile.path]
        process.currentDirectoryURL = folder
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(
            process.terminationStatus == 0,
            "the original Intel par binary must verify our set clean")
    }

    // MARK: - Round trip through our own engine

    @Test func createdSetVerifiesAndRepairsNatively() async throws {
        let names = ["one.dat", "two.dat", "three.dat", "four.dat"]
        let folder = try stageData(from: "five-files", names: names)
        defer { try? FileManager.default.removeItem(at: folder) }
        let parFile = folder.appendingPathComponent("roundtrip.par")
        _ = try await runCreate(
            parFile: parFile, files: names.map(folder.appendingPathComponent), volumes: 2)

        var route = SessionRoute(mode: .verifyRepair, autoRepair: true)
        route.folderBookmark = try? ScopedAccess.bookmark(for: folder)
        route.anchorBookmark = try ScopedAccess.bookmark(for: parFile)
        var events: [EngineEvent] = []
        for await event in Par1Engine().run(route) { events.append(event) }
        #expect(finalStatus(events) == .allFilesOK)

        // Now lose two files and repair them from our own volumes.
        var originals: [String: Data] = [:]
        for name in ["two.dat", "four.dat"] {
            let url = folder.appendingPathComponent(name)
            originals[name] = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
        }
        events.removeAll()
        var repairRoute = SessionRoute(mode: .verifyRepair, autoRepair: true)
        repairRoute.folderBookmark = try? ScopedAccess.bookmark(for: folder)
        repairRoute.anchorBookmark = try ScopedAccess.bookmark(for: parFile)
        for await event in Par1Engine().run(repairRoute) { events.append(event) }
        #expect(finalStatus(events) == .restoredSuccessfully)
        for (name, data) in originals {
            #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == data)
        }
    }

    @Test func unicodeNamesRoundTripThroughCreate() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("par1-create-uni-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["Привет мир.dat", "café-ümlaut.dat"]
        for name in names {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        let parFile = folder.appendingPathComponent("uni.par")
        let events = try await runCreate(
            parFile: parFile, files: names.map(folder.appendingPathComponent), volumes: 1)
        #expect(finalStatus(events) == .createdSuccessfully)
        let parsed = try Par1Parser.parse(Data(contentsOf: parFile))
        #expect(Set(parsed.files.map(\.name)) == Set(names))
        #expect(parsed.controlHashVerified)
    }

    @Test func indexOnlySetIsValid() async throws {
        let names = ["one.dat", "two.dat"]
        let folder = try stageData(from: "five-files", names: names)
        defer { try? FileManager.default.removeItem(at: folder) }
        let parFile = folder.appendingPathComponent("indexonly.par")
        let events = try await runCreate(
            parFile: parFile, files: names.map(folder.appendingPathComponent), volumes: 0)
        #expect(finalStatus(events) == .createdSuccessfully)
        #expect(
            !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("indexonly.p01").path))

        var route = SessionRoute(mode: .verifyRepair, autoRepair: true)
        route.folderBookmark = try? ScopedAccess.bookmark(for: folder)
        route.anchorBookmark = try ScopedAccess.bookmark(for: parFile)
        var verifyEvents: [EngineEvent] = []
        for await event in Par1Engine().run(route) { verifyEvents.append(event) }
        #expect(finalStatus(verifyEvents) == .allFilesOK)
    }

    @Test func refusesToOverwriteExistingOutput() async throws {
        let names = ["one.dat"]
        let folder = try stageData(from: "five-files", names: names)
        defer { try? FileManager.default.removeItem(at: folder) }
        let parFile = folder.appendingPathComponent("exists.par")
        try Data("not par".utf8).write(to: parFile)

        let events = try await runCreate(
            parFile: parFile, files: names.map(folder.appendingPathComponent), volumes: 1)
        #expect(finalStatus(events) == .createFailed)
        // The pre-existing file is untouched and no volume was deposited.
        #expect(try Data(contentsOf: parFile) == Data("not par".utf8))
        #expect(
            !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("exists.p01").path))
    }

    @Test func failedCreateRemovesOnlyItsOwnOutput() async throws {
        // The hash phase fails (missing source) before anything is written: the cleanup
        // must remove nothing — especially not files that happen to sit at target paths.
        // (Phase 8 review: cleanup deleted every target path unconditionally)
        let names = ["one.dat"]
        let folder = try stageData(from: "five-files", names: names)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bystander = folder.appendingPathComponent("unrelated.txt")
        try Data("bystander".utf8).write(to: bystander)

        let parFile = folder.appendingPathComponent("doomed.par")
        let events = try await runCreate(
            parFile: parFile,
            files: [
                folder.appendingPathComponent("one.dat"),
                folder.appendingPathComponent("never-existed.dat"),
            ],
            volumes: 2)
        #expect(finalStatus(events) == .createFailed)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(Set(remaining) == Set(["one.dat", "unrelated.txt"]), "no debris, no casualties")
    }

    @Test func upfrontRefusalLeavesAForeignVolumeFileUntouched() async throws {
        // A file already sitting at a VOLUME target path refuses the run before anything
        // is hashed or written — and survives intact.
        let names = ["one.dat"]
        let folder = try stageData(from: "five-files", names: names)
        defer { try? FileManager.default.removeItem(at: folder) }
        let foreign = folder.appendingPathComponent("mine.p01")
        try Data("not yours".utf8).write(to: foreign)

        let events = try await runCreate(
            parFile: folder.appendingPathComponent("mine.par"),
            files: names.map(folder.appendingPathComponent), volumes: 1)
        #expect(finalStatus(events) == .createFailed)
        #expect(try Data(contentsOf: foreign) == Data("not yours".utf8))
        #expect(
            !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("mine.par").path),
            "no partial index may be deposited")
    }

    // MARK: - Model validation (doc-01 §5.2 wording)

    @Test func modelValidatesPar1Limits() {
        let model = CreateModel(kind: .par1)
        #expect(model.validationErrors.contains { $0.contains("at least one file") })

        model.par1VolumeMode = .fixed
        model.par1FixedVolumeCount = 100
        #expect(
            model.validationErrors.contains {
                $0.contains("between 0 and 99")
            })

        model.par1VolumeMode = .byFileCount
        model.par1FilesPerVolume = 0
        #expect(
            model.validationErrors.contains {
                $0.contains("between 1 and 99")
            })
    }

    @Test func volumeCountDerivesFromFileCount() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("par1-volcount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = CreateModel(kind: .par1)
        for i in 0..<7 {
            let url = folder.appendingPathComponent("f\(i).dat")
            try Data([UInt8(i)]).write(to: url)
            model.add([url])
        }
        model.par1VolumeMode = .byFileCount
        model.par1FilesPerVolume = 3
        #expect(model.par1VolumeCount == 3)  // ceil(7 / 3)
        model.par1VolumeMode = .fixed
        model.par1FixedVolumeCount = 5
        #expect(model.par1VolumeCount == 5)
    }
}
