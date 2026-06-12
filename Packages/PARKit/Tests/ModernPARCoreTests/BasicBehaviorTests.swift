import Foundation
import Testing

@testable import ModernPARCore

/// The Basic-tab behaviors (doc-01 §5.1): `AutoDeletePnn` moves the set's par files to the
/// Trash after a successful restore. (ROADMAP Phase 7)
@MainActor
struct BasicBehaviorTests {

    static let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    private func waitUntilIdle(_ session: OperationSession) async throws {
        for _ in 0..<200 where session.isBusy {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!session.isBusy, "session never finished parsing")
    }

    /// Copies the golden par2cmdline fixture set into a scratch folder (trashing must never
    /// touch the real fixtures).
    private func stageFixtureSet() throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("autodelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(
            at: Self.fixtures.appendingPathComponent("par2cmdline"), to: scratch)
        return scratch
    }

    @Test func parsedSetRecordsItsContributingParFiles() async throws {
        let session = OperationSession()
        session.open(Self.fixtures.appendingPathComponent("par2cmdline/set.par2"))
        try await waitUntilIdle(session)
        let parFiles = try #require(session.parSet?.parFiles)
        #expect(!parFiles.isEmpty)
        #expect(parFiles.allSatisfy { $0.pathExtension.lowercased() == "par2" })
        #expect(parFiles.contains { $0.lastPathComponent == "set.par2" })
    }

    @Test func trashParFilesMovesEveryContributingParFileAndLogsIt() async throws {
        let folder = try stageFixtureSet()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = OperationSession()
        session.open(folder.appendingPathComponent("set.par2"))
        try await waitUntilIdle(session)
        let parFiles = try #require(session.parSet?.parFiles)
        #expect(!parFiles.isEmpty)

        session.trashParFiles()

        for url in parFiles {
            #expect(
                !FileManager.default.fileExists(atPath: url.path),
                "\(url.lastPathComponent) should be in the Trash")
        }
        // The data files stay untouched — only par files are swept.
        let remaining = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)
        #expect(!remaining.isEmpty)
        #expect(remaining.allSatisfy { $0.pathExtension.lowercased() != "par2" })
        #expect(session.log.contains { $0.contains("to the Trash") })
    }

    @Test func trashParFilesWithoutADocumentIsANoOp() {
        let session = OperationSession()
        session.trashParFiles()
        #expect(session.log.isEmpty)
    }

    @Test func trashParFilesIsIdempotent() async throws {
        let folder = try stageFixtureSet()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = OperationSession()
        session.open(folder.appendingPathComponent("set.par2"))
        try await waitUntilIdle(session)

        session.trashParFiles()
        let linesAfterFirst = session.log.count
        // The pars are already gone — the second sweep must not log or fail.
        session.trashParFiles()
        #expect(session.log.count == linesAfterFirst)
    }

    // MARK: - The AutoDeletePnn trigger fires only after an actual restore (Phase 7 review)

    final class ScriptedEngine: PAR2Engine, @unchecked Sendable {
        let events: [EngineEvent]
        init(events: [EngineEvent]) { self.events = events }
        func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
            AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private func openAndRun(_ folder: URL, endState: DocStatus) async throws -> OperationSession {
        let session = OperationSession()
        session.open(
            folder.appendingPathComponent("set.par2"),
            thenVerifyUsing: ScriptedEngine(events: [
                .docStatusChanged(endState),
                .finished(.success(OperationSummary())),
            ]),
            autoRepair: true)
        try await waitUntilIdle(session)
        for _ in 0..<200 where session.docStatus != endState {
            try await Task.sleep(for: .milliseconds(25))
        }
        return session
    }

    @Test func plainAllOKVerifyNeverTrashesTheParFiles() async throws {
        // The preference's own label: "after a successful RESTORE" — checking a healthy set
        // the user means to keep must leave its pars alone. (doc-01 §5.1)
        let folder = try stageFixtureSet()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try await openAndRun(folder, endState: .allFilesOK)

        session.trashParFilesAfterSuccessfulRestore()
        #expect(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("set.par2").path))
        #expect(!session.log.contains { $0.contains("to the Trash") })
    }

    @Test func successfulRestoreTrashesTheParFiles() async throws {
        let folder = try stageFixtureSet()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try await openAndRun(folder, endState: .restoredSuccessfully)

        session.trashParFilesAfterSuccessfulRestore()
        #expect(
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("set.par2").path))
        #expect(session.log.contains { $0.contains("to the Trash") })
    }

    @Test func restoreWithRenamesAlsoTrashesTheParFiles() async throws {
        let folder = try stageFixtureSet()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try await openAndRun(folder, endState: .restoredWithRenames)

        session.trashParFilesAfterSuccessfulRestore()
        #expect(
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("set.par2").path))
    }

    @Test func failureEndStatesAreExactlyTheNotifiableOnes() {
        #expect(DocStatus.notValid.isFailureEndState)
        #expect(DocStatus.internalError.isFailureEndState)
        #expect(DocStatus.extractionFailed.isFailureEndState)
        #expect(DocStatus.createFailed.isFailureEndState)
        #expect(DocStatus.needMoreRecovery(blocks: 3).isFailureEndState)
        // Consent and in-flight states never notify.
        #expect(!DocStatus.repairNeeded.isFailureEndState)
        #expect(!DocStatus.checking.isFailureEndState)
        #expect(!DocStatus.allFilesOK.isFailureEndState)
        #expect(!DocStatus.waitingToStart.isFailureEndState)
        // No state is both green and a failure.
        #expect(!DocStatus.restoredSuccessfully.isFailureEndState)
    }
}
