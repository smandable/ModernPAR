import Foundation
import ModernPARCore
import Par2Cxx
import Testing

@testable import Par2Kit

/// Regression tests for PAR2 create with empty (0-byte) files at the engine level
/// (VENDORED.txt patch 6). The par2 CLI skips 0-byte files, but `par2shim_create` hands its
/// list straight to turbo's `par2create()`, where an empty file sorting (by File ID) before a
/// non-empty one wrote past the end of its 0-entry verification packet and shifted every later
/// block and file hash — the new set reported intact data as damaged. The app's own create
/// path skips empty files (EmbeddedCreateTests); these drive the shim directly so the engine
/// fix itself stays covered.
struct EmptyFileCreateTests {

    /// An empty file with this name has a File ID whose two most significant bytes are zero
    /// (PAR2 orders File IDs as little-endian 128-bit integers), so it sorts before the other
    /// files: the ordering that triggered the bug. Tests re-check the order they rely on.
    private static let firstSortingEmptyName = "empty-ae7"

    /// Deterministic contents, so File IDs — and with them the set's file order — are stable.
    private func pattern(_ size: Int, seed: UInt32) -> Data {
        var state = seed
        return Data(
            (0..<size).map { _ in
                state = state &* 1_664_525 &+ 1_013_904_223
                return UInt8(truncatingIfNeeded: state >> 24)
            })
    }

    private func makeFolder(_ files: [(String, Int)]) throws -> (dir: URL, urls: [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emptycreate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, (name, size)) in files.enumerated() {
            let url = dir.appendingPathComponent(name)
            try pattern(size, seed: UInt32(index + 1)).write(to: url)
            urls.append(url)
        }
        return (dir, urls)
    }

    /// Collects the engine's output lines. `onLine` runs synchronously on the engine thread
    /// that printed the line — used to change a file at an exact point of a create.
    private final class EngineOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [String] = []
        private let onLine: (@Sendable (String) -> Void)?

        init(onLine: (@Sendable (String) -> Void)? = nil) {
            self.onLine = onLine
        }

        func append(_ line: String) {
            lock.withLock { collected.append(line) }
            onLine?(line)
        }

