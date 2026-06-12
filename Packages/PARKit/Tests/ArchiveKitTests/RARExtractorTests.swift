import ArchiveKit
import Foundation
import ModernPARCore
import Testing

/// Protocol-level tests for the in-process UnRAR engine (ROADMAP Phase 4 exit criteria):
/// RAR2/RAR3/RAR5, both multi-volume styles, password / encrypted-header archives, hostile
/// input, output placement, conflict policy, and cooperative cancellation — all through the
/// linked library, exactly the way `OperationSession` drives it. Fixtures are real archives
/// from the rarfile corpus (see Fixtures/rar/README.md); the password everywhere is "password".
struct RARExtractorTests {

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/rar")

    /// Copies the named fixtures into a fresh working folder (extraction writes beside the
    /// archive, so every test gets its own sandbox).
    private func stage(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unrar-\(UUID().uuidString)")
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

    private func collect(_ stream: AsyncStream<EngineEvent>) async -> [EngineEvent] {
        var events: [EngineEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @discardableResult
    private func runExtract(
        archive: String,
        staged: [String]? = nil,
        password: CountingPasswordProvider = CountingPasswordProvider(nil),
        conflicts: ConflictPolicy = .cancel,
        keepBroken: Bool = false,
        in existingFolder: URL? = nil
    ) async throws -> (events: [EngineEvent], folder: URL) {
        let folder: URL
        if let existingFolder {
            folder = existingFolder
        } else {
            folder = try stage(staged ?? [archive])
        }
        let extractor = RARExtractor()
        let events = await collect(
            extractor.extract(
                try route(anchor: folder.appendingPathComponent(archive), folder: folder),
                options: ExtractOptions(keepBrokenFiles: keepBroken),
                password: password,
                conflicts: AutoConflictResolver(conflicts)))
        return (events, folder)
    }

    // MARK: - Event helpers

    private func finalResult(_ events: [EngineEvent]) -> Result<OperationSummary, EngineError>? {
        for event in events.reversed() {
            if case .finished(let result) = event { return result }
        }
        return nil
    }

    private func finalError(_ events: [EngineEvent]) -> EngineError? {
        if case .failure(let error) = finalResult(events) { return error }
        return nil
    }

    private func placed(_ events: [EngineEvent]) -> URL? {
        for event in events {
            if case .extractionPlaced(let url) = event { return url }
        }
        return nil
    }

    private func discoveredNames(_ events: [EngineEvent]) -> [String] {
        for event in events {
            if case .filesDiscovered(let rows) = event { return rows.map(\.name) }
        }
        return []
    }

    private func statusCounts(_ events: [EngineEvent]) -> (ok: Int, failed: Int) {
        var ok = 0
        var failed = 0
        for event in events {
            if case .fileStatusChanged(_, let status) = event {
                if status == .ok { ok += 1 }
                if status == .unrecoverableCorrupt { failed += 1 }
            }
        }
        return (ok, failed)
    }

    private func logLines(_ events: [EngineEvent]) -> [String] {
        events.compactMap {
            if case .logLine(let line) = $0 { return line }
            return nil
        }
    }

    /// Path equality across the /var → /private/var symlink and trailing-slash differences.
    private func samePath(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func contents(of folder: URL) -> Set<String> {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.map { $0.precomposedStringWithCanonicalMapping })
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
            .flatMap { $0 } ?? 0
    }

    /// No `.ModernPAR-extract-*` staging folder may survive a run, success or failure.
    private func expectNoStagingLeftovers(in folder: URL) {
        let leftovers = contents(of: folder).filter { $0.hasPrefix(".ModernPAR-extract-") }
        #expect(leftovers.isEmpty, "staging leftovers: \(leftovers)")
    }

    // MARK: - Format generations (exit criterion: RAR2/RAR3/RAR5 via the linked lib)

    @Test func extractsRAR3Archive() async throws {
        let (events, folder) = try await runExtract(archive: "rar3-comment-plain.rar")
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        // Two top-level files → enclosing folder named after the archive.
        let out = folder.appendingPathComponent("rar3-comment-plain")
        #expect(samePath(placed(events), out))
        #expect(contents(of: out) == ["file1.txt", "file2.txt"])
        #expect(discoveredNames(events) == ["file1.txt", "file2.txt"])
        #expect(statusCounts(events).ok == 2)
        #expect(
            events.contains {
                if case .docStatusChanged(.extractedSuccessfully) = $0 { return true }
                return false
            })
        expectNoStagingLeftovers(in: folder)
    }

    @Test func extractsRAR5Archive() async throws {
        let (events, folder) = try await runExtract(archive: "rar5-crc.rar")
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        let out = folder.appendingPathComponent("rar5-crc")
        #expect(contents(of: out) == ["stest1.txt", "stest2.txt"])
        #expect(fileSize(out.appendingPathComponent("stest1.txt")) == 2048)
        #expect(fileSize(out.appendingPathComponent("stest2.txt")) == 2048)
        expectNoStagingLeftovers(in: folder)
    }

    @Test func extractsRAR15Archive() async throws {
        let (events, folder) = try await runExtract(archive: "rar15-comment.rar")
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        let out = folder.appendingPathComponent("rar15-comment")
        #expect(contents(of: out) == ["FILE1.TXT", "FILE2.TXT"])
        #expect(fileSize(out.appendingPathComponent("FILE1.TXT")) == 7)
    }

    @Test func extractsRAR202Archive() async throws {
        let (events, folder) = try await runExtract(archive: "rar202-comment-nopsw.rar")
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        let out = folder.appendingPathComponent("rar202-comment-nopsw")
        #expect(contents(of: out) == ["FILE1.TXT", "FILE2.TXT"])
    }

    @Test func extractsSolidArchive() async throws {
        let (events, folder) = try await runExtract(archive: "rar3-solid.rar")
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        expectNoStagingLeftovers(in: folder)
    }

    // MARK: - Structure: subdirectories, unicode names, placement

    @Test func preservesSubdirectoriesAndExtractsSingleTopLevelItemWithoutWrapper() async throws {
        let (events, folder) = try await runExtract(archive: "rar5-subdirs.rar")
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        // Every entry lives under "sub/" → single top-level item, no enclosing folder.
        let out = folder.appendingPathComponent("sub")
        #expect(samePath(placed(events), out))
        #expect(
            fileSize(out.appendingPathComponent("dir2/file2.txt")) == 6)
        #expect(
            fileSize(out.appendingPathComponent("with space/long fn.txt")) == 8)
        let unicodeDir = contents(of: out).contains("üȵĩöḋè".precomposedStringWithCanonicalMapping)
        #expect(unicodeDir, "unicode subdirectory missing: \(contents(of: out))")
    }

