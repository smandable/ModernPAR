import Foundation
import ModernPARCore
import Testing

@testable import ArchiveKit

/// Protocol-level tests for the libarchive-backed zip engine (ROADMAP Phase 5 exit criterion:
/// "zip with both encryption schemes extracts correctly under sandbox") — plain/stored/
/// deflate, placement rules, ZipCrypto + WinZip AES, hostile entry names, cancellation.
/// Fixture recipes in Fixtures/zip/README.md; the password everywhere is "password".
struct ZipExtractorTests {

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/zip")

    private func stage(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.copyItem(
                at: Self.fixtureDir.appendingPathComponent(name),
                to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func route(anchor: URL, folder: URL) throws -> SessionRoute {
        SessionRoute(
            mode: .extractArchive,
            folderBookmark: try? ScopedAccess.bookmark(for: folder),
            anchorBookmark: try ScopedAccess.bookmark(for: anchor))
    }

    @discardableResult
    private func runExtract(
        archive: String,
        password: CountingPasswordProvider = CountingPasswordProvider(nil),
        conflicts: ConflictPolicy = .cancel,
        keepBroken: Bool = false,
        in existingFolder: URL? = nil
    ) async throws -> (events: [EngineEvent], folder: URL) {
        let folder = try existingFolder ?? stage([archive])
        let extractor = ZipExtractor()
        let stream = extractor.extract(
            try route(anchor: folder.appendingPathComponent(archive), folder: folder),
            options: ExtractOptions(keepBrokenFiles: keepBroken),
            password: password,
            conflicts: AutoConflictResolver(conflicts))
        var events: [EngineEvent] = []
        for await event in stream { events.append(event) }
        return (events, folder)
    }

    private func finalResult(_ events: [EngineEvent]) -> Result<OperationSummary, EngineError>? {
        for event in events.reversed() {
            if case .finished(let result) = event { return result }
        }
        return nil
    }

    private func finalError(_ events: [EngineEvent]) -> EngineError? {
        if case .failure(let error)? = finalResult(events) { return error }
        return nil
    }

    private func placed(_ events: [EngineEvent]) -> URL? {
        for event in events {
            if case .extractionPlaced(let url) = event { return url }
        }
        return nil
    }

    private func contents(of folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.map { $0.precomposedStringWithCanonicalMapping })
    }

    private func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
            .flatMap { $0 }) ?? 0
    }

    private func expectNoStagingLeftovers(in folder: URL) {
        let leftovers = contents(of: folder).filter { $0.hasPrefix(".ModernPAR-extract-") }
        #expect(leftovers.isEmpty, "staging leftovers: \(leftovers)")
    }

    // MARK: - Formats & placement

    @Test func extractsAPlainDeflateZip() async throws {
        let (events, folder) = try await runExtract(archive: "plain.zip")
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        // Two top-level files → wrapper folder named after the archive.
        let out = folder.appendingPathComponent("plain")
        #expect(placed(events)?.lastPathComponent == "plain")
        #expect(contents(of: out) == ["file1.txt", "file2.txt"])
        #expect(fileSize(out.appendingPathComponent("file1.txt")) == 20)
        expectNoStagingLeftovers(in: folder)
    }

    @Test func extractsAStoredZipAsASingleFile() async throws {
        let (events, folder) = try await runExtract(archive: "stored.zip")
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        // Single top-level item → placed directly, no wrapper.
        #expect(placed(events)?.lastPathComponent == "file1.txt")
        #expect(fileSize(folder.appendingPathComponent("file1.txt")) == 20)
    }

    @Test func preservesSubdirsAndUnicodeNames() async throws {
        let (events, folder) = try await runExtract(archive: "subdirs.zip")
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        let out = folder.appendingPathComponent("sub")
        #expect(placed(events)?.lastPathComponent == "sub")
        #expect(
            fileSize(out.appendingPathComponent("dir with space/nested.txt")) == 15)
        let unicodeDir = contents(of: out).contains("üñïçødé".precomposedStringWithCanonicalMapping)
        #expect(unicodeDir, "unicode subdirectory missing: \(contents(of: out))")
    }

    // MARK: - Encryption (exit criterion: both schemes)

    @Test func extractsZipCryptoWithThePasswordPromptingOnce() async throws {
        let provider = CountingPasswordProvider("password")
        let (events, folder) = try await runExtract(archive: "zipcrypto.zip", password: provider)
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        let out = folder.appendingPathComponent("zipcrypto")
        #expect(contents(of: out) == ["secret.txt", "file1.txt"])
        #expect(fileSize(out.appendingPathComponent("secret.txt")) == 15)
        #expect(provider.prompts == 1, "prompted \(provider.prompts) times")
    }

    @Test func wrongZipCryptoPasswordFailsAsBadPassword() async throws {
        let (events, folder) = try await runExtract(
            archive: "zipcrypto.zip", password: CountingPasswordProvider("wrong-password"))
        #expect(finalError(events) == .badPassword)
        #expect(placed(events) == nil)
        expectNoStagingLeftovers(in: folder)
    }

    @Test func decliningTheZipPasswordFailsAsPasswordNeeded() async throws {
        let (events, _) = try await runExtract(
            archive: "zipcrypto.zip", password: CountingPasswordProvider(nil))
        #expect(finalError(events) == .passwordNeeded)
    }

    @Test func extractsWinZipAES128AndAES256() async throws {
        for fixture in ["aes128.zip", "aes256.zip"] {
            let provider = CountingPasswordProvider("password")
            let (events, folder) = try await runExtract(archive: fixture, password: provider)
            guard case .success = finalResult(events) else {
                Issue.record(
                    "\(fixture): expected success, got \(String(describing: finalResult(events)))"
                )
                continue
            }
            // Single README entry → placed directly.
            #expect(placed(events)?.lastPathComponent == "README")
            #expect(fileSize(folder.appendingPathComponent("README")) == 6818)
            #expect(provider.prompts == 1)
        }
    }

    @Test func wrongAESPasswordFailsAsBadPassword() async throws {
        let (events, folder) = try await runExtract(
            archive: "aes256.zip", password: CountingPasswordProvider("wrong-password"))
        #expect(finalError(events) == .badPassword)
        #expect(placed(events) == nil)
        expectNoStagingLeftovers(in: folder)
    }

    // MARK: - Hostile input

    @Test func traversalEntriesAreRefusedButGoodEntriesExtract() async throws {
        let (events, folder) = try await runExtract(archive: "traversal.zip")
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        // good.txt is the only safe entry → placed directly.
        #expect(placed(events)?.lastPathComponent == "good.txt")
        // Nothing escaped the destination folder.
        let parent = folder.deletingLastPathComponent()
        #expect(
            !FileManager.default.fileExists(
                atPath: parent.appendingPathComponent("escape.txt").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: parent.appendingPathComponent("escape2.txt").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("escape2.txt").path))
        let refusals = events.compactMap { event -> String? in
            if case .logLine(let line) = event, line.contains("Refusing entry") { return line }
            return nil
        }
        #expect(refusals.count == 2, "refusal logs: \(refusals)")
    }

    @Test func absolutePathEntriesAreReRootedNotHonored() async throws {
        let absoluteTarget = URL(fileURLWithPath: "/tmp/abs-escape.txt")
        try? FileManager.default.removeItem(at: absoluteTarget)
        let (events, folder) = try await runExtract(archive: "absolute.zip")
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        #expect(
            !FileManager.default.fileExists(atPath: absoluteTarget.path),
            "absolute entry name must not be honored")
        // The re-rooted form lands INSIDE the output alongside ok.txt.
        let out = folder.appendingPathComponent("absolute")
        #expect(contents(of: out).contains("ok.txt"))
        #expect(
            FileManager.default.fileExists(
                atPath: out.appendingPathComponent("tmp/abs-escape.txt").path))
    }

    @Test func truncatedZipFailsGracefully() async throws {
        let (events, folder) = try await runExtract(archive: "truncated.zip")
        #expect(finalError(events) != nil)
        #expect(finalError(events) != .cancelled)
        expectNoStagingLeftovers(in: folder)
    }

    @Test func nonZipFileIsRejected() async throws {
        let (events, folder) = try await runExtract(archive: "not-a-zip.zip")
        guard case .engine(_, let message)? = finalError(events) else {
            Issue.record("expected engine error, got \(String(describing: finalResult(events)))")
            return
        }
        #expect(!message.isEmpty)
        expectNoStagingLeftovers(in: folder)
    }

    // MARK: - Conflicts & cancellation (shared machinery; one probe each)

    @Test func keepBothConflictNumbersTheSecondExtraction() async throws {
        let (first, folder) = try await runExtract(archive: "plain.zip")
        guard case .success = finalResult(first) else {
            Issue.record("first extraction failed")
            return
        }
        let (second, _) = try await runExtract(
            archive: "plain.zip", conflicts: .keepBoth, in: folder)
        guard case .success = finalResult(second) else {
            Issue.record("second extraction failed: \(String(describing: finalResult(second)))")
            return
        }
        #expect(placed(second)?.lastPathComponent == "plain 2")
    }

    @Test func cancellationWhileWaitingForThePasswordUnwindsCleanly() async throws {
        let folder = try stage(["zipcrypto.zip"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let stream = ZipExtractor().extract(
            try route(anchor: folder.appendingPathComponent("zipcrypto.zip"), folder: folder),
            options: ExtractOptions(),
            password: HangingPasswordProvider(),
            conflicts: AutoConflictResolver(.cancel))
        let consumer = Task {
            for await _ in stream {}
        }
        try await Task.sleep(for: .milliseconds(400))
        consumer.cancel()
        _ = await consumer.value
        for _ in 0..<50 {
            if !contents(of: folder).contains(where: { $0.hasPrefix(".ModernPAR-extract-") }) {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        expectNoStagingLeftovers(in: folder)
        #expect(
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("zipcrypto").path)
        )
    }

    // MARK: - Path sanitization unit tests

    @Test func safeRelativePathNormalizesAndRejects() {
        #expect(ZipExtractor.safeRelativePath("a/b.txt") == "a/b.txt")
        #expect(ZipExtractor.safeRelativePath("./a//b.txt") == "a/b.txt")
        #expect(ZipExtractor.safeRelativePath("/tmp/x.txt") == "tmp/x.txt")  // re-rooted
        #expect(ZipExtractor.safeRelativePath("a\\b\\c.txt") == "a/b/c.txt")  // Windows zips
        #expect(ZipExtractor.safeRelativePath("../escape.txt") == nil)
        #expect(ZipExtractor.safeRelativePath("a/../../escape.txt") == nil)
        #expect(ZipExtractor.safeRelativePath("..") == nil)
        #expect(ZipExtractor.safeRelativePath("") == nil)
        #expect(ZipExtractor.safeRelativePath("/") == nil)
    }
}
