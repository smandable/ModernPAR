import Foundation
import ModernPARCore
import Testing

@testable import Par2Kit

/// Create-path tests (ROADMAP Phase 6 exit criteria): a created set verifies clean through the
/// embedded engine AND cross-tool via the Homebrew `par2` CLI (1.1.1), the options are honored,
/// and the run streams + cancels like verify/repair.
struct EmbeddedCreateTests {

    private func makeFolder(_ files: [(String, Int)]) throws -> (dir: URL, urls: [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (name, size) in files {
            let url = dir.appendingPathComponent(name)
            try Data((0..<size).map { _ in UInt8.random(in: .min ... .max) }).write(to: url)
            urls.append(url)
        }
        return (dir, urls)
    }

    private func collect(_ stream: AsyncStream<EngineEvent>) async -> [EngineEvent] {
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

    private func request(
        parFile: URL, files: [URL], options: CreateOptions
    ) throws -> CreateRequest {
        CreateRequest(
            parFile: parFile, files: files, options: options,
            folderBookmark: try? ScopedAccess.bookmark(for: parFile.deletingLastPathComponent()))
    }

    /// Runs the Homebrew `par2 verify` against a created set; returns true on a clean verify.
    /// Skips (returns nil) when no `par2` CLI is installed.
    private func par2CliVerifies(parFile: URL) -> Bool? {
        let candidates = ["/opt/homebrew/bin/par2", "/usr/local/bin/par2", "/usr/bin/par2"]
        guard
            let par2 = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: par2)
        process.arguments = ["verify", parFile.path]
        process.currentDirectoryURL = parFile.deletingLastPathComponent()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        return process.terminationStatus == 0
    }

    // MARK: - Create + verify round-trips

    @Test func createdSetVerifiesCleanThroughTheEmbeddedEngineAndPar2Cli() async throws {
        let (dir, urls) = try makeFolder([("alpha.bin", 2 << 20), ("beta.bin", 1 << 20)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("archive.par2")

        let engine = EmbeddedEngine()
        let events = await collect(
            engine.create(
                try request(
                    parFile: parFile, files: urls,
                    options: CreateOptions(redundancyPercent: 10))))

        guard case .success = finalResult(events) else {
            Issue.record("create failed: \(String(describing: finalResult(events)))")
            return
        }
        #expect(placed(events) == parFile)
        #expect(FileManager.default.fileExists(atPath: parFile.path))
        // Recovery volume files were written beside the index.
        let made = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(made.contains { $0.hasPrefix("archive.vol") && $0.hasSuffix(".par2") })
        #expect(
            events.contains {
                if case .docStatusChanged(.createdSuccessfully) = $0 { return true }
                return false
            })

        // Verify through our own embedded engine.
        let route = SessionRoute(
            mode: .verifyRepair,
            folderBookmark: try? ScopedAccess.bookmark(for: dir),
            anchorBookmark: try ScopedAccess.bookmark(for: parFile))
        let verifyEvents = await collect(EmbeddedEngine().run(route))
        #expect(
            verifyEvents.contains {
                if case .docStatusChanged(.allFilesOK) = $0 { return true }
                return false
            }, "embedded verify of the created set should be clean")

        // Cross-tool: par2cmdline 1.1.1 must verify it clean (proves naming/sizing compat).
        if let ok = par2CliVerifies(parFile: parFile) {
            #expect(ok, "par2 CLI should verify the created set clean")
        }
    }

    @Test func createdSetRepairsRealDamage() async throws {
        let (dir, urls) = try makeFolder([("data.bin", 4 << 20)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("data.par2")
        let victim = urls[0]
        let original = try Data(contentsOf: victim)

        let create = await collect(
            EmbeddedEngine().create(
                try request(
                    parFile: parFile, files: urls,
                    options: CreateOptions(redundancyPercent: 30, blockSize: .kilobytes(64)))))
        guard case .success = finalResult(create) else {
            Issue.record("create failed")
            return
        }

        // Damage several blocks, then repair. A 4 MiB file at 64 KB blocks = 64 source
        // blocks; 30% redundancy ≈ 19 recovery blocks, so damage 10 (well within budget).
        var damaged = original
        for block in 0..<10 { damaged[block * 65536] ^= 0xFF }
        try damaged.write(to: victim)

        let route = SessionRoute(
            mode: .verifyRepair,
            folderBookmark: try? ScopedAccess.bookmark(for: dir),
            anchorBookmark: try ScopedAccess.bookmark(for: parFile))
        let repair = await collect(EmbeddedEngine().run(route))
        guard case .success(let summary)? = finalResult(repair) else {
            Issue.record("repair failed: \(String(describing: finalResult(repair)))")
            return
        }
        #expect(summary.repaired == 1)
        #expect(try Data(contentsOf: victim) == original)
    }

    @Test func uniformSchemeAndManualBlockSizeAreHonored() async throws {
        let (dir, urls) = try makeFolder([("one.bin", 3 << 20)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("uniform.par2")
        let events = await collect(
            EmbeddedEngine().create(
                try request(
                    parFile: parFile, files: urls,
                    options: CreateOptions(
                        redundancyPercent: 15, blockSize: .kilobytes(128),
                        fileScheme: .uniform))))
        guard case .success = finalResult(events) else {
            Issue.record("create failed: \(String(describing: finalResult(events)))")
            return
        }
        // The block-size header line reflects the manual 128 KB = 131072 bytes.
        let logs = events.compactMap { event -> String? in
            if case .logLine(let l) = event { return l }
            return nil
        }
        #expect(logs.contains { $0.contains("131072 bytes") })
        if let ok = par2CliVerifies(parFile: parFile) { #expect(ok) }
    }

    @Test func progressReachesCompletion() async throws {
        let (dir, urls) = try makeFolder([("p.bin", 4 << 20)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("p.par2")
        let events = await collect(
            EmbeddedEngine().create(
                try request(parFile: parFile, files: urls, options: CreateOptions())))
        let fractions = events.compactMap { event -> Double? in
            if case .overallProgress(let f) = event { return f }
            return nil
        }
        #expect(fractions.contains { $0 >= 0.99 }, "progress should reach completion")
        // Monotonic non-decreasing.
        #expect(fractions == fractions.sorted())
    }

    @Test func emptyFileSetFailsCleanly() async throws {
        let (dir, _) = try makeFolder([])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("empty.par2")
        let events = await collect(
            EmbeddedEngine().create(
                CreateRequest(parFile: parFile, files: [], options: CreateOptions())))
        guard case .failure(let error)? = finalResult(events) else {
            Issue.record("expected failure")
            return
        }
        if case .launchFailed = error {
        } else {
            Issue.record("expected launchFailed, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: parFile.path))
    }

    @Test func cancellingCreateIsSafe() async throws {
        // Cancellation timing vs the (fast, SIMD) engine is nondeterministic, so this asserts
        // the SAFETY property: dropping the stream mid-create never crashes and the engine
        // queue stays healthy for the next run. (The partial-output cleanup is covered
        // deterministically by cleanupRemovesPartialOutputButNotSources.)
        let (dir, urls) = try makeFolder([("big.bin", 16 << 20)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let stream = EmbeddedEngine().create(
            try request(
                parFile: dir.appendingPathComponent("big.par2"), files: urls,
                options: CreateOptions(redundancyPercent: 50, blockSize: .kilobytes(8))))
        let consumer = Task {
            for await event in stream {
                if case .overallProgress = event { break }
            }
        }
        _ = await consumer.value
        try await Task.sleep(for: .milliseconds(200))

        // A create in a FRESH folder must succeed after the cancel — proves the shared engine
        // queue is not wedged.
        let (dir2, urls2) = try makeFolder([("after.bin", 1 << 20)])
        defer { try? FileManager.default.removeItem(at: dir2) }
        let rerun = await collect(
            EmbeddedEngine().create(
                try request(
                    parFile: dir2.appendingPathComponent("after.par2"), files: urls2,
                    options: CreateOptions(redundancyPercent: 10))))
        guard case .success = finalResult(rerun) else {
            Issue.record("create after cancel failed: \(String(describing: finalResult(rerun)))")
            return
        }
    }

    // Finding (LOW): par2create does NOT unlink its partial output on cancel, so the create
    // path cleans it up. Drive that cleanup deterministically over a synthetic partial set.
    @Test func cleanupRemovesPartialOutputButNotSources() throws {
        let (dir, urls) = try makeFolder([("movie.mkv", 1024), ("data.par2", 512)])
        defer { try? FileManager.default.removeItem(at: dir) }
        // A previous create's index + volumes for stem "set".
        for name in ["set.par2", "set.vol0+1.par2", "set.vol1+2.par2"] {
            try Data(count: 16).write(to: dir.appendingPathComponent(name))
        }
        let parFile = dir.appendingPathComponent("set.par2")
        EmbeddedEngine.cleanupPartialOutput(
            request: CreateRequest(parFile: parFile, files: urls, options: CreateOptions()))

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        // The partial set is gone.
        #expect(!remaining.contains("set.par2"))
        #expect(!remaining.contains("set.vol0+1.par2"))
        #expect(!remaining.contains("set.vol1+2.par2"))
        // Source files — including a SOURCE that happens to be a .par2 — are untouched.
        #expect(remaining.contains("movie.mkv"))
        #expect(remaining.contains("data.par2"))
    }
}