    @Test func extractsUnicodeFilenames() async throws {
        let (events, folder) = try await runExtract(archive: "unicode.rar")
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        let out = folder.appendingPathComponent("unicode")
        let expected: Set<String> = [
            "уииоотивл.txt".precomposedStringWithCanonicalMapping,
            "𝐀𝐁𝐁𝐂.txt".precomposedStringWithCanonicalMapping,
        ]
        #expect(contents(of: out) == expected)
    }

    // MARK: - Multi-volume (exit criterion)

    @Test func extractsOldStyleMultiVolumeSet() async throws {
        let (events, folder) = try await runExtract(
            archive: "rar3-old.rar", staged: ["rar3-old.rar", "rar3-old.r00", "rar3-old.r01"])
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        // Single top-level "vols" directory → placed directly.
        let out = folder.appendingPathComponent("vols")
        #expect(samePath(placed(events), out))
        #expect(fileSize(out.appendingPathComponent("bigfile.txt")) == 205_000)
        #expect(fileSize(out.appendingPathComponent("smallfile.txt")) == 2050)
    }

    @Test func extractsOldStyleSetOpenedFromAContinuationVolume() async throws {
        let (events, folder) = try await runExtract(
            archive: "rar3-old.r01", staged: ["rar3-old.rar", "rar3-old.r00", "rar3-old.r01"])
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        #expect(fileSize(folder.appendingPathComponent("vols/bigfile.txt")) == 205_000)
        #expect(logLines(events).contains { $0.contains("first volume") })
    }

