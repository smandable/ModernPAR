import Foundation
import Par2Kit
import Testing

@testable import ModernPARCore

/// A Main packet that lists one File ID twice — or lists it as both recoverable and
/// non-recovery — is refused before the engine opens the set.
///
/// The vendored engine looks each Main entry up in a File ID map, so a repeat puts ONE
/// `Par2RepairerSourceFile` at two indices. It then double-counts that file's blocks, opens
/// its path on two file threads (`diskFileMap`'s guard is a non-atomic find-then-insert whose
/// `assert` is compiled out under NDEBUG), and during a repair walks past the end of its block
/// vectors. Because ModernPAR runs the engine IN-PROCESS, that is an app-killing SIGSEGV —
/// after the repair has already rewritten the user's files. An intact set can also come back
/// reported as damaged. The native parser tolerates the repeat (`ParSet` keeps the first row),
/// so the roster is the last place that can stop it.
struct MalformedSetGuardTests {

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/par2-duplicate-fileid")

    private func stage(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dupid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let anchor = dir.appendingPathComponent("set.par2")
        try FileManager.default.copyItem(
            at: Self.fixtureDir.appendingPathComponent(name), to: anchor)
        return anchor
    }

    private func route(anchor: URL) throws -> SessionRoute {
        SessionRoute(
            mode: .verifyRepair,
            folderBookmark: try? ScopedAccess.bookmark(for: anchor.deletingLastPathComponent()),
            anchorBookmark: try ScopedAccess.bookmark(for: anchor))
    }

    private func collect(_ stream: AsyncStream<EngineEvent>) async -> [EngineEvent] {
        var events: [EngineEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test(arguments: ["repeated-in-recovery.par2", "listed-in-both.par2"])
    func aRepeatedFileIDIsRefusedBeforeTheEngineRuns(fixture: String) async throws {
        let anchor = try stage(fixture)
        defer { try? FileManager.default.removeItem(at: anchor.deletingLastPathComponent()) }

        let engine = EmbeddedEngine(repairsAutomatically: false)
        let events = await collect(engine.run(try route(anchor: anchor)))

        // The run fails as "could not start", which the session shows as "not valid".
        guard case .finished(.failure(let error))? = events.last else {
            Issue.record("expected a terminal failure, got \(String(describing: events.last))")
            return
        }
        guard case .launchFailed(let reason) = error else {
            Issue.record("expected launchFailed, got \(error)")
            return
        }
        #expect(reason.contains("same file ID"))

        // The engine never started: no "checking", no verdict, no per-file status.
        let docStatuses = events.compactMap {
            if case .docStatusChanged(let status) = $0 { return status } else { return nil }
        }
        #expect(!docStatuses.contains(.checking))
        #expect(
            !events.contains {
                if case .fileStatusChanged = $0 { return true } else { return false }
            })
        // The rows are still painted, so the window shows what the set claims to hold.
        #expect(
            events.contains { if case .filesDiscovered = $0 { return true } else { return false } })
    }

    @Test func anOrdinarySetIsNotRefused() async throws {
        // The guard must not fire on the crafted-but-legal non-recovery fixture next door.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/par2-nonrecovery")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dupid-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for file in try FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil)
        {
            try FileManager.default.copyItem(
                at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
        let anchor = dir.appendingPathComponent("set.par2")

        let engine = EmbeddedEngine(repairsAutomatically: false)
        let events = await collect(engine.run(try route(anchor: anchor)))

        if case .finished(.failure(let error))? = events.last {
            Issue.record("a legal set was refused: \(error)")
        }
    }
}
