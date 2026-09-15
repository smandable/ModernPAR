import Foundation
import ModernPARCore
import Par2Cxx
import Testing

@testable import Par2Kit

/// Protocol-level tests for the embedded engine (ROADMAP Phase 2 exit criteria): verify and
/// repair against golden sets, event-stream shape, create round-trip, and cooperative
/// cancellation. These drive `EmbeddedEngine` exactly the way `OperationSession` does.
struct EmbeddedEngineTests {

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ModernPARCoreTests/Fixtures/par2cmdline")

    private func stageFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-\(UUID().uuidString)")
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

    private func finalStatuses(in events: [EngineEvent]) -> [UUID: FileStatus] {
        var statuses: [UUID: FileStatus] = [:]
        for case .fileStatusChanged(let id, let status) in events {
            statuses[id] = status
        }
        return statuses
    }

    private func finishedSummary(in events: [EngineEvent]) -> OperationSummary? {
        guard case .finished(.success(let summary))? = events.last else { return nil }
        return summary
    }

    // MARK: - Verify / repair

    @Test func verifyingAnIntactSetStreamsOKEventsAndSucceeds() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = EmbeddedEngine()
        let events = await collect(
            engine.run(try route(anchor: dir.appendingPathComponent("set.par2"), folder: dir)))

        let roster = events.compactMap { event -> [FileEntry]? in
            if case .filesDiscovered(let files) = event { return files }
            return nil
        }.first
        #expect(roster?.count == 4)

