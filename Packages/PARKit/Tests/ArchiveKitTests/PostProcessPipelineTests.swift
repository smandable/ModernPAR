import ArchiveKit
import Foundation
import ModernPARCore
import Par2Kit
import Testing

/// The Phase 5 demoable milestone, end-to-end with the REAL engines and no UI: a PAR2 set
/// whose payload is an archive → open → verify passes → the first matching rule chains the
/// session into extraction → extracted files land beside the set. ★ This is the MVP pipeline
/// (ROADMAP Phase 5).
@MainActor
struct PostProcessPipelineTests {

    static let rarFixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/rar")
    static let zipFixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/zip")

    /// Builds a working folder holding the payload archive + a freshly created PAR2 set
    /// over it (Par2Create — the same engine-level create the spike pinned).
    private func makeSet(payloadFixture: URL) throws -> (folder: URL, parFile: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload = folder.appendingPathComponent(payloadFixture.lastPathComponent)
        try FileManager.default.copyItem(at: payloadFixture, to: payload)
        let parFile = folder.appendingPathComponent("set.par2")
        try Par2Create.createSet(
            parFile: parFile, files: [payload], blockSize: 4096, recoveryBlockCount: 8)
        return (folder, parFile)
    }

    private func drain(_ session: OperationSession, timeoutMilliseconds: Int = 30000) async {
        for _ in 0..<(timeoutMilliseconds / 10) {
            if !session.isBusy { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits until the session goes idle AND the post-process trigger fires (or times out).
    private func drainUntilTrigger(_ session: OperationSession) async {
        for _ in 0..<3000 {
            if session.postProcessReady > 0 && !session.isBusy { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func runPipeline(
        payloadFixture: URL, extractor: any ArchiveExtractor
    ) async throws -> (session: OperationSession, folder: URL) {
        let (folder, parFile) = try makeSet(payloadFixture: payloadFixture)
        let session = OperationSession()

        // Open → verify (the MacPAR loop) with the real embedded turbo engine.
        session.open(parFile, thenVerifyUsing: EmbeddedEngine(), autoRepair: true)
        await drainUntilTrigger(session)
        #expect(session.postProcessReady == 1, "verify must end green and fire the trigger")
        #expect(session.docStatus.isGreenEndState, "got \(session.docStatus)")

        // The rule decision PostProcessor makes in the UI, replicated engine-side.
        let names = session.rows.map(\.name)
        let match = try #require(PostProcessRules.standard.firstMatch(in: names))
        let payload = folder.appendingPathComponent(match.filename)
        session.chainIntoArchive(
            payload, ruleName: match.rule.name, using: extractor,
            password: StaticPassword(nil), conflicts: StaticConflicts(.cancel))
        await drain(session)
        return (session, folder)
    }

    struct StaticPassword: PasswordProvider {
        let value: String?
        init(_ value: String?) { self.value = value }
        func password(forVolume name: String) async -> String? { value }
    }

    struct StaticConflicts: ConflictResolver {
        let policy: ConflictPolicy
        init(_ policy: ConflictPolicy) { self.policy = policy }
        func resolve(conflictAt url: URL) async -> ConflictPolicy { policy }
    }

    @Test func verifiedRarPayloadChainsIntoExtraction() async throws {
        let (session, folder) = try await runPipeline(
            payloadFixture: Self.rarFixtures.appendingPathComponent("rar3-comment-plain.rar"),
            extractor: RARExtractor())
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(session.docStatus == .extractedSuccessfully, "got \(session.docStatus)")
        let out = folder.appendingPathComponent("rar3-comment-plain")
        #expect(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("file1.txt").path))
        #expect(session.placedURL != nil)
        // The whole pipeline's history lives in one log: verify lines AND extraction lines.
        #expect(session.log.contains { $0.contains("Loading \"set.par2\"") })
        #expect(session.log.contains { $0.contains("Post-processing (Built-in Unrar)") })
        #expect(session.log.contains { $0.contains("Extracted to") })
    }

    @Test func verifiedZipPayloadChainsIntoExtraction() async throws {
        let (session, folder) = try await runPipeline(
            payloadFixture: Self.zipFixtures.appendingPathComponent("plain.zip"),
            extractor: ZipExtractor())
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(session.docStatus == .extractedSuccessfully, "got \(session.docStatus)")
        let out = folder.appendingPathComponent("plain")
        #expect(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("file1.txt").path))
        #expect(session.log.contains { $0.contains("Post-processing (Built-in Unzip)") })
    }
}
