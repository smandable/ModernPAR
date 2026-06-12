import Foundation
import ModernPARCore
import Testing

@testable import ArchiveKit

/// Regression tests for the confirmed findings of the Phase 4 adversarial review — each test
/// names the failure it pins. (See Fixtures/rar/README.md for the fixture recipes.)
struct ReviewRegressionTests {

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/rar")

    private func stage(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unrar-rr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.copyItem(
                at: Self.fixtureDir.appendingPathComponent(name),
                to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func runExtract(
        anchor: String, in folder: URL, password: String? = nil,
        conflicts: ConflictPolicy = .cancel
    ) async throws -> [EngineEvent] {
        let route = SessionRoute(
            mode: .extractArchive,
            folderBookmark: try? ScopedAccess.bookmark(for: folder),
            anchorBookmark: try ScopedAccess.bookmark(
                for: folder.appendingPathComponent(anchor)))
        let stream = RARExtractor().extract(
            route, options: ExtractOptions(),
            password: CountingPasswordProvider(password),
            conflicts: AutoConflictResolver(conflicts))
        var events: [EngineEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func finalError(_ events: [EngineEvent]) -> EngineError? {
        for event in events.reversed() {
            if case .finished(.failure(let error)) = event { return error }
        }
        return nil
    }

    private func succeeded(_ events: [EngineEvent]) -> Bool {
        for event in events.reversed() {
            if case .finished(let result) = event {
                if case .success = result { return true }
                return false
            }
        }
        return false
    }

    private func placed(_ events: [EngineEvent]) -> URL? {
        for event in events {
            if case .extractionPlaced(let url) = event { return url }
        }
        return nil
    }

    private func statusCounts(_ events: [EngineEvent]) -> (ok: Int, bad: Int, skipped: Int) {
        var ok = 0
        var bad = 0
        var skipped = 0
        for event in events {
            if case .fileStatusChanged(_, let status) = event {
                if status == .ok { ok += 1 }
                if status == .unrecoverableCorrupt { bad += 1 }
                if status == .notInSet { skipped += 1 }
            }
        }
        return (ok, bad, skipped)
    }

    // Finding: "stale Cmd.DllError aborts the keep-extracting loop" (HIGH). The two intact
    // files AFTER the corrupt middle entry must extract and be reported.
    @Test func corruptMiddleFileDoesNotAbortTheRestOfTheArchive() async throws {
        let folder = try stage(["corrupt-middle.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(anchor: "corrupt-middle.rar", in: folder)

        guard case .engine(let code, _)? = finalError(events) else {
            Issue.record(
                "expected damaged-data failure, got \(String(describing: finalError(events)))")
            return
        }
        #expect(code == 12)  // BAD_DATA — the run still reports the damage
        let counts = statusCounts(events)
        #expect(counts.ok == 3, "intact files must extract; got ok=\(counts.ok)")
        #expect(counts.bad == 1)
        guard let out = placed(events) else {
            Issue.record("intact files must be placed")
            return
        }
        // The two files AFTER the corrupt entry are the regression's core assertion.
        #expect(
            FileManager.default.fileExists(
                atPath: out.appendingPathComponent("dir1/file1.txt").path))
        #expect(
            FileManager.default.fileExists(
                atPath: out.appendingPathComponent("üȵĩöḋè/file.txt").path)
                || FileManager.default.fileExists(
                    atPath: out.appendingPathComponent(
                        "üȵĩöḋè".precomposedStringWithCanonicalMapping + "/file.txt"
                    ).path)
        )
    }

    // Finding: "sticky RARX_WARNING becomes ERAR_UNKNOWN and fails the whole extraction"
    // (HIGH). The unsafe `../random123` symlink is skipped with a warning; everything else
    // extracts and the run SUCCEEDS.
    @Test func unsafeSymlinkIsSkippedWithoutFailingTheRun() async throws {
        let folder = try stage(["rar5-symlink-unix.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(anchor: "rar5-symlink-unix.rar", in: folder)

        #expect(succeeded(events), "got \(String(describing: finalError(events)))")
        guard let out = placed(events) else {
            Issue.record("output must be placed")
            return
        }
        let dataFile = out.appendingPathComponent("data.txt")
        #expect(FileManager.default.fileExists(atPath: dataFile.path))
        // The unsafe link must not exist anywhere in the output.
        #expect(
            !FileManager.default.fileExists(
                atPath: out.appendingPathComponent("random_link").path))
        #expect(statusCounts(events).skipped >= 1)
    }

    // Finding: vendor patch 1 must not mask GENUINE RAR3 header corruption.
    @Test func corruptRAR3HeaderIsReportedAsDamage() async throws {
        let folder = try stage(["corrupt-header3.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(anchor: "corrupt-header3.rar", in: folder)
        #expect(!succeeded(events), "header corruption must not read as success")
        #expect(finalError(events) != .badPassword)  // no password involved
    }

    // Finding: vendor patch 2 must report truncation INSIDE a header as damage, not as a
    // clean end-of-archive.
    @Test func truncationInsideAHeaderIsNotACleanEnd() async throws {
        let folder = try stage(["truncated-header.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(anchor: "truncated-header.rar", in: folder)
        #expect(!succeeded(events), "mid-header truncation must not read as success")
    }

    // Finding: "RAR5 corrupt encrypted data is misdiagnosed as wrong password" (the re-prompt
    // loop trap). With the CORRECT password, damage must surface as damage.
    @Test func corruptEncryptedRAR5WithCorrectPasswordIsDataDamageNotBadPassword() async throws {
        let folder = try stage(["corrupt-encrypted.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(
            anchor: "corrupt-encrypted.rar", in: folder, password: "password")

        guard case .engine(let code, _)? = finalError(events) else {
            Issue.record(
                "expected damaged-data failure, got \(String(describing: finalError(events)))")
            return
        }
        #expect(code == 12, "must be BAD_DATA, not badPassword")
        let counts = statusCounts(events)
        #expect(counts.ok == 1, "the intact encrypted file proves the password was right")
    }

    // Finding: "opening a continuation volume with the first volume missing silently
    // extracts a partial set and reports success" — both volume-naming styles.
    @Test func missingFirstVolumeFailsFastForOldStyleSets() async throws {
        let folder = try stage(["rar3-old.r00", "rar3-old.r01"])  // no rar3-old.rar
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(anchor: "rar3-old.r00", in: folder)
        guard case .volumeMissing(let name)? = finalError(events) else {
            Issue.record("expected volumeMissing, got \(String(describing: finalError(events)))")
            return
        }
        #expect(name == "rar3-old.rar")
    }

    @Test func missingFirstPartFailsFastForNewStyleSets() async throws {
        let folder = try stage(["rar5-vols.part2.rar", "rar5-vols.part3.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(anchor: "rar5-vols.part2.rar", in: folder)
        guard case .volumeMissing(let name)? = finalError(events) else {
            Issue.record("expected volumeMissing, got \(String(describing: finalError(events)))")
            return
        }
        #expect(name.contains("part1"), "missing name was \(name)")
    }

    // Finding: "overwrite conflict can trash the source archive". An extensionless archive
    // whose wrapper-folder name collides with the archive itself must survive an Overwrite
    // answer — the output gets a numbered name instead.
    @Test func overwriteNeverTrashesTheSourceArchive() async throws {
        let folder = try stage(["rar5-crc.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensionless = folder.appendingPathComponent("rar5-crc")
        try FileManager.default.moveItem(
            at: folder.appendingPathComponent("rar5-crc.rar"), to: extensionless)

        let events = try await runExtract(
            anchor: "rar5-crc", in: folder, conflicts: .overwrite)
        #expect(succeeded(events), "got \(String(describing: finalError(events)))")
        #expect(
            FileManager.default.fileExists(atPath: extensionless.path),
            "the source archive must never be trashed")
        #expect(placed(events)?.lastPathComponent == "rar5-crc 2")
    }

    // Finding: "wrong-password run places partial output and fires the success notification".
    // Placement must be skipped entirely for password-class failures.
    @Test func wrongPasswordRunPlacesNothing() async throws {
        let folder = try stage(["rar5-psw.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(
            anchor: "rar5-psw.rar", in: folder, password: "wrong-password")
        #expect(finalError(events) == .badPassword)
        #expect(placed(events) == nil)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(leftovers == ["rar5-psw.rar"], "nothing but the archive: \(leftovers)")
    }

    // Finding: hostile size fields must saturate the progress denominator, not trap the app.
    @Test func extractBridgeByteCountingSaturatesInsteadOfTrapping() {
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream()
        defer {
            continuation.finish()
            _ = stream
        }
        let bridge = ExtractBridge(
            continuation: continuation, idsByName: [:], legacyEncryptedNames: [],
            totalBytes: .max,
            broker: PasswordBroker(
                provider: CountingPasswordProvider(nil), token: ExtractCancelToken(),
                archiveName: "x"),
            token: ExtractCancelToken())
        bridge.addBytes(.max)
        bridge.addBytes(1024)  // would trap before the fix
        bridge.addBytes(.max)
    }

    // Volume-naming additions from the review fixes.
    @Test func missingFirstVolumeNamesMatchTheSetNaming() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rr-vol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r00 = dir.appendingPathComponent("set.r00")
        FileManager.default.createFile(atPath: r00.path, contents: Data())
        #expect(RARVolumes.missingFirstVolumeName(for: r00) == "set.rar")

        let part2 = dir.appendingPathComponent("set.part02.rar")
        FileManager.default.createFile(atPath: part2.path, contents: Data())
        #expect(RARVolumes.missingFirstVolumeName(for: part2) == "set.part01.rar")
        let part9 = dir.appendingPathComponent("other.part9.rar")
        FileManager.default.createFile(atPath: part9.path, contents: Data())
        #expect(RARVolumes.missingFirstVolumeName(for: part9) == "other.part1.rar")

        let rar = dir.appendingPathComponent("set.rar")
        FileManager.default.createFile(atPath: rar.path, contents: Data())
        #expect(RARVolumes.missingFirstVolumeName(for: rar) == nil)
    }

    @Test func setMembershipGuardsTheSourceVolumes() {
        let first = URL(fileURLWithPath: "/x/archive.part01.rar")
        #expect(
            RARVolumes.belongsToSet(
                URL(fileURLWithPath: "/x/archive.part01.rar"), firstVolume: first))
        #expect(
            RARVolumes.belongsToSet(
                URL(fileURLWithPath: "/x/archive.part02.rar"), firstVolume: first))
        #expect(!RARVolumes.belongsToSet(URL(fileURLWithPath: "/x/archive"), firstVolume: first))
        #expect(
            !RARVolumes.belongsToSet(
                URL(fileURLWithPath: "/y/archive.part02.rar"), firstVolume: first))

        let old = URL(fileURLWithPath: "/x/set.rar")
        #expect(RARVolumes.belongsToSet(URL(fileURLWithPath: "/x/set.r00"), firstVolume: old))
        #expect(RARVolumes.belongsToSet(URL(fileURLWithPath: "/x/SET.RAR"), firstVolume: old))
        #expect(!RARVolumes.belongsToSet(URL(fileURLWithPath: "/x/set"), firstVolume: old))
        #expect(!RARVolumes.belongsToSet(URL(fileURLWithPath: "/x/other.r00"), firstVolume: old))
    }
}