    @Test func extractsNewStyleMultiVolumeSet() async throws {
        let parts = ["rar5-vols.part1.rar", "rar5-vols.part2.rar", "rar5-vols.part3.rar"]
        let (events, folder) = try await runExtract(
            archive: "rar5-vols.part1.rar", staged: parts)
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        let out = folder.appendingPathComponent("vols")
        #expect(fileSize(out.appendingPathComponent("bigfile.txt")) == 205_000)
        #expect(fileSize(out.appendingPathComponent("smallfile.txt")) == 2050)
        #expect(logLines(events).contains { $0.contains("Continuing in volume") })
    }

    @Test func extractsNewStyleSetOpenedFromAMiddleVolume() async throws {
        let parts = ["rar5-vols.part1.rar", "rar5-vols.part2.rar", "rar5-vols.part3.rar"]
        let (events, folder) = try await runExtract(
            archive: "rar5-vols.part2.rar", staged: parts)
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        #expect(fileSize(folder.appendingPathComponent("vols/bigfile.txt")) == 205_000)
        #expect(logLines(events).contains { $0.contains("first volume") })
    }

    @Test func missingVolumeProducesAMappedErrorNamingIt() async throws {
        let (events, folder) = try await runExtract(
            archive: "rar5-vols.part1.rar",
            staged: ["rar5-vols.part1.rar", "rar5-vols.part2.rar"])  // part3 absent
        guard case .volumeMissing(let name) = finalError(events) else {
            Issue.record("expected volumeMissing, got \(String(describing: finalResult(events)))")
            return
        }
        #expect(name.contains("part3"), "missing-volume name was \(name)")
        expectNoStagingLeftovers(in: folder)
    }

    // MARK: - Passwords (exit criterion: password archives via the linked lib; prompt once)

    @Test func extractsRAR5PasswordArchiveAndPromptsExactlyOnce() async throws {
        let provider = CountingPasswordProvider("password")
        let (events, folder) = try await runExtract(archive: "rar5-psw.rar", password: provider)
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        let out = folder.appendingPathComponent("rar5-psw")
        #expect(fileSize(out.appendingPathComponent("stest1.txt")) == 2048)
        #expect(fileSize(out.appendingPathComponent("stest2.txt")) == 2048)
        #expect(provider.prompts == 1, "prompted \(provider.prompts) times")
    }

