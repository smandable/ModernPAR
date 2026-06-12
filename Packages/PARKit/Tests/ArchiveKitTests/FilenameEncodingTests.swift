import Foundation
import ModernPARCore
import Testing

@testable import ArchiveKit

/// Legacy filename-encoding coverage (ROADMAP Phase 7; doc-01 §3.7): pre-RAR5 headers can
/// store entry names in an OEM/regional codepage with NO Unicode variant. The decode layer
/// is unit-tested with synthetic raw bytes; the end-to-end tests run the real engine over
/// minimal RAR 1.5-format STORED archives synthesized by `RAR15Builder` (no archiver writes
/// these anymore, and the rarfile corpus has no codepage-named fixture).
struct FilenameEncodingTests {

    // CP866 "Привет.txt" / "Пока.txt" / "Пика.txt" — every Cyrillic byte is invalid UTF-8.
    static let privetCP866: [UInt8] = [0x8F, 0xE0, 0xA8, 0xA2, 0xA5, 0xE2] + Array(".txt".utf8)
    static let pokaCP866: [UInt8] = [0x8F, 0xAE, 0xAA, 0xA0] + Array(".txt".utf8)
    static let pikaCP866: [UInt8] = [0x8F, 0xA8, 0xAA, 0xA0] + Array(".txt".utf8)
    // windows-1252 "café.txt" — a single 0xE9 high byte.
    static let cafe1252: [UInt8] = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)

    // MARK: - Decode primitives

    @Test func decodesCP866Bytes() {
        #expect(LegacyFilenameDecoder.decode(Self.privetCP866, ianaName: "IBM866") == "Привет.txt")
        #expect(LegacyFilenameDecoder.decode(Self.pokaCP866, ianaName: "IBM866") == "Пока.txt")
    }

    @Test func decodesWindows1252Bytes() {
        #expect(
            LegacyFilenameDecoder.decode(Self.cafe1252, ianaName: "windows-1252") == "café.txt")
    }

    @Test func unknownCharsetDecodesToNil() {
        #expect(LegacyFilenameDecoder.decode(Self.privetCP866, ianaName: "no-such-charset") == nil)
    }

    @Test func lossyUTF8ReplacesEveryInvalidByte() {
        let lossy = LegacyFilenameDecoder.lossyUTF8(Self.pokaCP866)
        #expect(lossy == String(repeating: "\u{FFFD}", count: 4) + ".txt")
    }

    // MARK: - Candidates

    @Test func candidatesOnlyOfferCharsetsThatDecodeEveryAffectedName() {
        let candidates = LegacyFilenameDecoder.candidates(
            for: [Self.privetCP866, Self.pokaCP866])
        #expect(candidates.contains { $0.ianaName == "IBM866" })
        // The contract: each offered charset decodes ALL affected names.
        for candidate in candidates {
            #expect(
                LegacyFilenameDecoder.decode(Self.privetCP866, ianaName: candidate.ianaName)
                    != nil, "\(candidate.ianaName) cannot decode an affected name")
            #expect(
                LegacyFilenameDecoder.decode(Self.pokaCP866, ianaName: candidate.ianaName) != nil,
                "\(candidate.ianaName) cannot decode an affected name")
            #expect(!candidate.localizedName.isEmpty)
        }
        // The preview is the FIRST affected name in that charset's reading.
        let ibm866 = candidates.first { $0.ianaName == "IBM866" }
        #expect(ibm866?.preview == "Привет.txt")
    }

    @Test func candidatePreviewShowsLegacyBackslashSeparatorsAsSlashes() {
        let nested: [UInt8] = [0x8F, 0xE0] + Array("\\".utf8) + Self.pokaCP866
        let ibm866 = LegacyFilenameDecoder.candidates(for: [nested])
            .first { $0.ianaName == "IBM866" }
        #expect(ibm866?.preview == "Пр/Пока.txt")
    }

    // MARK: - Path safety (same posture as ZipExtractor.safeRelativePath)

    @Test func sanitizerMatchesTheZipPathPolicy() {
        #expect(LegacyFilenameDecoder.sanitizedRelativePath("../evil.txt") == nil)
        #expect(LegacyFilenameDecoder.sanitizedRelativePath("a/../../evil.txt") == nil)
        #expect(LegacyFilenameDecoder.sanitizedRelativePath("") == nil)
        #expect(LegacyFilenameDecoder.sanitizedRelativePath("/abs/x.txt") == "abs/x.txt")
        #expect(LegacyFilenameDecoder.sanitizedRelativePath("dir\\file.txt") == "dir/file.txt")
        #expect(
            LegacyFilenameDecoder.sanitizedRelativePath(".ModernPAR-extract-x/y") == nil)
    }

    @Test func uniquifiedNumbersCollisionsPreservingExtensions() {
        var taken: Set<String> = ["a.txt"]
        #expect(LegacyFilenameDecoder.uniquified("a.txt", taken: &taken) == "a 2.txt")
        #expect(LegacyFilenameDecoder.uniquified("a.txt", taken: &taken) == "a 3.txt")
        #expect(LegacyFilenameDecoder.uniquified("b", taken: &taken) == "b")
        // Case-insensitive, matching APFS defaults.
        #expect(LegacyFilenameDecoder.uniquified("A.TXT", taken: &taken) == "A 4.TXT")
    }

    // MARK: - Plan resolution (no engine)

    private func entry(
        _ name: String, raw: [UInt8]? = nil, isDirectory: Bool = false
    ) -> RAREntry {
        RAREntry(
            name: name, unpackedSize: 1, isDirectory: isDirectory, isEncrypted: false,
            unpVersion: 20, rawNameBytes: raw)
    }

    private func makePlan(
        entries: [RAREntry],
        preference: FilenameEncodingPreference = .automatic,
        picker: (any FilenameEncodingPicker)? = nil
    ) -> LegacyFilenameDecoder.Plan {
        var continuation: AsyncStream<EngineEvent>.Continuation!
        let stream = AsyncStream<EngineEvent> { continuation = $0 }
        defer {
            continuation.finish()
            _ = stream
        }
        return LegacyFilenameDecoder.plan(
            for: entries, preference: preference, picker: picker,
            token: ExtractCancelToken(), continuation: continuation)
    }

    @Test func planIsEmptyForValidUTF8AndUnicodeFlaggedNames() {
        let picker = RecordingEncodingPicker(answer: "IBM866")
        let plan = makePlan(
            entries: [
                entry("plain.txt"),  // RAR5 / unicode-flagged: no raw bytes at all
                entry("café.txt", raw: Array("café.txt".utf8)),  // raw bytes but valid UTF-8
            ],
            picker: picker)
        #expect(plan.relativePaths.isEmpty)
        #expect(picker.prompts == 0, "an unaffected archive must never prompt")
    }

    @Test func planAppliesAFixedEncodingWithoutPrompting() {
        let picker = RecordingEncodingPicker(answer: "windows-1251")
        let plan = makePlan(
            entries: [entry("", raw: Self.privetCP866), entry("plain.txt")],
            preference: .fixed(ianaName: "IBM866"), picker: picker)
        #expect(plan.relativePaths == [0: "Привет.txt"])
        #expect(picker.prompts == 0)
    }

    @Test func planPromptsOnceAndHonorsTheChoice() {
        let picker = RecordingEncodingPicker(answer: "IBM866")
        let plan = makePlan(
            entries: [entry("", raw: Self.privetCP866), entry("", raw: Self.pokaCP866)],
            picker: picker)
        #expect(picker.prompts == 1)
        #expect(picker.offeredIANANames.contains("IBM866"))
        #expect(plan.relativePaths == [0: "Привет.txt", 1: "Пока.txt"])
    }

    @Test func planFallsBackToLossyUTF8WhenThePickerDeclines() {
        let picker = RecordingEncodingPicker(answer: nil)
        let plan = makePlan(entries: [entry("", raw: Self.pokaCP866)], picker: picker)
        #expect(picker.prompts == 1)
        #expect(plan.relativePaths == [0: String(repeating: "\u{FFFD}", count: 4) + ".txt"])
    }

    @Test func planWithoutAPickerFallsBackToLossyUTF8() {
        let plan = makePlan(entries: [entry("", raw: Self.pokaCP866)], picker: nil)
        #expect(plan.relativePaths == [0: String(repeating: "\u{FFFD}", count: 4) + ".txt"])
    }

    @Test func planUniquesCollisionsAgainstUnaffectedAndDecodedNames() {
        // An unaffected entry already owns "Привет.txt"; lossy twins collide with each other.
        let plan = makePlan(
            entries: [
                entry("Привет.txt"),
                entry("", raw: Self.privetCP866),
                entry("", raw: Self.pokaCP866),
                entry("", raw: Self.pikaCP866),
            ],
            preference: .fixed(ianaName: "IBM866"))
        #expect(plan.relativePaths[1] == "Привет 2.txt")
        #expect(plan.relativePaths[2] == "Пока.txt")
        #expect(plan.relativePaths[3] == "Пика.txt")
    }

    @Test func planRefusesHostileDecodedPaths() {
        // windows-1252 bytes that decode to a traversal — both readings sanitize to nil, so
        // the entry keeps the engine default (no override).
        let hostile: [UInt8] = Array("../evil".utf8) + [0xE9]
        let plan = makePlan(
            entries: [entry("", raw: hostile)], preference: .fixed(ianaName: "windows-1252"))
        #expect(plan.relativePaths.isEmpty)
    }

    // The DLL build force-overwrites, so a directory landing on a file-owned path would
    // DELETE the extracted file with both entries still reporting success. (Phase 7 review
    // HIGH)
    @Test func planNeverLetsADirectoryTakeAFileOwnedPath() {
        // An unaffected FILE owns "Пика.txt"; the affected directory decodes to that path.
        let plan = makePlan(
            entries: [
                entry("Пика.txt"),
                entry("", raw: Self.pikaCP866, isDirectory: true),
            ],
            preference: .fixed(ianaName: "IBM866"))
        #expect(plan.relativePaths[1] == "Пика 2.txt")
    }

    @Test func planRenamedDirectoryCarriesItsNestedEntries() {
        // The directory's decoded path collides with an unaffected FILE; its nested child
        // (legacy RAR stores the full dir\child path per entry) must follow the rename.
        let dirCP866: [UInt8] = [0x84, 0x88, 0x90]  // "ДИР"
        let childCP866 = dirCP866 + Array("\\".utf8) + Self.pokaCP866
        let plan = makePlan(
            entries: [
                entry("ДИР"),  // unaffected FILE owning the directory's decoded path
                entry("", raw: dirCP866, isDirectory: true),
                entry("", raw: childCP866),
            ],
            preference: .fixed(ianaName: "IBM866"))
        #expect(plan.relativePaths[1] == "ДИР 2")
        #expect(plan.relativePaths[2] == "ДИР 2/Пока.txt")
    }

    @Test func planLossyFileAndDirectoryTwinsNeverShareAPath() {
        // Under the lossy fallback a file and a directory decode identically — directories
        // plan first, the file is numbered away, and no path is shared.
        let plan = makePlan(entries: [
            entry("", raw: Self.pokaCP866),
            entry("", raw: Self.pikaCP866, isDirectory: true),
        ])
        let lossy = String(repeating: "\u{FFFD}", count: 4) + ".txt"
        #expect(plan.relativePaths[1] == lossy)
        #expect(plan.relativePaths[0] == String(repeating: "\u{FFFD}", count: 4) + " 2.txt")
        #expect(plan.relativePaths[0] != plan.relativePaths[1])
    }

    // MARK: - End to end (real engine over synthesized RAR 1.5 archives)

    private func stageSynthesized(
        _ name: String, entries: [RAR15Builder.Entry]
    ) throws -> (folder: URL, archive: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("unrar-enc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent(name)
        try RAR15Builder.archive(entries: entries).write(to: archive)
        return (folder, archive)
    }

    private func runExtract(
        archive: URL, folder: URL, options: ExtractOptions
    ) async throws -> [EngineEvent] {
        let route = SessionRoute(
            mode: .extractArchive,
            folderBookmark: try? ScopedAccess.bookmark(for: folder),
            anchorBookmark: try ScopedAccess.bookmark(for: archive))
        let stream = RARExtractor().extract(
            route, options: options,
            password: CountingPasswordProvider(nil),
            conflicts: AutoConflictResolver(.cancel))
        var events: [EngineEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func succeeded(_ events: [EngineEvent]) -> Bool {
        for event in events.reversed() {
            if case .finished(let result) = event {
                if case .success = result { return true }
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

    private func discoveredNames(_ events: [EngineEvent]) -> [String] {
        for event in events {
            if case .filesDiscovered(let rows) = event { return rows.map(\.name) }
        }
        return []
    }

    private func contents(of folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.map { $0.precomposedStringWithCanonicalMapping })
    }

    @Test func fixedEncodingExtractsCP866NamesEndToEnd() async throws {
        let (folder, archive) = try stageSynthesized(
            "cp866.rar",
            entries: [
                .file(nameBytes: Self.privetCP866, data: Data("privet-data\n".utf8)),
                .file(nameBytes: Self.pokaCP866, data: Data("poka-data\n".utf8)),
                .file(nameBytes: Array("plain.txt".utf8), data: Data("plain-data\n".utf8)),
            ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(
            archive: archive, folder: folder,
            options: ExtractOptions(filenameEncoding: .fixed(ianaName: "IBM866")))
        #expect(succeeded(events), "expected success, got \(events.suffix(3))")
        let out = folder.appendingPathComponent("cp866")
        #expect(contents(of: out) == ["Привет.txt", "Пока.txt", "plain.txt"])
        #expect(
            (try? Data(contentsOf: out.appendingPathComponent("Привет.txt")))
                == Data("privet-data\n".utf8))
        #expect(Set(discoveredNames(events)) == ["Привет.txt", "Пока.txt", "plain.txt"])
    }

    @Test func automaticEncodingPromptsOnceAndDecodesTheChoice() async throws {
        let (folder, archive) = try stageSynthesized(
            "cp866.rar",
            entries: [
                .file(nameBytes: Self.privetCP866, data: Data("privet-data\n".utf8)),
                .file(nameBytes: Array("plain.txt".utf8), data: Data("plain-data\n".utf8)),
            ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let picker = RecordingEncodingPicker(answer: "IBM866")
        let events = try await runExtract(
            archive: archive, folder: folder,
            options: ExtractOptions(filenameEncoding: .automatic, encodingPicker: picker))
        #expect(succeeded(events))
        #expect(picker.prompts == 1, "prompted \(picker.prompts) times")
        #expect(picker.offeredIANANames.contains("IBM866"))
        let out = folder.appendingPathComponent("cp866")
        #expect(contents(of: out) == ["Привет.txt", "plain.txt"])
    }

    @Test func declinedPromptStillExtractsUnderLossyNames() async throws {
        // Today these archives fail outright (the engine cannot create an empty-named file);
        // the lossy fallback must extract every entry under stable replacement-char names.
        let (folder, archive) = try stageSynthesized(
            "cp866.rar",
            entries: [
                .file(nameBytes: Self.pokaCP866, data: Data("poka-data\n".utf8)),
                .file(nameBytes: Self.pikaCP866, data: Data("pika-data\n".utf8)),
            ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let picker = RecordingEncodingPicker(answer: nil)
        let events = try await runExtract(
            archive: archive, folder: folder,
            options: ExtractOptions(filenameEncoding: .automatic, encodingPicker: picker))
        #expect(succeeded(events))
        let lossy = String(repeating: "\u{FFFD}", count: 4) + ".txt"
        let out = folder.appendingPathComponent("cp866")
        // Both names lossy-decode identically — the second must be numbered, not dropped.
        #expect(
            contents(of: out) == Set([lossy, String(repeating: "\u{FFFD}", count: 4) + " 2.txt"]))
        #expect(
            (try? Data(contentsOf: out.appendingPathComponent(lossy)))
                == Data("poka-data\n".utf8))
    }

    @Test func aDirectoryEntryNeverReplacesAnExtractedFile() async throws {
        // A FILE and a DIRECTORY whose raw names lossy-decode identically: the forced-
        // overwrite DLL would delete the extracted file and put the directory in its place,
        // still reporting success — the file's data must survive. (Phase 7 review HIGH)
        let (folder, archive) = try stageSynthesized(
            "dirclash.rar",
            entries: [
                .file(nameBytes: Self.pokaCP866, data: Data("poka-data\n".utf8)),
                .directory(nameBytes: Self.pikaCP866),
            ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let picker = RecordingEncodingPicker(answer: nil)
        let events = try await runExtract(
            archive: archive, folder: folder,
            options: ExtractOptions(filenameEncoding: .automatic, encodingPicker: picker))
        #expect(succeeded(events))
        let out = folder.appendingPathComponent("dirclash")
        let lossy = String(repeating: "\u{FFFD}", count: 4) + ".txt"
        // The directory keeps the base path; the file is numbered away with its data intact.
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(
            atPath: out.appendingPathComponent(lossy).path, isDirectory: &isDirectory)
        #expect(isDirectory.boolValue, "the colliding path must be the directory")
        #expect(
            (try? Data(
                contentsOf: out.appendingPathComponent(
                    String(repeating: "\u{FFFD}", count: 4) + " 2.txt")))
                == Data("poka-data\n".utf8),
            "the file's data must survive the collision")
    }

    @Test func nestedLegacyDirectoriesDecodeAsAWholePath() async throws {
        // RAR 1.5-4.x stores '\' separators; a CP866 directory entry plus a nested file must
        // come out as one decoded tree.
        let dirCP866: [UInt8] = [0x84, 0x88, 0x90]  // "ДИР"
        let (folder, archive) = try stageSynthesized(
            "nested.rar",
            entries: [
                .directory(nameBytes: dirCP866),
                .file(
                    nameBytes: dirCP866 + Array("\\".utf8) + Self.privetCP866,
                    data: Data("nested-data\n".utf8)),
            ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = try await runExtract(
            archive: archive, folder: folder,
            options: ExtractOptions(filenameEncoding: .fixed(ianaName: "IBM866")))
        #expect(succeeded(events))
        // Single top-level item → placed directly, no enclosing folder.
        let out = folder.appendingPathComponent("ДИР")
        #expect(contents(of: out) == ["Привет.txt"])
        #expect(
            (try? Data(contentsOf: out.appendingPathComponent("Привет.txt")))
                == Data("nested-data\n".utf8))
    }

    @Test func validUTF8ArchivesNeverPromptAndAreUntouched() async throws {
        // unicode.rar (RAR3, unicode-flagged names) — the canonical "completely unaffected"
        // case: no prompt, names exactly as before.
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/rar")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("unrar-enc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("unicode.rar")
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("unicode.rar"), to: archive)
        let picker = RecordingEncodingPicker(answer: "IBM866")
        let events = try await runExtract(
            archive: archive, folder: folder,
            options: ExtractOptions(filenameEncoding: .automatic, encodingPicker: picker))
        #expect(succeeded(events))
        #expect(picker.prompts == 0, "valid-UTF-8 names must never prompt")
        let out = folder.appendingPathComponent("unicode")
        #expect(
            contents(of: out) == [
                "уииоотивл.txt".precomposedStringWithCanonicalMapping,
                "𝐀𝐁𝐁𝐂.txt".precomposedStringWithCanonicalMapping,
            ])
    }
}

// MARK: - Test doubles

/// Counts prompts and records the offered candidates — the prompt-once contract and the
/// "only decodable charsets are offered" contract.
final class RecordingEncodingPicker: FilenameEncodingPicker, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: String?
    private var count = 0
    private var offered: [FilenameEncodingCandidate] = []

    init(answer: String?) { self.answer = answer }

    func chooseEncoding(candidates: [FilenameEncodingCandidate]) async -> String? {
        lock.withLock {
            count += 1
            offered = candidates
        }
        return answer
    }

    var prompts: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var offeredIANANames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return offered.map(\.ianaName)
    }
}

// MARK: - RAR 1.5 synthesis

/// Builds a minimal RAR 1.5-format STORED archive byte-by-byte (marker, main header, file
/// headers with the format's CRC16-of-header), the same layout `ReadHeader15` parses — the
/// only way to fixture legacy codepage names, which no maintained archiver writes anymore.
enum RAR15Builder {

    enum Entry {
        case file(nameBytes: [UInt8], data: Data)
        case directory(nameBytes: [UInt8])
    }

    static func archive(entries: [Entry]) -> Data {
        var bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]  // "Rar!\x1a\x07\x00"
        // Main header: HighPosAV(2) + PosAV(4), no flags.
        bytes += block(type: 0x73, flags: 0x0000, body: [0, 0, 0, 0, 0, 0])
        for entry in entries {
            switch entry {
            case .file(let nameBytes, let data):
                bytes += fileBlock(nameBytes: nameBytes, data: [UInt8](data), isDirectory: false)
            case .directory(let nameBytes):
                bytes += fileBlock(nameBytes: nameBytes, data: [], isDirectory: true)
            }
        }
        return Data(bytes)
    }

    /// HEAD3_FILE: PackSize(4) UnpSize(4) HostOS(1) FileCRC(4) FileTime(4) UnpVer(1)
    /// Method(1) NameSize(2) FileAttr(4) Name — directories are marked by the all-ones
    /// window mask in the flags (LHD_DIRECTORY) plus the DOS directory attribute.
    private static func fileBlock(
        nameBytes: [UInt8], data: [UInt8], isDirectory: Bool
    ) -> [UInt8] {
        let flags: UInt16 = isDirectory ? 0x80E0 : 0x8000
        let attr: UInt32 = isDirectory ? 0x10 : 0x20
        var body: [UInt8] = []
        body += le32(UInt32(data.count))  // PackSize
        body += le32(UInt32(data.count))  // UnpSize
        body += [0x00]  // HostOS = MS-DOS
        body += le32(crc32(data))  // FileCRC
        body += le32(0x3D63_3D0F)  // FileTime (any valid DOS stamp)
        body += [20, 0x30]  // UnpVer 2.0, method '0' = stored
        body += le16(UInt16(nameBytes.count))
        body += le32(attr)
        body += nameBytes
        return block(type: 0x74, flags: flags, body: body) + data
    }

    /// Generic RAR 1.5 block: CRC16(2) Type(1) Flags(2) HeadSize(2) + body, where the CRC
    /// is the low 16 bits of CRC32 over everything after the CRC field (rawread GetCRC15).
    private static func block(type: UInt8, flags: UInt16, body: [UInt8]) -> [UInt8] {
        let headSize = UInt16(7 + body.count)
        let afterCRC = [type] + le16(flags) + le16(headSize) + body
        return le16(UInt16(crc32(afterCRC) & 0xFFFF)) + afterCRC
    }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8(value >> 24),
        ]
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    static func crc32<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }
}
