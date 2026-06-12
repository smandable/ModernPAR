import Foundation
import ModernPARCore
import Testing

@testable import ArchiveKit

/// Regression tests for the confirmed findings of the Phase 5 adversarial review — each test
/// names the failure it pins. (Fixture recipes in Fixtures/zip/README.md.)
struct ZipReviewRegressionTests {

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/zip")

    private func stage(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unzip-rr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.copyItem(
                at: Self.fixtureDir.appendingPathComponent(name),
                to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func runExtract(
        anchor: String, in folder: URL, keepBroken: Bool = false
    ) async throws -> [EngineEvent] {
        let route = SessionRoute(
            mode: .extractArchive,
            folderBookmark: try? ScopedAccess.bookmark(for: folder),
            anchorBookmark: try ScopedAccess.bookmark(for: folder.appendingPathComponent(anchor)))
        let stream = ZipExtractor().extract(
            route, options: ExtractOptions(keepBrokenFiles: keepBroken),
            password: CountingPasswordProvider(nil),
            conflicts: AutoConflictResolver(.cancel))
        var events: [EngineEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func finalResult(_ events: [EngineEvent]) -> Result<OperationSummary, EngineError>? {
        for event in events.reversed() {
            if case .finished(let result) = event { return result }
        }
        return nil
    }

    private func placed(_ events: [EngineEvent]) -> URL? {
        for event in events {
            if case .extractionPlaced(let url) = event { return url }
        }
        return nil
    }

    private func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
            .flatMap { $0 }) ?? 0
    }

    private func contents(of folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names)
    }

    // Finding (HIGH): streaming-reader entries with unset size were written empty and
    // reported success. They must carry their real bytes.
    @Test func streamingUnsetSizeEntriesExtractTheirRealBytes() async throws {
        let folder = try stage(["streaming-unset-size.zip"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(anchor: "streaming-unset-size.zip", in: folder)
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        guard let out = placed(events) else {
            Issue.record("nothing placed")
            return
        }
        // The whole point: NOT zero bytes.
        #expect(fileSize(out.appendingPathComponent("streamed.txt")) > 100)
        #expect(fileSize(out.appendingPathComponent("second.txt")) > 0)
    }

    // Finding (MEDIUM): a lying-size entry returned ARCHIVE_WARN from write_data_block and
    // aborted the ENTIRE run, discarding healthy files. It must be a per-file failure only.
    @Test func lyingSizeEntryFailsPerFileWithoutAbortingTheRun() async throws {
        let folder = try stage(["lying-size.zip"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(anchor: "lying-size.zip", in: folder)
        // honest.txt is the only surviving file → placed directly (single top-level item).
        guard let placedURL = placed(events) else {
            Issue.record(
                "the healthy file must still be placed, got \(String(describing: finalResult(events)))"
            )
            return
        }
        #expect(
            placedURL.lastPathComponent == "honest.txt",
            "the file after the lying entry must extract; placed \(placedURL.lastPathComponent)")
        if case .failure(let error) = finalResult(events) {
            // It's reported as damage, NOT a destination-write fatal that blames the disk.
            if case .engine(let code, _) = error { #expect(code == 12) }
        }
    }

    // Finding (LOW/HIGH-security): unsafe symlinks must be skipped like the RAR engine, not
    // created verbatim in the output. The good file still extracts and the run succeeds.
    @Test func unsafeSymlinksAreSkippedAndGoodEntriesSucceed() async throws {
        let folder = try stage(["symlinks.zip"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(anchor: "symlinks.zip", in: folder)
        guard case .success = finalResult(events) else {
            Issue.record("expected success, got \(String(describing: finalResult(events)))")
            return
        }
        guard let placedURL = placed(events) else {
            Issue.record("nothing placed")
            return
        }
        // good.txt is the only extracted entry → placed directly (single top-level item).
        #expect(placedURL.lastPathComponent == "good.txt")
        // Neither hostile link may exist anywhere in the destination folder.
        for link in ["abs_link", "escape_link"] {
            let url = folder.appendingPathComponent(link)
            #expect(
                !FileManager.default.fileExists(atPath: url.path),
                "\(link) must be skipped")
        }
        let skips = events.compactMap { event -> String? in
            if case .logLine(let line) = event, line.contains("Skipped"),
                line.contains("unsafe link")
            {
                return line
            }
            return nil
        }
        #expect(skips.count == 2, "skip logs: \(skips)")
    }

    // Finding (NIT-security): a staging-prefix entry name must be refused so a later run's
    // stale-staging sweep cannot delete it as "leftover".
    @Test func stagingPrefixEntryNamesAreRefused() async throws {
        let folder = try stage(["staging-name.zip"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(anchor: "staging-name.zip", in: folder)
        // The only entry was refused → nothing extractable.
        let placedAnything = placed(events) != nil
        let staged = contents(of: folder).contains { $0.hasPrefix(".ModernPAR-extract-") }
        #expect(!staged, "no staging-prefixed item may survive in the destination")
        if placedAnything {
            #expect(
                !(placed(events)!.lastPathComponent.hasPrefix(".ModernPAR-extract-")),
                "must not place a staging-prefixed item")
        }
    }

    @Test func safeRelativePathRefusesStagingPrefix() {
        #expect(ZipExtractor.safeRelativePath(".ModernPAR-extract-x/a.txt") == nil)
        #expect(
            ZipExtractor.safeRelativePath("ok/.ModernPAR-extract-x") == "ok/.ModernPAR-extract-x")
    }
}
