import Foundation
import ModernPARCore
import Testing

@testable import Par2Kit

/// The ROADMAP Phase 2 swappability criterion: the helper-process fallback passes the same
/// protocol-level scenarios as the embedded engine — same events, same statuses, same results.
/// Serialized: the no-zombie assertion below identifies OUR child; concurrent siblings'
/// helpers would race a global process check.
@Suite(.serialized)
struct HelperProcessEngineTests {

    private final class BundleToken {}

    /// The vendored CLI built by SPM alongside the test bundle (Par2HelperCLI test dependency).
    static let helperURL = Bundle(for: BundleToken.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("Par2HelperCLI")

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ModernPARCoreTests/Fixtures/par2cmdline")

    private func makeEngine(repairs: Bool = true) -> HelperProcessEngine {
        HelperProcessEngine(helperURL: Self.helperURL, repairsAutomatically: repairs)
    }

    private func stageFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(
            at: Self.fixtureDir, includingPropertiesForKeys: nil)
        {
            try FileManager.default.copyItem(
                at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
        return dir
    }

    private func route(anchor: URL, folder: URL) throws -> SessionRoute {
        SessionRoute(
            mode: .verifyRepair,
            folderBookmark: try? ScopedAccess.bookmark(for: folder),
            anchorBookmark: try ScopedAccess.bookmark(for: anchor)
        )
    }

    private func collect(_ stream: AsyncStream<EngineEvent>) async -> [EngineEvent] {
        var events: [EngineEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    @Test func helperBinaryExists() {
        #expect(
            FileManager.default.isExecutableFile(atPath: Self.helperURL.path),
            "expected the vendored CLI at \(Self.helperURL.path)")
    }

    @Test func verifyingAnIntactSetMatchesTheEmbeddedContract() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = await collect(
            makeEngine().run(
                try route(anchor: dir.appendingPathComponent("set.par2"), folder: dir)))

        let roster = events.compactMap { event -> [FileEntry]? in
            if case .filesDiscovered(let files) = event { return files }
            return nil
        }.first
        #expect(roster?.count == 4)
        var statuses: [UUID: FileStatus] = [:]
        for case .fileStatusChanged(let id, let status) in events { statuses[id] = status }
        #expect(statuses.count == 4)
        #expect(statuses.values.allSatisfy { $0 == .ok })
        #expect(
            events.contains {
                if case .docStatusChanged(.allFilesOK) = $0 { return true } else { return false }
            })
        guard case .finished(.success(let summary))? = events.last else {
            Issue.record("missing finished event: \(String(describing: events.last))")
            return
        }
        #expect(summary.repaired == 0)
        #expect(summary.stillMissing == 0)
    }

    @Test func damagedSetRepairsThroughTheSubprocess() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = dir.appendingPathComponent("file-a.bin")
        let original = try Data(contentsOf: victim)
        var damaged = original
        for i in 0..<1200 { damaged[i] ^= 0xA5 }
        try damaged.write(to: victim)

        let events = await collect(
            makeEngine().run(
                try route(anchor: dir.appendingPathComponent("set.par2"), folder: dir)))
        #expect(
            events.contains {
                if case .docStatusChanged(.restoredSuccessfully) = $0 {
                    return true
                } else {
                    return false
                }
            })
        guard case .finished(.success(let summary))? = events.last else {
            Issue.record("missing finished event")
            return
        }
        #expect(summary.repaired == 1)
        #expect(try Data(contentsOf: victim) == original)
    }

    @Test func verifyOnlyEndsAwaitingConsent() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = dir.appendingPathComponent("file-b.bin")
        var damaged = try Data(contentsOf: victim)
        damaged[0] ^= 0xFF
        try damaged.write(to: victim)
        let mutated = damaged

        let events = await collect(
            makeEngine(repairs: false).run(
                try route(anchor: dir.appendingPathComponent("set.par2"), folder: dir)))
        let lastDocStatus = events.compactMap { event -> DocStatus? in
            if case .docStatusChanged(let status) = event { return status }
            return nil
        }.last
        #expect(lastDocStatus == .repairNeeded)
        #expect(try Data(contentsOf: victim) == mutated)
        guard case .finished(.success(let summary))? = events.last else {
            Issue.record("missing finished event")
            return
        }
        #expect(summary.stillMissing == 1)
    }

    @Test func insufficientRecoveryReportsNeededBlocks() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        for file in try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        where file.lastPathComponent.contains(".vol") {
            try FileManager.default.removeItem(at: file)
        }
        let victim = dir.appendingPathComponent("file-a.bin")
        var damaged = try Data(contentsOf: victim)
        for i in 0..<1200 { damaged[i] ^= 0xA5 }
        try damaged.write(to: victim)

        let events = await collect(
            makeEngine().run(
                try route(anchor: dir.appendingPathComponent("set.par2"), folder: dir)))
        let needed = events.compactMap { event -> Int? in
            if case .docStatusChanged(.needMoreRecovery(let blocks)) = event { return blocks }
            return nil
        }
        #expect((needed.first ?? 0) > 0)
    }

    @Test func abandoningTheStreamTerminatesTheChildProcess() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        func helperPID() -> pid_t? {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-f", Self.helperURL.path]
            let pipe = Pipe()
            pgrep.standardOutput = pipe
            try? pgrep.run()
            pgrep.waitUntilExit()
            let output = String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return output.split(separator: "\n").compactMap { pid_t($0) }.first
        }

        let stream = makeEngine().run(
            try route(anchor: dir.appendingPathComponent("set.par2"), folder: dir))
        var observedPID: pid_t?
        for await _ in stream {
            // The suite is serialized, so the only live helper is OUR child.
            if observedPID == nil { observedPID = helperPID() }
            if observedPID != nil { break }  // abandon → onTermination → SIGTERM
        }
        guard let pid = observedPID else {
            // Tiny fixture: the helper can finish before pgrep sees it — nothing to leak then.
            return
        }
        // Poll for the SPECIFIC child to vanish (kill(pid, 0) fails once it is fully reaped).
        var gone = false
        for _ in 0..<40 {
            if kill(pid, 0) != 0 {
                gone = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(gone, "helper pid \(pid) is still alive after stream abandonment")
    }

    @Test func misnamedFileIsFoundAndRenamedThroughTheSubprocess() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let proper = dir.appendingPathComponent("file-b.bin")
        let wrongName = dir.appendingPathComponent("totally-wrong-name.dat")
        try FileManager.default.moveItem(at: proper, to: wrongName)

        let events = await collect(
            makeEngine().run(
                try route(anchor: dir.appendingPathComponent("set.par2"), folder: dir)))
        let lastDocStatus = events.compactMap { event -> DocStatus? in
            if case .docStatusChanged(let status) = event { return status }
            return nil
        }.last
        #expect(lastDocStatus == .restoredWithRenames)
        #expect(FileManager.default.fileExists(atPath: proper.path))
    }

    @Test func argumentBuilderMapsTheCLIContract() {
        #expect(
            ArgumentBuilder.verifyRepair(par2Path: "/x/set.par2", repair: false)
                == ["v", "--", "/x/set.par2"])
        #expect(
            ArgumentBuilder.verifyRepair(
                par2Path: "/x/set.par2", repair: true, extraFiles: ["/x/a.bin"], threads: 4)
                == ["r", "-t4", "--", "/x/set.par2", "/x/a.bin"])
    }
}
