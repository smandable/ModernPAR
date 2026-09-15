import Foundation
import Testing

@testable import ModernPARCore

/// The sandbox folder-grant flow as the r/macapps reports (2026-07) exercised it: a declined
/// or never-shown grant must be VISIBLE in the status line, archives stage before their run
/// is configured so the grant can come first, and a remembered parent grant covers children.
@MainActor
struct FolderGrantFlowTests {

    /// A folder the test process cannot READ (mode 0300) — the closest a non-sandboxed test
    /// gets to a folder the sandbox has not been granted. `needsFolderGrant` keys on
    /// readability. Callers must `cleanUp` (restores the mode before removing).
    func scratchArchive() throws -> (folder: URL, archive: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("grant-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("payload.rar")
        try Data("Rar!".utf8).write(to: archive)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: folder.path)
        return (folder, archive)
    }

    func cleanUp(_ folder: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func declinedGrantIsAConsentStateOnTheStatusLine() {
        let session = OperationSession()
        session.folderGrantDeclined()
        #expect(session.docStatus == .folderAccessNeeded)
        #expect(!session.awaitingFolderGrant)
        // A consent state: neither green nor a failure (no unattended failure notification).
        #expect(!DocStatus.folderAccessNeeded.isGreenEndState)
        #expect(!DocStatus.folderAccessNeeded.isFailureEndState)
        #expect(session.log.last?.contains("Grant Folder Access") == true)
        #expect(session.log.last?.contains("verify") == true)
    }

    @Test func stagingAnArchiveSetsTheAnchorWithoutStartingAnything() throws {
        FolderAccessStore.removeAll()
        let (folder, archive) = try scratchArchive()
        defer { cleanUp(folder) }
        let session = OperationSession()
        session.stageArchive(archive)
        #expect(session.anchorURL == archive)
        #expect(session.anchorIsArchive)
        #expect(!session.isBusy)
        #expect(!session.awaitingFolderGrant)
        #expect(session.docStatus == .waitingToStart)
        // Nothing granted yet: the UI must show the grant panel BEFORE configuring the run.
        #expect(session.needsFolderGrant)
    }

    @Test func decliningAStagedArchiveExplainsExtractionNotVerify() throws {
        FolderAccessStore.removeAll()
        let (folder, archive) = try scratchArchive()
        defer { cleanUp(folder) }
        let session = OperationSession()
        let endedBefore = session.runEnded
        session.stageArchive(archive)
        session.folderGrantDeclined()
        #expect(session.docStatus == .folderAccessNeeded)
        #expect(session.log.last?.contains("extraction") == true)
        #expect(session.runEnded == endedBefore + 1, "a decline must settle the open queue")
    }

    @Test func aRememberedParentGrantCoversAStagedArchive() throws {
        FolderAccessStore.removeAll()
        defer { FolderAccessStore.removeAll() }
        let (folder, archive) = try scratchArchive()
        defer { cleanUp(folder) }
        let session = OperationSession()
        session.stageArchive(archive)
        #expect(session.needsFolderGrant)
        FolderAccessStore.remember(folder.deletingLastPathComponent())
        #expect(!session.needsFolderGrant, "a grant on a parent folder covers its children")
    }

    @Test func requestExtractWithoutAGrantWaitsInsteadOfRunning() throws {
        FolderAccessStore.removeAll()
        let (folder, archive) = try scratchArchive()
        defer { cleanUp(folder) }
        let session = OperationSession()
        session.stageArchive(archive)
        session.requestExtract(
            using: NeverExtractor(), password: NoPassword(), conflicts: NoConflicts())
        #expect(session.awaitingFolderGrant)
        #expect(!session.isBusy)
        session.folderGrantDeclined()
        #expect(session.docStatus == .folderAccessNeeded)
        #expect(!session.awaitingFolderGrant)
    }

    struct NeverExtractor: ArchiveExtractor {
        func extract(
            _ archive: SessionRoute, options: ExtractOptions,
            password: any PasswordProvider, conflicts: any ConflictResolver
        ) -> AsyncStream<EngineEvent> {
            Issue.record("extraction must not start without a folder grant")
            return AsyncStream { $0.finish() }
        }
    }
    struct NoPassword: PasswordProvider {
        func password(forVolume name: String) async -> String? { nil }
    }
    struct NoConflicts: ConflictResolver {
        func resolve(conflictAt url: URL) async -> ConflictPolicy { .cancel }
    }
}

extension FolderGrantFlowTests {
    /// The grant-first archive path: a grant obtained outside the deferred-action flow must
    /// clear the consent state even when the run that follows never starts (destination
    /// panel cancelled) — otherwise the banner keeps claiming access is missing. (v1.0.1 review)
    @Test func aSatisfiedGrantClearsTheConsentStateWithoutARun() throws {
        FolderAccessStore.removeAll()
        defer { FolderAccessStore.removeAll() }
        let (folder, archive) = try scratchArchive()
        defer { cleanUp(folder) }
        let session = OperationSession()
        session.stageArchive(archive)
        session.folderGrantDeclined()
        #expect(session.docStatus == .folderAccessNeeded)
        FolderAccessStore.remember(folder.deletingLastPathComponent())
        session.folderGrantSatisfied()
        #expect(session.docStatus == .waitingToStart)
        #expect(!session.isBusy)
        #expect(session.log.last == "Folder access granted.")
        // Idempotent and inert outside the consent state.
        session.folderGrantSatisfied()
        #expect(session.docStatus == .waitingToStart)
    }
}