    @Test func wrongRAR5PasswordFailsAsBadPassword() async throws {
        let provider = CountingPasswordProvider("wrong-password")
        let (events, folder) = try await runExtract(archive: "rar5-psw.rar", password: provider)
        #expect(finalError(events) == .badPassword)
        #expect(placed(events) == nil)
        #expect(
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("rar5-psw").path))
        expectNoStagingLeftovers(in: folder)
    }

    @Test func decliningThePasswordFailsAsPasswordNeeded() async throws {
        let (events, folder) = try await runExtract(
            archive: "rar5-psw.rar", password: CountingPasswordProvider(nil))
        #expect(finalError(events) == .passwordNeeded)
        expectNoStagingLeftovers(in: folder)
    }

    @Test func extractsRAR5EncryptedHeadersPromptingOnceAcrossBothPasses() async throws {
        let provider = CountingPasswordProvider("password")
        let (events, folder) = try await runExtract(archive: "rar5-hpsw.rar", password: provider)
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        let out = folder.appendingPathComponent("rar5-hpsw")
        #expect(fileSize(out.appendingPathComponent("stest1.txt")) == 2048)
        // The list pass and the extract pass each open the archive; the cached password
        // must make that a single user prompt. (ROADMAP: "prompt-once-and-reuse")
        #expect(provider.prompts == 1, "prompted \(provider.prompts) times")
    }

    @Test func encryptedHeadersWithNoPasswordFailsAsPasswordNeeded() async throws {
        let (events, _) = try await runExtract(
            archive: "rar5-hpsw.rar", password: CountingPasswordProvider(nil))
        #expect(finalError(events) == .passwordNeeded)
    }

    @Test func extractsRAR3EncryptedHeadersArchive() async throws {
        let provider = CountingPasswordProvider("password")
        let (events, _) = try await runExtract(
            archive: "rar3-comment-hpsw.rar", password: provider)
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        #expect(provider.prompts == 1)
    }

    @Test func wrongRAR3HeaderPasswordFailsAsBadPassword() async throws {
        // RAR3 has no password check value — garbage decryption surfaces as broken data. The
        // mapping must still call it a bad password so the UI re-prompts.
        let provider = CountingPasswordProvider("wrong-password")
        let (events, _) = try await runExtract(
            archive: "rar3-comment-hpsw.rar", password: provider)
        #expect(finalError(events) == .badPassword)
    }

    // MARK: - Hostile input (mapped errors, no crashes, no leftovers)

    @Test func corruptDataReportsTheBadFileAndKeepsTheGoodOne() async throws {
        let (events, folder) = try await runExtract(archive: "corrupt-data.rar")
        // One file survives, one fails its checksum → output is placed, run reports the damage.
        guard case .engine(let code, _) = finalError(events) else {
            Issue.record("expected engine error, got \(String(describing: finalResult(events)))")
            return
        }
        #expect(code == 12, "expected BAD_DATA, got \(code)")  // UNRARSHIM_BAD_DATA
        let counts = statusCounts(events)
        #expect(counts.ok == 1)
        #expect(counts.failed == 1)
        if let out = placed(events) {
            // The broken file is deleted (keepBroken = false), so the single surviving file
            // is the one top-level item — placed directly, no enclosing folder.
            #expect(out.lastPathComponent == "stest1.txt")
            #expect(fileSize(out) == 2048)
        } else {
            Issue.record("expected the good file to be placed")
        }
        expectNoStagingLeftovers(in: folder)
    }

    @Test func keepBrokenFilesPreferenceKeepsTheDamagedOutput() async throws {
        let (events, _) = try await runExtract(archive: "corrupt-data.rar", keepBroken: true)
        guard let out = placed(events) else {
            Issue.record("expected placement, got \(String(describing: finalResult(events)))")
            return
        }
        #expect(contents(of: out).count == 2, "broken file should be kept: \(contents(of: out))")
    }

    @Test func truncatedArchiveFailsGracefully() async throws {
        let (events, folder) = try await runExtract(archive: "truncated.rar")
        #expect(finalError(events) != nil)
        #expect(finalError(events) != .cancelled)
        expectNoStagingLeftovers(in: folder)
    }

    @Test func nonRarFileIsRejected() async throws {
        let (events, folder) = try await runExtract(archive: "not-a-rar.rar")
        guard case .engine(let code, let message) = finalError(events) else {
            Issue.record("expected engine error, got \(String(describing: finalResult(events)))")
            return
        }
        #expect(code == 13 || code == 14, "expected BAD_ARCHIVE/UNKNOWN_FORMAT, got \(code)")
        #expect(!message.isEmpty)
        expectNoStagingLeftovers(in: folder)
    }

    // MARK: - Destination conflicts (ROADMAP: ask / overwrite / keep-both / cancel)

    @Test func keepBothConflictPolicyNumbersTheSecondExtraction() async throws {
        let (first, folder) = try await runExtract(archive: "rar5-crc.rar")
        guard case .success = finalResult(first) else {
            Issue.record("first extraction failed")
            return
        }
        let (second, _) = try await runExtract(
            archive: "rar5-crc.rar", conflicts: .keepBoth, in: folder)
        guard case .success = finalResult(second) else {
            Issue.record("second extraction failed: \(String(describing: finalResult(second)))")
            return
        }
        #expect(samePath(placed(second), folder.appendingPathComponent("rar5-crc 2")))
        #expect(contents(of: folder.appendingPathComponent("rar5-crc 2")).count == 2)
    }

    @Test func overwriteConflictPolicyReplacesTheExistingOutput() async throws {
        let (first, folder) = try await runExtract(archive: "rar5-crc.rar")
        guard case .success = finalResult(first) else {
            Issue.record("first extraction failed")
            return
        }
        // Plant a marker inside the existing output to prove it was replaced, not merged.
        let marker = folder.appendingPathComponent("rar5-crc/marker.txt")
        FileManager.default.createFile(atPath: marker.path, contents: Data("x".utf8))
        let (second, _) = try await runExtract(
            archive: "rar5-crc.rar", conflicts: .overwrite, in: folder)
        guard case .success = finalResult(second) else {
            Issue.record("second extraction failed: \(String(describing: finalResult(second)))")
            return
        }
        #expect(samePath(placed(second), folder.appendingPathComponent("rar5-crc")))
        #expect(
            contents(of: folder.appendingPathComponent("rar5-crc")) == ["stest1.txt", "stest2.txt"])
    }

    @Test func cancelConflictPolicyLeavesTheExistingOutputUntouched() async throws {
        let (first, folder) = try await runExtract(archive: "rar5-crc.rar")
        guard case .success = finalResult(first) else {
            Issue.record("first extraction failed")
            return
        }
        let (second, _) = try await runExtract(
            archive: "rar5-crc.rar", conflicts: .cancel, in: folder)
        #expect(finalError(second) == .cancelled)
        #expect(
            contents(of: folder.appendingPathComponent("rar5-crc")) == ["stest1.txt", "stest2.txt"])
        expectNoStagingLeftovers(in: folder)
    }

    // MARK: - Cancellation (cooperative, no leftovers)

    @Test func cancellationWhileWaitingForAPasswordUnwindsCleanly() async throws {
        let folder = try stage(["rar5-psw.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let extractor = RARExtractor()
        let stream = extractor.extract(
            try route(anchor: folder.appendingPathComponent("rar5-psw.rar"), folder: folder),
            options: ExtractOptions(),
            password: HangingPasswordProvider(),
            conflicts: AutoConflictResolver(.cancel))

        let consumer = Task {
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        // Give the engine time to reach the password prompt, then cancel the consumer —
        // exactly what Cmd-. does. The token poll must unwind the blocked engine thread.
        try await Task.sleep(for: .milliseconds(400))
        consumer.cancel()
        _ = await consumer.value

        // The engine queue run must complete and clean its staging folder.
        for _ in 0..<50 {
            if !contents(of: folder).contains(where: { $0.hasPrefix(".ModernPAR-extract-") }) {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        expectNoStagingLeftovers(in: folder)
        #expect(
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("rar5-psw").path))
    }
}

// MARK: - Test doubles

/// Counts how often the engine actually consulted the provider — the prompt-once contract.
final class CountingPasswordProvider: PasswordProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let value: String?
    private var count = 0

    init(_ value: String?) { self.value = value }

    func password(forVolume name: String) async -> String? {
        lock.withLock { count += 1 }
        return value
    }

    var prompts: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Never answers — models a password sheet the user leaves open, for cancellation tests.
struct HangingPasswordProvider: PasswordProvider {
    func password(forVolume name: String) async -> String? {
        try? await Task.sleep(for: .seconds(60))
        return nil
    }
}

struct AutoConflictResolver: ConflictResolver {
    let policy: ConflictPolicy
    init(_ policy: ConflictPolicy) { self.policy = policy }
    func resolve(conflictAt url: URL) async -> ConflictPolicy { policy }
}
