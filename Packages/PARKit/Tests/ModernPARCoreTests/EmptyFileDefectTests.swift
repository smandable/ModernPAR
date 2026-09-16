import Foundation
import Par2Kit
import Testing

@testable import ModernPARCore

// MARK: - Synthesized packets

extension Par2Builder {
    /// A minimal index carrying Main + FileDesc + (optional) IFSC per member.
    ///
    /// Unlike `indexFile`, this emits the members in the order GIVEN rather than sorting them
    /// by File ID. Real sets are sorted, but the defect turns on which members come after an
    /// empty one in Main order, and sorting synthetic File IDs would leave that to chance.
    static func checksumIndex(
        sliceSize: UInt64,
        members: [(name: String, length: UInt64, slices: [Par2SliceChecksum]?)]
    ) -> Data {
        var seed: UInt8 = 0
        let built = members.map {
            member -> (desc: (body: Data, fileID: Data), slices: [Par2SliceChecksum]?) in
            seed += 1
            return (
                fileDesc(name: member.name, length: member.length, contentSeed: seed), member.slices
            )
        }
        let main = mainBody(sliceSize: sliceSize, recoveryIDs: built.map(\.desc.fileID))
        let setID = MD5Digest.hash(main).bytes
        var data = packet(type: Par2Parser.PacketType.main, setID: setID, body: main)
        for member in built {
            data.append(
                packet(
                    type: Par2Parser.PacketType.fileDescription, setID: setID,
                    body: member.desc.body))
            guard let slices = member.slices else { continue }
            var body = member.desc.fileID
            for slice in slices {
                body.append(slice.md5.bytes)
                body.append(le32(slice.crc32))
            }
            data.append(
                packet(
                    type: Par2Parser.PacketType.inputFileSliceChecksum, setID: setID, body: body))
        }
        return data
    }

    /// A slot the creator never filled in — the defect's signature.
    static var unwrittenSlice: Par2SliceChecksum {
        Par2SliceChecksum(md5: MD5Digest(bytes: Data(count: 16))!, crc32: 0)
    }

    /// A plausible real slice checksum (nothing here hashes to all zeros).
    static func slice(_ seed: UInt8) -> Par2SliceChecksum {
        Par2SliceChecksum(md5: MD5Digest.hash(Data([seed, 0x5A])), crc32: UInt32(seed) &+ 1)
    }
}

/// Recognizing — and refusing to repair against — a PAR2 set written by ModernPAR 1.0.1 or
/// earlier over a file list that included an empty file.
///
/// Those sets record shifted slice checksums (see `Fixtures/par2-empty-shift/readme.txt` and
/// `Par2EmptyFileDefect`). Creation is fixed, but the broken sets are already on people's
/// disks, and `Settings.autoRepair` defaults to true: opening one used to rename the intact
/// originals to `name.1`, write shifted copies over them, and end "Repair Failed." — on every
/// open. The parser now recognizes the shape and the app opens such a set read-only.
struct EmptyFileDefectTests {

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/par2-empty-shift")

    // MARK: - The real sets

