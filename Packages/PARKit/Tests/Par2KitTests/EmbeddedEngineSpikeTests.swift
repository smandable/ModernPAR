import Foundation
import Par2Cxx
import Testing

/// Phase 2 spike exit criteria (ROADMAP): prove Swift calls through the Par2Shim C ABI into the
/// vendored par2cmdline-turbo engine — version string, a real verify, and a real repair on the
/// golden fixture set. The engine is the same code the `par2` CLI runs, so results must match.
struct EmbeddedEngineSpikeTests {

    /// Thread-safe log sink for the shim's C callback (engine worker threads call it).
    final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }
        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// Golden fixtures live in ModernPARCoreTests; reach them via #filePath (spike-grade
    /// plumbing — a shared fixture target can come with the full engine work).
    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Par2KitTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("ModernPARCoreTests/Fixtures/par2cmdline")

    private func stageFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spike-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(
            at: Self.fixtureDir, includingPropertiesForKeys: nil)
        {
            try FileManager.default.copyItem(
                at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
        return dir
    }

    private func runShim(anchor: URL, repair: Bool, sink: LogSink) -> Par2ShimResult {
        let context = Unmanaged.passUnretained(sink).toOpaque()
        return par2shim_repair(
            anchor.path, nil, nil, 0, 0, 0, repair ? 1 : 0,
            { context, line, _ in
                guard let context, let line else { return }
                Unmanaged<LogSink>.fromOpaque(context).takeUnretainedValue()
                    .append(String(cString: line))
            }, context, nil, nil)
    }

    @Test func linkedEngineReportsPinnedVersion() {
        #expect(String(cString: par2shim_version()) == "par2cmdline-turbo 1.4.0")
    }

    @Test func verifyIntactGoldenSetSucceeds() throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = LogSink()
        let result = runShim(
            anchor: dir.appendingPathComponent("set.par2"), repair: false, sink: sink)
        #expect(result == PAR2SHIM_SUCCESS)
        #expect(sink.lines.contains { $0.contains("All files are correct") })
    }

    @Test func damagedSetVerifiesAsRepairableThenRepairs() throws {
        let dir = try stageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = dir.appendingPathComponent("file-a.bin")
        let original = try Data(contentsOf: victim)
        var damaged = original
        for i in 0..<500 { damaged[i] ^= 0xFF }  // wreck half a block
        try damaged.write(to: victim)

        let verifySink = LogSink()
        let verdict = runShim(
            anchor: dir.appendingPathComponent("set.par2"), repair: false, sink: verifySink)
        #expect(verdict == PAR2SHIM_REPAIR_POSSIBLE)
        #expect(verifySink.lines.contains { $0.contains("Repair is possible") })

        let repairSink = LogSink()
        let outcome = runShim(
            anchor: dir.appendingPathComponent("set.par2"), repair: true, sink: repairSink)
        #expect(outcome == PAR2SHIM_SUCCESS)
        #expect(try Data(contentsOf: victim) == original)  // byte-identical restoration
    }

    @Test func missingPar2FileFailsCleanlyThroughTheCABI() {
        let sink = LogSink()
        let result = runShim(
            anchor: FileManager.default.temporaryDirectory
                .appendingPathComponent("does-not-exist-\(UUID().uuidString).par2"),
            repair: false, sink: sink)
        // Must come back as an error code — never a C++ exception across the boundary.
        #expect(result != PAR2SHIM_SUCCESS)
        #expect(result != PAR2SHIM_CXX_EXCEPTION)
    }
}
