import Foundation
import ModernPARCore
import Par2Cxx
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

    // MARK: - Empty (0-byte) files are left out, like the par2 CLI

    private func logLines(_ events: [EngineEvent]) -> [String] {
        events.compactMap { event -> String? in
            if case .logLine(let line) = event { return line }
            return nil
        }
    }

    @Test func emptyFilesAreLeftOutAndTheSetVerifiesClean() async throws {
        // A dropped folder brings hidden 0-byte files along with the data (".localized", the
        // custom-icon file "Icon\r"). Before the fix, an empty file whose File ID sorted ahead
        // of the data shifted every later checksum, so the new set reported intact files as
        // damaged ("empty-ae7" always sorts first — see EmptyFileCreateTests).
        let (dir, urls) = try makeFolder([
            ("alpha.bin", 300_000), (".localized", 0), ("beta.bin", 70_000), ("Icon\r", 0),
            ("empty-ae7", 0),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("folder.par2")

        let events = await collect(
            EmbeddedEngine().create(
                try request(
                    parFile: parFile, files: urls,
                    options: CreateOptions(redundancyPercent: 10))))
        guard case .success = finalResult(events) else {
            Issue.record("create failed: \(String(describing: finalResult(events)))")
            return
        }
        let logs = logLines(events)
        // Control characters print as %XX, as the engine prints them, so "Icon\r" can't split
        // the line.
        for name in [".localized", "Icon%0D", "empty-ae7"] {
            #expect(
                logs.contains(
                    "Skipping empty file “\(name)” — a 0-byte file has no data to protect."))
        }
        #expect(logs.contains { $0.hasPrefix("Creating folder.par2: 2 file(s),") })

        // Only the files with data are in the set...
        let set = try Par2Parser.loadSet(anchor: parFile)
        #expect(
            Set(set.recoveryFileIDs.compactMap { set.descriptions[$0]?.asciiName })
                == ["alpha.bin", "beta.bin"])
        #expect(set.nonRecoveryFileIDs.isEmpty)

        // ...and it verifies clean with the empty files still in the folder.
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
        if let ok = par2CliVerifies(parFile: parFile) {
            #expect(ok, "par2 CLI should verify the created set clean")
        }
    }

    @MainActor
    @Test func aFileThatGainsDataAfterBeingAddedIsProtected() async throws {
        // Staged while still empty (a download or export still writing, or a file the user
        // then saves into), it has data by the time Create is pressed. The build window read
        // its size when it was added; the run must judge it by its size now. (Foundation caches
        // resource values per URL instance, so re-reading them through the same URLs returned
        // the add-time 0 and the file was silently left out.)
        let (dir, urls) = try makeFolder([("data.bin", 100_000), ("late.bin", 0)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = CreateModel(kind: .par2)
        model.add(urls)
        #expect(model.skippedEmptyItems.map(\.name) == ["late.bin"])
        try Data(repeating: 7, count: 50_000).write(to: urls[1])

        let parFile = dir.appendingPathComponent("set.par2")
        let events = await collect(
            EmbeddedEngine().create(
                model.makeRequest(
                    parFile: parFile, folderBookmark: try? ScopedAccess.bookmark(for: dir))))
        guard case .success = finalResult(events) else {
            Issue.record("create failed: \(String(describing: finalResult(events)))")
            return
        }
        #expect(!logLines(events).contains { $0.hasPrefix("Skipping") })
        let set = try Par2Parser.loadSet(anchor: parFile)
        #expect(
            Set(set.recoveryFileIDs.compactMap { set.descriptions[$0]?.asciiName })
                == ["data.bin", "late.bin"])
    }

    @Test func aCreateThatCollidesWithAnExistingSetLeavesItAlone() async throws {
        // The engine never overwrites a set, so creating one under an existing set's name fails
        // ("File already exists"). The failed run's cleanup used to delete the EXISTING set as
        // if the run had written it.
        let (dir, urls) = try makeFolder([("data.bin", 200_000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("set.par2")
        let first = await collect(
            EmbeddedEngine().create(
                try request(parFile: parFile, files: urls, options: CreateOptions())))
        guard case .success = finalResult(first) else {
            Issue.record("first create failed: \(String(describing: finalResult(first)))")
            return
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".par2") }.sorted()
        let original = try names.map { try Data(contentsOf: dir.appendingPathComponent($0)) }

        let second = await collect(
            EmbeddedEngine().create(
                try request(parFile: parFile, files: urls, options: CreateOptions())))
        guard case .failure(.engine(let code, _))? = finalResult(second) else {
            Issue.record(
                "expected the engine to refuse, got \(String(describing: finalResult(second)))")
            return
        }
        #expect(code == Int32(PAR2SHIM_FILE_IO_ERROR.rawValue))
        let after = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".par2") }.sorted()
        #expect(after == names, "the existing set's files must all still be there")
        #expect(try after.map { try Data(contentsOf: dir.appendingPathComponent($0)) } == original)
    }

    @Test func onlyEmptyFilesFailCleanly() async throws {
        let (dir, urls) = try makeFolder([("e1", 0), ("e2", 0)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("empty.par2")
        let events = await collect(
            EmbeddedEngine().create(
                try request(parFile: parFile, files: urls, options: CreateOptions())))
        guard case .failure(.launchFailed)? = finalResult(events) else {
            Issue.record("expected launchFailed, got \(String(describing: finalResult(events)))")
            return
        }
        #expect(logLines(events).contains("[err] No non-empty files to protect."))
        #expect(!FileManager.default.fileExists(atPath: parFile.path))
    }

    @Test func aMissingFileIsNotMistakenForAnEmptyOne() async throws {
        // A size that can't be read is not 0: the file stays in the list, so the create fails
        // loudly instead of silently protecting fewer files than the user chose.
        let (dir, urls) = try makeFolder([("real.bin", 100_000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("set.par2")
        let missing = dir.appendingPathComponent("gone.bin")
        let events = await collect(
            EmbeddedEngine().create(
                try request(parFile: parFile, files: urls + [missing], options: CreateOptions())))
        guard case .failure(.engine(let code, _))? = finalResult(events) else {
            Issue.record(
                "expected an engine failure, got \(String(describing: finalResult(events)))")
            return
        }
        #expect(code == Int32(PAR2SHIM_FILE_IO_ERROR.rawValue))
        #expect(!logLines(events).contains { $0.hasPrefix("Skipping") })
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