    @Test func theSetModernPAR101WroteIsFlagged() throws {
        let set = try Par2Parser.loadSet(
            anchor: Self.fixtureDir.appendingPathComponent("affected/data.par2"))
        let defect = try #require(set.emptyFileDefect)

        #expect(defect.emptyMemberNames == ["empty-ae7"])
        // b.bin and a.bin both sort after the empty member, so both are shifted — in Main
        // order, which is the order the creator walked.
        #expect(defect.shiftedMemberNames == ["b.bin", "a.bin"])
        // One empty member ahead of the last non-empty one, so one slot went unwritten.
        #expect(defect.unwrittenSliceCount == 1)
        #expect(
            defect.explanation
                == "This recovery set was made by ModernPAR 1.0.1 or earlier, which recorded wrong checksums when a set included an empty file. Your files are most likely intact — make the set again."
        )
        #expect(defect.detail.contains("“empty-ae7”"))
        #expect(defect.detail.contains("“b.bin” and “a.bin”"))
        // The set is otherwise perfectly well-formed — this is not a corruption story.
        #expect(set.setIDVerified)
        #expect(set.corruptPacketCount == 0)
        #expect(set.creator == "Created by par2cmdline-turbo version 1.4.0.")
    }

    @Test func theSameSetFromTheCurrentEngineIsNotFlagged() throws {
        // Identical members, identical block size, identical recovery-block count — only the
        // engine differs. Nothing but the checksums can explain a different verdict.
        let set = try Par2Parser.loadSet(
            anchor: Self.fixtureDir.appendingPathComponent("fixed/data.par2"))
        #expect(set.emptyFileDefect == nil)
        #expect(set.recoveryFileIDs.count == 3)
        #expect(set.descriptions.values.contains { $0.length == 0 })
    }

    @Test func ordinarySetsAreNotFlagged() throws {
        let plain = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/par2cmdline/set.par2")
        #expect(try Par2Parser.loadSet(anchor: plain).emptyFileDefect == nil)
    }

    // MARK: - What separates a broken set from a sound one

    private func defect(
        _ members: [(name: String, length: UInt64, slices: [Par2SliceChecksum]?)]
    ) throws -> Par2EmptyFileDefect? {
        let dir = try Par2Builder.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Par2Builder.write(
            Par2Builder.checksumIndex(sliceSize: 4096, members: members), name: "s.par2", in: dir)
        return try Par2Parser.loadSet(anchor: url).emptyFileDefect
    }

    @Test func anEmptyMemberSortingLastShiftsNothing() throws {
        // The engine writes this one correctly: no member comes after the empty one, so no
        // checksum moves and no slot is left unwritten. Flagging it would be a false alarm on
        // a set that verifies clean.
        let found = try defect([
            ("a.bin", 8192, [Par2Builder.slice(1), Par2Builder.slice(2)]),
            ("empty", 0, nil),
        ])
        #expect(found == nil)
    }

    @Test func anEmptyMemberWithSoundChecksumsIsNotFlagged() throws {
        // The multi-pass path (blocks over 32 MiB) writes correct checksums even with an empty
        // member ahead of the data. Requiring the unwritten slots is what keeps those sets out.
        let found = try defect([
            ("empty", 0, nil),
            ("a.bin", 8192, [Par2Builder.slice(1), Par2Builder.slice(2)]),
        ])
        #expect(found == nil)
    }

    @Test func unwrittenSlotsWithoutAnEmptyMemberAreNotFlagged() throws {
        // Zero entries with nothing to explain them are some other problem; this diagnosis
        // would be a guess, and the advice ("make the set again") might be wrong.
        let found = try defect([
            ("a.bin", 8192, [Par2Builder.slice(1), Par2Builder.unwrittenSlice])
        ])
        #expect(found == nil)
    }

    @Test func moreUnwrittenSlotsThanEmptyMembersIsNotFlagged() throws {
        let found = try defect([
            ("empty", 0, nil),
            (
                "a.bin", 12288,
                [Par2Builder.slice(1), Par2Builder.unwrittenSlice, Par2Builder.unwrittenSlice]
            ),
        ])
        #expect(found == nil)
    }

    @Test func zeroEntriesInTheMiddleAreNotTheSignature() throws {
        // The creator runs out of blocks at the END. A zero entry anywhere else is not this.
        let found = try defect([
            ("empty", 0, nil),
            (
                "a.bin", 12288,
                [Par2Builder.slice(1), Par2Builder.unwrittenSlice, Par2Builder.slice(2)]
            ),
        ])
        #expect(found == nil)
    }

    @Test func aMemberBeforeTheEmptyOneIsNotReportedAsShifted() throws {
        // Empirically confirmed on a real set: a member sorting BEFORE the empty one keeps
        // correct checksums and still verifies.
        let found = try #require(
            try defect([
                ("first.bin", 4096, [Par2Builder.slice(1)]),
                ("empty", 0, nil),
                ("last.bin", 8192, [Par2Builder.slice(2), Par2Builder.unwrittenSlice]),
            ]))
        #expect(found.shiftedMemberNames == ["last.bin"])
        #expect(found.emptyMemberNames == ["empty"])
    }

    @Test func twoEmptyMembersLeaveTwoUnwrittenSlots() throws {
        let found = try #require(
            try defect([
                ("e1", 0, nil),
                ("e2", 0, nil),
                (
                    "a.bin", 12288,
                    [Par2Builder.slice(1), Par2Builder.unwrittenSlice, Par2Builder.unwrittenSlice]
                ),
            ]))
        #expect(found.unwrittenSliceCount == 2)
        #expect(found.emptyMemberNames == ["e1", "e2"])
        #expect(found.detail.contains("“e1” and “e2”"))
    }

    @Test func fewerBlocksThanEmptyMembersStillFlags() throws {
        // A last member with only one block cannot show two unwritten slots, so the count is
        // capped by its block count — pinned against a real set built this way.
        let found = try #require(
            try defect([
                ("e1", 0, nil),
                ("e2", 0, nil),
                ("tiny.bin", 4096, [Par2Builder.unwrittenSlice]),
            ]))
        #expect(found.unwrittenSliceCount == 1)
    }

    @Test func aMemberWithNoSurvivingDescriptionCannotInventADefect() throws {
        // Main lists a File ID with no FileDesc: its length is unknowable, so it neither
        // proves nor disproves anything. The parser already warns about the missing packet.
        let dir = try Par2Builder.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var index = Par2Builder.checksumIndex(
            sliceSize: 4096,
            members: [
                ("ghost", 0, nil),
                ("a.bin", 8192, [Par2Builder.slice(1), Par2Builder.unwrittenSlice]),
            ])
        // Drop the first FileDesc packet (the empty member's) from the index bytes.
        let descTag = Par2Parser.PacketType.fileDescription
        let start = try #require(index.range(of: descTag)).lowerBound - 48
        let length = try #require(index.leUInt64(at: start - index.startIndex + 8))
        index.removeSubrange(start..<(start + Int(length)))

        let url = try Par2Builder.write(index, name: "s.par2", in: dir)
        let set = try Par2Parser.loadSet(anchor: url)
        #expect(set.missingDescriptionIDs.count == 1)
        #expect(set.emptyFileDefect == nil)
    }
}