        var lines: [String] { lock.withLock { collected } }
    }

    /// Direct shim calls queue on the engines' serial queue, like EmbeddedEngine's runs: turbo
    /// supports one operation per process at a time (its first-use initializers race), so
    /// these must never overlap another test's engine work, whether or not the shim also
    /// serializes itself.
    private func onEngineQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            EngineRunSupport.serialQueue.async { continuation.resume(returning: body()) }
        }
    }

    /// `par2shim_create` with 4 KiB blocks and 4 recovery blocks.
    private func shimCreate(
        parFile: URL,
        files: [URL],
        scheme: Par2ShimScheme = PAR2SHIM_SCHEME_UNIFORM,
        memoryLimit: Int = 0,
        output: EngineOutput = EngineOutput()
    ) async -> Par2ShimResult {
        let parPath = parFile.path
        let paths = files.map(\.path)
        return await onEngineQueue {
            let argv: [UnsafePointer<CChar>?] = paths.map { UnsafePointer(strdup($0)) }
            defer {
                for pointer in argv { free(UnsafeMutablePointer(mutating: pointer)) }
            }
            let context = Unmanaged.passUnretained(output).toOpaque()
            return argv.withUnsafeBufferPointer { buffer in
                par2shim_create(
                    parPath, nil, buffer.baseAddress, paths.count, 4096, 4, scheme, 0, 0,
                    memoryLimit,
                    { context, line, _ in
                        guard let context, let line else { return }
                        Unmanaged<EngineOutput>.fromOpaque(context).takeUnretainedValue()
                            .append(String(cString: line))
                    }, context, nil, nil)
            }
        }
    }

    /// Verify only (no repair), the way EmbeddedEngine runs the shim.
    private func shimVerify(parFile: URL, output: EngineOutput = EngineOutput()) async
        -> Par2ShimResult
    {
        let parPath = parFile.path
        return await onEngineQueue {
            let context = Unmanaged.passUnretained(output).toOpaque()
            return par2shim_repair(
                parPath, nil, nil, 0, 0, 0, 0,
                { context, line, _ in
                    guard let context, let line else { return }
                    Unmanaged<EngineOutput>.fromOpaque(context).takeUnretainedValue()
                        .append(String(cString: line))
                }, context, nil, nil)
        }
    }

    /// Recovery-set member lengths in the set's canonical (File ID) order.
    private func memberLengths(of parFile: URL) throws -> [UInt64?] {
        let set = try Par2Parser.loadSet(anchor: parFile)
        return set.recoveryFileIDs.map { set.descriptions[$0]?.length }
    }

    /// Recomputes `url`'s slice MD5s (the last slice zero-padded) and whole-file MD5 and
    /// compares them with what the set recorded — exactly the checksums the bug shifted —
    /// without going through any verifier.
    private func recordedChecksumsMatch(_ url: URL, in parFile: URL) throws -> Bool {
        let set = try Par2Parser.loadSet(anchor: parFile)
        let data = try Data(contentsOf: url)
        guard
            let id = set.recoveryFileIDs.first(where: {
                set.descriptions[$0]?.asciiName == url.lastPathComponent
            }),
            let description = set.descriptions[id], let slices = set.sliceChecksums[id]
        else { return false }
        let block = Int(set.sliceSize)
        let expected = stride(from: 0, to: data.count, by: block).map { offset -> MD5Digest in
            var slice = data.subdata(in: offset..<min(offset + block, data.count))
            slice.append(Data(count: block - slice.count))
            return MD5Digest.hash(slice)
        }
        return description.fileMD5 == MD5Digest.hash(data) && slices.map(\.md5) == expected
    }

    // MARK: - Checksums

    @Test func anEmptyFileSortingFirstNoLongerCorruptsTheSet() async throws {
        // The default path: single pass with deferred hashing (blocks up to 32 MiB whose
        // recovery data fits the memory limit). Before the fix this set verified as damaged
        // every time: "Target: "a.bin" - damaged. Found 9 of 10 data blocks."
        let (dir, urls) = try makeFolder([
            ("a.bin", 40960), ("b.bin", 20000), (Self.firstSortingEmptyName, 0),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("set.par2")

        let created = EngineOutput()
        let result = await shimCreate(parFile: parFile, files: urls, output: created)
        try #require(result == PAR2SHIM_SUCCESS, "\(created.lines.joined(separator: "\n"))")
        let lengths = try memberLengths(of: parFile)
        try #require(
            lengths.count == 3 && lengths.first == 0,
            "the empty member must sort first to exercise the bug (got \(lengths))")
        #expect(try recordedChecksumsMatch(urls[0], in: parFile))
        #expect(try recordedChecksumsMatch(urls[1], in: parFile))

        let verified = EngineOutput()
        #expect(
            await shimVerify(parFile: parFile, output: verified) == PAR2SHIM_SUCCESS,
            "\(verified.lines.joined(separator: "\n"))")
        // An empty member has no slices, so turbo checks it by whole-file hash instead.
        #expect(
            verified.lines.contains {
                $0.hasSuffix(" is a perfect match for \(Self.firstSortingEmptyName)")
            })
    }

    @Test func anEmptyFileSortingBetweenOthersNoLongerCorruptsTheSet() async throws {
        // The empty member sits between the two data files, so the fix's second step-over (the
        // one after each file is finished) is the one that has to skip it.
        let (dir, urls) = try makeFolder([("a.bin", 40960), ("b.bin", 20000), ("empty-mid-3", 0)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("set.par2")

        let created = EngineOutput()
        let result = await shimCreate(parFile: parFile, files: urls, output: created)
        try #require(result == PAR2SHIM_SUCCESS, "\(created.lines.joined(separator: "\n"))")
        let lengths = try memberLengths(of: parFile)
        try #require(lengths == [20000, 0, 40960], "unexpected member order \(lengths)")
        #expect(try recordedChecksumsMatch(urls[0], in: parFile))
        #expect(try recordedChecksumsMatch(urls[1], in: parFile))

        let verified = EngineOutput()
        #expect(
            await shimVerify(parFile: parFile, output: verified) == PAR2SHIM_SUCCESS,
            "\(verified.lines.joined(separator: "\n"))")
    }

    @Test func adjacentEmptyFilesAreAllSteppedOver() async throws {
        // Two empty members in a row: the step-over must skip every one of them, not just the
        // first. (No verify here: PAR2 readers can't tell two empty members apart and report a
        // false "wrong name" — the reason the app leaves empty files out. The recorded
        // checksums are compared directly instead.)
        let (dir, urls) = try makeFolder([
            ("a.bin", 40960), ("b.bin", 20000), ("empty-mid-14", 0), ("empty-mid-22", 0),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("set.par2")

        let created = EngineOutput()
        let result = await shimCreate(parFile: parFile, files: urls, output: created)
        try #require(result == PAR2SHIM_SUCCESS, "\(created.lines.joined(separator: "\n"))")
        let lengths = try memberLengths(of: parFile)
        try #require(lengths == [20000, 0, 0, 40960], "unexpected member order \(lengths)")
        #expect(try recordedChecksumsMatch(urls[0], in: parFile))
        #expect(try recordedChecksumsMatch(urls[1], in: parFile))
    }

    @Test func anEmptyFileOnTheMultiPassPathVerifiesClean() async throws {
        // A tiny memory limit forces chunks smaller than a block: the non-deferred path (the
        // app reaches it with blocks over 32 MiB, or recovery data beyond the memory limit).
        // Par2CreatorSourceFile::Open used to "finish" a last block for a file that has none.
        // That overflow is silent without ASan, so the patch also makes SetBlockHashAndCRC
        // throw on an out-of-range block; with only the Open() guard reverted, this create
        // fails as PAR2SHIM_CXX_EXCEPTION.
        let (dir, urls) = try makeFolder([
            ("a.bin", 40960), ("b.bin", 20000), (Self.firstSortingEmptyName, 0),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("set.par2")

        let created = EngineOutput()
        let result = await shimCreate(
            parFile: parFile, files: urls, memoryLimit: 8192, output: created)
        try #require(result == PAR2SHIM_SUCCESS, "\(created.lines.joined(separator: "\n"))")
        // One "Wrote N bytes to disk" line per pass: proof the multi-pass path ran.
        try #require(created.lines.filter { $0.hasPrefix("Wrote ") }.count > 1)
        let lengths = try memberLengths(of: parFile)
        try #require(
            lengths.count == 3 && lengths.contains(0), "the empty member must be in the set")

        let verified = EngineOutput()
        #expect(
            await shimVerify(parFile: parFile, output: verified) == PAR2SHIM_SUCCESS,
            "\(verified.lines.joined(separator: "\n"))")
    }

    // MARK: - Guards

    @Test func aSetWithNoDataIsRefusedWithoutLeavingFiles() async throws {
        // Every file empty: upstream divided by the largest file size (0) sizing LIMITED
        // volumes and then collided on output names; the other schemes wrote a useless
        // 0-source-block set. The engine now refuses before writing anything.
        for scheme in [PAR2SHIM_SCHEME_VARIABLE, PAR2SHIM_SCHEME_LIMITED, PAR2SHIM_SCHEME_UNIFORM] {
            let (dir, urls) = try makeFolder([("e1", 0), ("e2", 0)])
            defer { try? FileManager.default.removeItem(at: dir) }
            let output = EngineOutput()
            let result = await shimCreate(
                parFile: dir.appendingPathComponent("set.par2"), files: urls, scheme: scheme,
                output: output)
            #expect(result == PAR2SHIM_INVALID_ARGS, "scheme \(scheme.rawValue)")
            #expect(output.lines.contains { $0.contains("every source file is empty") })
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.lowercased().hasSuffix(".par2") }
            #expect(leftovers.isEmpty, "scheme \(scheme.rawValue) left \(leftovers)")
        }
    }

    // "Opening: <name>" is printed after the engine's first size read of that file
    // (ComputeBlockCount) and just before its second one (Par2CreatorSourceFile::Open), so
    // changing the file from the log callback lands exactly in that window — the window a
    // download still being written can hit. The block counts no longer add up; the engine now
    // refuses instead of building the set on top of them.

    @Test func aFileThatEmptiesMidCreateFailsCleanly() async throws {
        // Before the fix: source blocks with no DiskFile, a NULL dereference in ProcessData.
        let (dir, urls) = try makeFolder([("a.bin", 40960), ("b.bin", 20000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = urls[1]
        let output = EngineOutput { line in
            if line == "Opening: b.bin" { try? Data().write(to: victim) }
        }
        let result = await shimCreate(
            parFile: dir.appendingPathComponent("set.par2"), files: urls, output: output)
        #expect(result == PAR2SHIM_FILE_IO_ERROR, "\(output.lines.joined(separator: "\n"))")
        #expect(output.lines.contains { $0.contains("changed size") })
    }

    @Test func aFileThatGrowsFromEmptyMidCreateFailsCleanly() async throws {
        // Before the fix: InitialiseSourceBlocks wrote past the end of sourceblocks.
        let (dir, urls) = try makeFolder([("a.bin", 40960), ("grows.bin", 0)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = urls[1]
        let output = EngineOutput { line in
            if line == "Opening: grows.bin" { try? Data(count: 12288).write(to: victim) }
        }
        let result = await shimCreate(
            parFile: dir.appendingPathComponent("set.par2"), files: urls, output: output)
        #expect(result == PAR2SHIM_FILE_IO_ERROR, "\(output.lines.joined(separator: "\n"))")
        #expect(output.lines.contains { $0.contains("changed size") })
    }

    // Later, the engine reads every file again for the recovery data — once, or once per pass
    // in a multi-pass create. A file whose size changed by then used to be encoded truncated
    // or zero-filled, and the create "succeeded" with a set that could not verify or repair.

    @Test func aFileThatChangesSizeBeforeItIsReadFailsCleanly() async throws {
        // Single pass: "Processing:" is printed once the first block (of b.bin, which sorts
        // first) is in; a.bin has not been read yet.
        let (dir, urls) = try makeFolder([("a.bin", 40960), ("b.bin", 20000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = urls[0]
        let output = EngineOutput { line in
            if line.hasPrefix("Processing:") { try? Data(count: 50000).write(to: victim) }
        }
        let result = await shimCreate(
            parFile: dir.appendingPathComponent("set.par2"), files: urls, output: output)
        #expect(result == PAR2SHIM_FILE_IO_ERROR, "\(output.lines.joined(separator: "\n"))")
        #expect(output.lines.contains { $0.contains("changed size") })
    }

    @Test func aFileThatChangesSizeBetweenPassesFailsCleanly() async throws {
        // Multi-pass: "Wrote N bytes to disk" ends each pass, with every source file closed.
        let (dir, urls) = try makeFolder([("a.bin", 40960), ("b.bin", 20000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = urls[1]
        let output = EngineOutput { line in
            if line.hasPrefix("Wrote ") { try? Data(count: 30000).write(to: victim) }
        }
        let result = await shimCreate(
            parFile: dir.appendingPathComponent("set.par2"), files: urls, memoryLimit: 8192,
            output: output)
        #expect(result == PAR2SHIM_FILE_IO_ERROR, "\(output.lines.joined(separator: "\n"))")
        #expect(output.lines.contains { $0.contains("changed size") })
    }

    // MARK: - Verify/repair extra files

    @Test func emptyFilesAreNotPassedToTheEngineAsExtraFiles() throws {
        // turbo's scan of a 0-byte extra file returns without setting its match result (an
        // uninitialized read); the CLI never passes one. PAR metadata and folders stay out too.
        let (dir, _) = try makeFolder([
            ("data.bin", 1000), ("empty.bin", 0), ("set.par2", 100), ("old.par", 10),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let extras = EngineRunSupport.extraFiles(near: dir.appendingPathComponent("set.par2"))
        #expect(extras.map(\.lastPathComponent) == ["data.bin"])
    }

    @Test func aSetWithAnEmptyMemberReadsCleanThroughTheAppEngine() async throws {
        // The app's own create skips empty files, but a set that HAS one — made through the
        // shim, or by another tool — must still read as clean end to end: the engine checks the
        // empty member by whole-file hash, so the parser settles that row OK (not a blank
        // status, and not damaged) and gives it no "Blocks needed" count.
        let (dir, urls) = try makeFolder([
            ("a.bin", 40960), ("b.bin", 20000), (Self.firstSortingEmptyName, 0),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let parFile = dir.appendingPathComponent("set.par2")
        let created = EngineOutput()
        try #require(
            await shimCreate(parFile: parFile, files: urls, output: created) == PAR2SHIM_SUCCESS,
            "\(created.lines.joined(separator: "\n"))")

        let route = SessionRoute(
            mode: .verifyRepair, folderBookmark: try? ScopedAccess.bookmark(for: dir),
            anchorBookmark: try ScopedAccess.bookmark(for: parFile))
        var events: [EngineEvent] = []
        for await event in EmbeddedEngine(repairsAutomatically: false).run(route) {
            events.append(event)
        }

        let set = try Par2Parser.loadSet(anchor: parFile)
        let emptyID = try #require(
            set.descriptions.values.first { $0.preferredName == Self.firstSortingEmptyName }?
                .fileID.uuid)
        var statuses: [UUID: FileStatus] = [:]
        for case .fileStatusChanged(let id, let status) in events { statuses[id] = status }
        #expect(statuses[emptyID] == .ok)
        #expect(
            !events.contains {
                if case .fileBlocksNeeded(let id, _) = $0 { return id == emptyID }
                return false
            })
        #expect(
            events.contains {
                if case .docStatusChanged(.allFilesOK) = $0 { return true }
                return false
            })
    }
}