        let statuses = finalStatuses(in: events)
        #expect(statuses.count == 4)
        #expect(statuses.values.allSatisfy { $0 == .ok })
        #expect(
            events.contains {
                if case .docStatusChanged(.allFilesOK) = $0 { return true } else { return false }
            })
        let summary = try #require(finishedSummary(in: events))
        #expect(summary.repaired == 0)
        #expect(summary.stillMissing == 0)
    }

    @Test func damagedSetRepairsAutomaticallyWithPerFileLifecycle() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = dir.appendingPathComponent("file-a.bin")
        let original = try Data(contentsOf: victim)
        var damaged = original
        for i in 0..<1200 { damaged[i] ^= 0xA5 }
        try damaged.write(to: victim)

        let engine = EmbeddedEngine()
        let events = await collect(
            engine.run(try route(anchor: dir.appendingPathComponent("set.par2"), folder: dir)))

        // The damaged file must pass through recoverableCorrupt and end recovered.
        let parsedSet = try Par2Parser.loadSet(anchor: dir.appendingPathComponent("set.par2"))
        let victimID = try #require(
            parsedSet.descriptions.values.first { $0.preferredName == "file-a.bin" }?.fileID.uuid)
        let trail = events.compactMap { event -> FileStatus? in
            if case .fileStatusChanged(victimID, let status) = event { return status }
            return nil
        }
        #expect(trail.contains(.recoverableCorrupt))
        #expect(trail.last == .recovered)
        #expect(
            events.contains {
                if case .docStatusChanged(.restoredSuccessfully) = $0 {
                    return true
                } else {
                    return false
                }
            })
        let summary = try #require(finishedSummary(in: events))
        #expect(summary.repaired == 1)
        #expect(try Data(contentsOf: victim) == original)  // byte-identical restoration
    }

    @Test func verifyOnlyEngineReportsDamageWithoutTouchingFiles() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = dir.appendingPathComponent("file-b.bin")
        var damaged = try Data(contentsOf: victim)
        damaged[0] ^= 0xFF
        try damaged.write(to: victim)
        let mutated = damaged

        let engine = EmbeddedEngine(repairsAutomatically: false)
        let events = await collect(
            engine.run(try route(anchor: dir.appendingPathComponent("set.par2"), folder: dir)))

        let summary = try #require(finishedSummary(in: events))
        #expect(summary.repaired == 0)
        #expect(summary.stillMissing == 1)
        let statuses = finalStatuses(in: events)
        #expect(statuses.values.contains(.recoverableCorrupt))
        #expect(try Data(contentsOf: victim) == mutated)  // verify-only never writes
        // Terminal doc status must be the awaiting-consent verdict — never .repairing
        // (a verify-only run repairs nothing; "Restoring files…" forever was a review find).
        let lastDocStatus = events.compactMap { event -> DocStatus? in
            if case .docStatusChanged(let status) = event { return status }
            return nil
        }.last
        #expect(lastDocStatus == .repairNeeded)
    }

    @Test func insufficientRecoveryReportsNeededBlocks() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Remove every recovery volume: 0 recovery blocks remain, then damage a file.
        for file in try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        where file.lastPathComponent.contains(".vol") {
            try FileManager.default.removeItem(at: file)
        }
        let victim = dir.appendingPathComponent("file-a.bin")
        var damaged = try Data(contentsOf: victim)
        for i in 0..<1200 { damaged[i] ^= 0xA5 }
        try damaged.write(to: victim)

        let engine = EmbeddedEngine()
        let events = await collect(
            engine.run(try route(anchor: dir.appendingPathComponent("set.par2"), folder: dir)))

        let needed = events.compactMap { event -> Int? in
            if case .docStatusChanged(.needMoreRecovery(let blocks)) = event { return blocks }
            return nil
        }
        #expect((needed.first ?? 0) > 0)
        let statuses = finalStatuses(in: events)
        #expect(statuses.values.contains(.unrecoverableCorrupt))
    }

    @Test func misnamedFileIsFoundAndRenamedBack() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The classic Usenet case: the data is intact but under the wrong name.
        let proper = dir.appendingPathComponent("file-b.bin")
        let wrongName = dir.appendingPathComponent("totally-wrong-name.dat")
        try FileManager.default.moveItem(at: proper, to: wrongName)

        let engine = EmbeddedEngine()
        let events = await collect(
            engine.run(try route(anchor: dir.appendingPathComponent("set.par2"), folder: dir)))

        let lastDocStatus = events.compactMap { event -> DocStatus? in
            if case .docStatusChanged(let status) = event { return status }
            return nil
        }.last
        #expect(lastDocStatus == .restoredWithRenames)
        let statuses = finalStatuses(in: events)
        #expect(
            statuses.values.contains { status in
                if case .renamed = status { return true } else { return false }
            })
        #expect(FileManager.default.fileExists(atPath: proper.path))  // renamed back
    }

    @Test func nonVerifyModesFailCleanly() async throws {
        let engine = EmbeddedEngine()
        let events = await collect(engine.run(SessionRoute(mode: .extractArchive)))
        guard case .finished(.failure(let error))? = events.last else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .notImplemented)
    }

    @Test func missingAnchorBookmarkFailsCleanly() async throws {
        let engine = EmbeddedEngine()
        let events = await collect(engine.run(SessionRoute(mode: .verifyRepair)))
        guard case .finished(.failure(.launchFailed))? = events.last else {
            Issue.record("expected launchFailed")
            return
        }
    }

    // MARK: - Create (engine-level; the UI arrives in Phase 6)

    @Test func createdSetVerifiesCleanAndMatchesRequestedShape() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, size) in [("one.bin", 9000), ("two.bin", 2500)] {
            try Data((0..<size).map { _ in UInt8.random(in: .min ... .max) })
                .write(to: dir.appendingPathComponent(name))
        }

        let parPath = dir.appendingPathComponent("made.par2")
        try Par2Create.createSet(
            parFile: parPath,
            files: [dir.appendingPathComponent("one.bin"), dir.appendingPathComponent("two.bin")],
            blockSize: 1000,
            recoveryBlockCount: 5)

        // Read back with the native parser: 12 source blocks (9+3), 5 recovery blocks.
        let set = try Par2Parser.loadSet(anchor: parPath)
        #expect(set.sliceSize == 1000)
        #expect(set.sourceBlockCount == 12)
        #expect(set.recoveryBlockCount == 5)
        // And the embedded engine verifies its own output clean.
        let engine = EmbeddedEngine()
        let events = await collect(engine.run(try route(anchor: parPath, folder: dir)))
        let summary = try #require(finishedSummary(in: events))
        #expect(summary.stillMissing == 0)
    }

    // MARK: - Cancellation (ROADMAP exit criterion: the C++ stops cooperatively, fast)

    @Test func cancellationStopsTheBlockingEngineCallQuickly() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Big enough that verify takes real time: 256 MiB of incompressible data.
        let chunk = Data((0..<(1 << 20)).map { _ in UInt8.random(in: .min ... .max) })
        let big = dir.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        for _ in 0..<256 { try handle.write(contentsOf: chunk) }
        try handle.close()

        let parPath = dir.appendingPathComponent("big.par2")
        try Par2Create.createSet(
            parFile: parPath, files: [big], blockSize: 65536, recoveryBlockCount: 16)

        /// Flips the cancel flag at the first engine output, recording when, so the test can
        /// measure flag-to-return latency — the actual ROADMAP criterion.
        final class CancelAtFirstOutput: @unchecked Sendable {
            private let lock = NSLock()
            private var flagged: ContinuousClock.Instant?
            func noteOutput() {
                lock.lock()
                if flagged == nil { flagged = .now }
                lock.unlock()
            }
            var isCancelled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return flagged != nil
            }
            var flaggedAt: ContinuousClock.Instant? {
                lock.lock()
                defer { lock.unlock() }
                return flagged
            }
        }
        let controller = CancelAtFirstOutput()
        let context = Unmanaged.passUnretained(controller).toOpaque()

        let result = par2shim_repair(
            parPath.path, nil, nil, 0, 0, 0, 0,
            { context, _, _ in
                guard let context else { return }
                Unmanaged<CancelAtFirstOutput>.fromOpaque(context).takeUnretainedValue()
                    .noteOutput()
            }, context,
            { context in
                guard let context else { return 0 }
                return Unmanaged<CancelAtFirstOutput>.fromOpaque(context).takeUnretainedValue()
                    .isCancelled
                    ? 1 : 0
            }, context)
        let returnedAt = ContinuousClock.now

        #expect(result == PAR2SHIM_CANCELLED)
        let flaggedAt = try #require(controller.flaggedAt, "engine produced no output at all")
        let latency = flaggedAt.duration(to: returnedAt)
        #expect(latency < .seconds(2), "cancel-to-return took \(latency)")
    }

    @Test func cancelDuringRepairComputeIsSafeAndRerunnable() async throws {
        // Regression for the review's reproduced SIGSEGV: cancelling while ParPar compute is
        // in flight used to unwind Par2Repairer while worker threads still held its buffers
        // (fixed by the joining-deinit vendor patches). Cancel exactly when "Repairing:"
        // progress appears, assert the process survives and the run reports CANCELLED, then
        // run the repair again to completion on the same folder.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = Data((0..<(1 << 20)).map { _ in UInt8.random(in: .min ... .max) })
        let big = dir.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        for _ in 0..<128 { try handle.write(contentsOf: chunk) }
        try handle.close()
        let parPath = dir.appendingPathComponent("big.par2")
        try Par2Create.createSet(
            parFile: parPath, files: [big], blockSize: 65536, recoveryBlockCount: 128)
        let original = try Data(contentsOf: big)
        var damaged = original
        for block in 0..<100 {  // damage 100 blocks so repair compute has real work
            damaged[block * 65536] ^= 0xFF
        }
        try damaged.write(to: big)

        final class CancelAtRepairing: @unchecked Sendable {
            private let lock = NSLock()
            private var flagged = false
            func note(line: String) {
                if line.hasPrefix("Repairing:") {
                    lock.lock()
                    flagged = true
                    lock.unlock()
                }
            }
            var isCancelled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return flagged
            }
        }
        let controller = CancelAtRepairing()
        let context = Unmanaged.passUnretained(controller).toOpaque()
        let cancelled = par2shim_repair(
            parPath.path, nil, nil, 0, 0, 0, 1,
            { context, line, _ in
                guard let context, let line else { return }
                Unmanaged<CancelAtRepairing>.fromOpaque(context).takeUnretainedValue()
                    .note(line: String(cString: line))
            }, context,
            { context in
                guard let context else { return 0 }
                return Unmanaged<CancelAtRepairing>.fromOpaque(context).takeUnretainedValue()
                    .isCancelled
                    ? 1 : 0
            }, context)
        #expect(cancelled == PAR2SHIM_CANCELLED)

        // The same set must repair to completion on a fresh run: the interrupted repair left
        // the engine's "big.bin.1" rename behind, and EmbeddedEngine hands the folder's files
        // to the engine as extra files, so the renamed data is found and the repair completes.
        let engine = EmbeddedEngine()
        let events = await collect(engine.run(try route(anchor: parPath, folder: dir)))
        let summary = try #require(finishedSummary(in: events))
        #expect(summary.repaired == 1)
        #expect(try Data(contentsOf: big) == original)
    }

    // MARK: - One engine operation per process

    @Test func shimNeverRunsTwoEngineOperationsAtOnce() throws {
        // Regression: turbo's process-global tables initialize lazily behind unsynchronized
        // first-use guards, and two operations racing through them corrupted the GF(2^16)
        // reciprocal table (in this unoptimized test build, for the life of the process —
        // every later repair failed its verification). The first operation parks inside the
        // engine (its log callback blocks); a second one must not start until it returns.
        // Budgets are generous: both calls may first queue behind other tests' engine work.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("one-at-a-time-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var parFiles: [URL] = []
        var dataFiles: [URL] = []
        for name in ["first", "second"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = dir.appendingPathComponent("\(name).bin")
            try Data((0..<65536).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: data)
            dataFiles.append(data)
            parFiles.append(dir.appendingPathComponent("\(name).par2"))
        }

        final class Gate: @unchecked Sendable {
            let firstInside = DispatchSemaphore(value: 0)
            let releaseFirst = DispatchSemaphore(value: 0)
            let secondCalling = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var firstParked = false
            private var secondStartedFlag = false
            private var results: [Int: Par2ShimResult] = [:]
            func firstEmitted() {
                let park = lock.withLock {
                    defer { firstParked = true }
                    return !firstParked
                }
                if park {
                    firstInside.signal()
                    releaseFirst.wait()
                }
            }
            func secondEmitted() { lock.withLock { secondStartedFlag = true } }
            var secondStarted: Bool { lock.withLock { secondStartedFlag } }
            func record(_ index: Int, _ result: Par2ShimResult) {
                lock.withLock { results[index] = result }
            }
            func result(_ index: Int) -> Par2ShimResult? { lock.withLock { results[index] } }
        }
        let gate = Gate()
        let callbacks: [Par2ShimLogLine] = [
            { context, _, _ in
                guard let context else { return }
                Unmanaged<Gate>.fromOpaque(context).takeUnretainedValue().firstEmitted()
            },
            { context, _, _ in
                guard let context else { return }
                Unmanaged<Gate>.fromOpaque(context).takeUnretainedValue().secondEmitted()
            },
        ]
        let finished = DispatchGroup()
        func create(_ index: Int) {
            finished.enter()
            let parPath = parFiles[index].path
            let dataPath = dataFiles[index].path
            let callback = callbacks[index]
            Thread.detachNewThread {
                let context = Unmanaged.passUnretained(gate).toOpaque()
                let data = strdup(dataPath)
                defer { free(data) }
                var argv: [UnsafePointer<CChar>?] = [UnsafePointer(data)]
                if index == 1 { gate.secondCalling.signal() }
                let result = argv.withUnsafeMutableBufferPointer { buffer in
                    par2shim_create(
                        parPath, nil, buffer.baseAddress, 1, 4096, 4, PAR2SHIM_SCHEME_VARIABLE,
                        0, 0, 0, callback, context, nil, nil)
                }
                gate.record(index, result)
                finished.leave()
            }
        }

        create(0)
        guard gate.firstInside.wait(timeout: .now() + 300) == .success else {
            Issue.record("the first operation never produced engine output")
            gate.releaseFirst.signal()
            return
        }
        create(1)
        // Only once the second call is really being made does silence prove it is waiting.
        #expect(gate.secondCalling.wait(timeout: .now() + 60) == .success)
        Thread.sleep(forTimeInterval: 0.5)
        #expect(!gate.secondStarted, "a second engine operation ran alongside the first")
        gate.releaseFirst.signal()
        #expect(finished.wait(timeout: .now() + 300) == .success)
        #expect(gate.secondStarted)
        #expect(gate.result(0) == PAR2SHIM_SUCCESS)
        #expect(gate.result(1) == PAR2SHIM_SUCCESS)
    }

    @Test func streamTerminationTripsTheCancelToken() async throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = EmbeddedEngine()
        let stream = engine.run(
            try route(anchor: dir.appendingPathComponent("set.par2"), folder: dir))
        // Abandon after the first event — onTermination must cancel the engine run without
        // crashing or leaving the process wedged (the shim-level test above proves the C++
        // actually stops; this one proves the Swift plumbing connects).
        for await _ in stream { break }
        try await Task.sleep(for: .milliseconds(300))
    }
}