// MARK: - The session refuses to repair against such a set

@MainActor
struct EmptyFileDefectSessionTests {

    /// A copy of the affected fixture, so nothing a test does touches the committed files.
    private func stageAffectedSet() throws -> URL {
        let source = EmptyFileDefectTests.fixtureDir.appendingPathComponent("affected")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emptyshift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil)
        {
            try FileManager.default.copyItem(
                at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
        return dir
    }

    private func dataFiles(in dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in ["a.bin", "b.bin", "empty-ae7"] {
            out[name] = try Data(contentsOf: dir.appendingPathComponent(name))
        }
        return out
    }

    /// Generous on purpose: the tests below drive the REAL in-process engine, and every engine
    /// operation in the process now queues on the Par2Shim mutex, so this run can sit behind
    /// another suite's multi-hundred-megabyte create. A 15 s budget passed locally and failed
    /// the v1.1.0 release on a 3 vCPU runner, where the same test took 85 s. A genuinely stuck
    /// run still fails long before the CI step's 20-minute timeout.
    private func waitUntilIdle(_ session: OperationSession) async throws {
        for _ in 0..<9600 where session.isBusy {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!session.isBusy, "session still busy after 240 s")
    }

    /// Engine scripted to report exactly what the real one reports for this set: damage on
    /// intact files, repairable. Lets the test assert what route the session handed it.
    private final class RecordingEngine: PAR2Engine, @unchecked Sendable {
        private(set) var runCount = 0
        private(set) var lastRoute: SessionRoute?
        func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
            runCount += 1
            lastRoute = route
            return AsyncStream { continuation in
                continuation.yield(.docStatusChanged(.repairNeeded))
                continuation.yield(.finished(.success(OperationSummary())))
                continuation.finish()
            }
        }
    }

    @Test func openingSuchASetNeverStartsTheAutomaticRepair() async throws {
        let dir = try stageAffectedSet()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try dataFiles(in: dir)

        let engine = RecordingEngine()
        let session = OperationSession()
        // The shipping default: Settings.autoRepair is true, so this is the path every user
        // with one of these sets took.
        session.open(
            dir.appendingPathComponent("data.par2"), thenVerifyUsing: engine, autoRepair: true)
        try await waitUntilIdle(session)

        #expect(engine.runCount == 0)
        #expect(session.docStatus == .unreliableChecksums)
        #expect(session.emptyFileDefect?.emptyMemberNames == ["empty-ae7"])
        #expect(session.parSet?.files.count == 3)  // the set still opens and lists its files
        #expect(try dataFiles(in: dir) == before)
        // The window says so plainly rather than leaving the user to guess.
        let defect = try #require(session.emptyFileDefect)
        #expect(session.log.contains(defect.explanation))
        #expect(session.log.contains(defect.detail))
        // The multi-open queue must still be released, or every window behind this one waits
        // forever. (MultiOpenQueue settle contract)
        #expect(session.runEnded == 1)
    }

    @Test func anExplicitRepairRequestIsDowngradedToAVerify() async throws {
        let dir = try stageAffectedSet()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = RecordingEngine()
        let session = OperationSession()
        session.open(dir.appendingPathComponent("data.par2"))
        try await waitUntilIdle(session)

        // Toolbar "Repair", Operation ▸ Repair Again, or a restored route asking for one.
        session.requestVerify(using: engine, autoRepair: true)
        try await waitUntilIdle(session)

        #expect(engine.runCount == 1)
        #expect(engine.lastRoute?.autoRepair == false)
        #expect(session.log.contains { $0.contains("Repair was not started") })
    }

    @Test func theRealEngineNeverRewritesTheFiles() async throws {
        let dir = try stageAffectedSet()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try dataFiles(in: dir)

        // The real in-process engine, with auto-repair on. Without the guard this run renames
        // a.bin/b.bin to a.bin.1/b.bin.1, writes shifted copies over the originals, and ends
        // "Repair Failed." — the failure this whole change exists to prevent.
        let session = OperationSession()
        session.open(
            dir.appendingPathComponent("data.par2"),
            thenVerifyUsing: EmbeddedEngine(), autoRepair: true)
        try await waitUntilIdle(session)

        #expect(session.docStatus == .unreliableChecksums)
        #expect(try dataFiles(in: dir) == before)
        let names = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        #expect(!names.contains { $0.hasSuffix(".1") })
    }

    @Test func anExplicitVerifyRunsTheRealEngineWithoutTouchingTheData() async throws {
        let dir = try stageAffectedSet()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try dataFiles(in: dir)

        let session = OperationSession()
        session.open(dir.appendingPathComponent("data.par2"))
        try await waitUntilIdle(session)
        // Asking the real engine to repair: it runs — verification is read-only and the user
        // is entitled to see the verdict — but it is handed a verify-only route.
        session.requestVerify(using: EmbeddedEngine(), autoRepair: true)
        try await waitUntilIdle(session)

        // The engine really did run against this set (it reports the shifted checksums as
        // damage), and the data survived it byte for byte.
        #expect(session.docStatus == .repairNeeded)
        #expect(try dataFiles(in: dir) == before)
        let names = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        #expect(!names.contains { $0.hasSuffix(".1") })
    }
}
