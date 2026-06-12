import CoreFoundation
import Foundation
import ModernPARCore

/// Decode planning for legacy (pre-RAR5) entry names stored in an OEM/regional codepage with
/// NO Unicode variant (ROADMAP Phase 7; doc-01 §3.7 — the original's encoding-selection
/// sheet). On _APPLE the engine decodes such names as UTF-8, which truncates at the first
/// invalid byte: an all-Cyrillic CP866 name reaches Swift EMPTY, names collide, and the
/// engine cannot even create the files. The plan therefore redirects every affected entry to
/// a properly decoded path inside the staging folder (via the shim's `destination_override`).
/// Valid-UTF-8 names and RAR5 archives always produce an empty plan: no renames, no prompts.
enum LegacyFilenameDecoder {

    /// Entry index (archive order, the shim's `entry_index`) → safe staging-relative decoded
    /// path. Empty when nothing needs a decode.
    struct Plan {
        var relativePaths: [Int: String] = [:]
    }

    /// The curated prompt order (doc-01 §3.7): western/central/eastern European, the DOS
    /// codepages, the major CJK encodings, then the remaining Windows codepages. Only
    /// candidates that decode EVERY affected name are offered.
    static let curatedIANANames: [String] = [
        "windows-1252",  // Latin-1 / Western European
        "windows-1250",  // Central European
        "windows-1251",  // Cyrillic
        "IBM866",  // Cyrillic (DOS)
        "IBM437",  // US (DOS)
        "Shift_JIS",
        "EUC-KR",
        "GB18030",
        "Big5",
        "windows-1253",  // Greek
        "windows-1254",  // Turkish
        "windows-1255",  // Hebrew
        "windows-1256",  // Arabic
    ]

    /// Resolves the decode once per run and maps every affected entry to a decoded, sanitized,
    /// collision-free staging-relative path. May block on the encoding-selection sheet
    /// (engine queue only — never the main thread); a declined/cancelled prompt and entries
    /// the chosen charset cannot decode fall back to a lossy UTF-8 reading, which still fixes
    /// the empty-name collisions.
    static func plan(
        for entries: [RAREntry],
        preference: FilenameEncodingPreference,
        picker: (any FilenameEncodingPicker)?,
        token: ExtractCancelToken,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) -> Plan {
        let affected = entries.enumerated().compactMap { index, entry -> (Int, [UInt8])? in
            guard let raw = entry.rawNameBytes, !raw.isEmpty,
                String(bytes: raw, encoding: .utf8) == nil
            else { return nil }
            return (index, raw)
        }
        guard !affected.isEmpty else { return Plan() }

        let chosen = resolveEncoding(
            preference: preference, picker: picker, rawNames: affected.map(\.1), token: token)
        if let chosen {
            continuation.yield(
                .logLine(
                    "Decoding \(affected.count) legacy file name(s) as \(localizedName(forIANA: chosen) ?? chosen)."
                ))
        } else {
            continuation.yield(
                .logLine(
                    "\(affected.count) legacy file name(s) are not valid UTF-8 — keeping a lossy UTF-8 reading."
                ))
        }

        // Collision avoidance is case-insensitive (APFS default). The taken set starts with
        // every path the engine will write by default (the unaffected entries). Directory
        // collisions merge with other DIRECTORIES so nested decoded entries stay together —
        // but a directory must NEVER take a file-owned path: the DLL build force-overwrites
        // (uisilent uiAskReplace), so the engine would DELETE the extracted file and create
        // the directory in its place, with both entries still reporting success. Directories
        // plan first (parents before children) so a renamed directory carries every entry
        // nested under it — legacy RAR stores the full dir\child path per entry.
        // (Phase 7 review HIGH)
        let affectedIndices = Set(affected.map(\.0))
        var taken = Set(
            entries.enumerated()
                .filter { !affectedIndices.contains($0.offset) }
                .map { $0.element.name.lowercased() })
        var fileOwned = Set(
            entries.enumerated()
                .filter { !affectedIndices.contains($0.offset) && !$0.element.isDirectory }
                .map { $0.element.name.lowercased() })

        var decodedEntries: [(index: Int, isDirectory: Bool, relative: String)] = []
        for (index, raw) in affected {
            let decoded = chosen.flatMap { decode(raw, ianaName: $0) } ?? lossyUTF8(raw)
            guard
                let relative = sanitizedRelativePath(decoded)
                    ?? sanitizedRelativePath(lossyUTF8(raw))
            else { continue }  // hostile either way → engine default (current behavior)
            decodedEntries.append((index, entries[index].isDirectory, relative))
        }

        var plan = Plan()
        // Renamed directory prefixes, recorded shallow-first; each original is expressed in
        // post-earlier-renames form, so sequential application stays correct for nesting.
        var dirRenames: [(original: String, renamed: String)] = []
        func applyDirRenames(_ path: String) -> String {
            var result = path
            for rename in dirRenames where result.hasPrefix(rename.original + "/") {
                result = rename.renamed + result.dropFirst(rename.original.count)
            }
            return result
        }

        let directories = decodedEntries.filter(\.isDirectory)
            .sorted { $0.relative.count < $1.relative.count }
        for entry in directories {
            var relative = applyDirRenames(entry.relative)
            if fileOwned.contains(relative.lowercased()) {
                let renamed = uniquified(relative, taken: &taken)
                dirRenames.append((original: relative, renamed: renamed))
                relative = renamed
            } else {
                taken.insert(relative.lowercased())
            }
            plan.relativePaths[entry.index] = relative
        }
        for entry in decodedEntries where !entry.isDirectory {
            var relative = applyDirRenames(entry.relative)
            relative = uniquified(relative, taken: &taken)
            fileOwned.insert(relative.lowercased())
            plan.relativePaths[entry.index] = relative
        }
        return plan
    }

    // MARK: - Decode primitives

    /// Strict single-name decode through the IANA charset registry; nil when the charset is
    /// unknown or the bytes are not valid in it.
    static func decode(_ bytes: [UInt8], ianaName: String) -> String? {
        guard let encoding = stringEncoding(forIANA: ianaName) else { return nil }
        return String(data: Data(bytes), encoding: encoding)
    }

    /// The fallback reading: invalid sequences become U+FFFD so the entry at least extracts
    /// under a stable, non-colliding (after uniquing) name.
    static func lossyUTF8(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Candidate interpretations for the selection sheet: every curated charset that decodes
    /// ALL affected names, previewed with the first affected name. (doc-01 §3.7)
    static func candidates(for rawNames: [[UInt8]]) -> [FilenameEncodingCandidate] {
        var result: [FilenameEncodingCandidate] = []
        for ianaName in curatedIANANames {
            var preview: String?
            var decodesAll = true
            for raw in rawNames {
                guard let decoded = decode(raw, ianaName: ianaName) else {
                    decodesAll = false
                    break
                }
                // RAR 1.5-4.x stores '\' as the path separator; preview it naturally.
                if preview == nil { preview = decoded.replacingOccurrences(of: "\\", with: "/") }
            }
            guard decodesAll, let preview else { continue }
            result.append(
                FilenameEncodingCandidate(
                    ianaName: ianaName,
                    localizedName: localizedName(forIANA: ianaName) ?? ianaName,
                    preview: preview))
        }
        return result
    }

    // MARK: - Path safety

    /// Same hostile-path posture as `ZipExtractor.safeRelativePath` (single policy for every
    /// caller-controlled archive path) — nil refuses traversal/absolute/empty results.
    static func sanitizedRelativePath(_ decoded: String) -> String? {
        ZipExtractor.safeRelativePath(decoded)
    }

    /// First name not yet taken: `Photos` → `Photos 2` → … (extensions preserved, matching
    /// `RARVolumes.uniqueDestination`); inserts the result into `taken`.
    static func uniquified(_ relative: String, taken: inout Set<String>) -> String {
        if taken.insert(relative.lowercased()).inserted { return relative }
        let ns = relative as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            if taken.insert(candidate.lowercased()).inserted { return candidate }
            counter += 1
        }
    }

    // MARK: - Resolution

    private static func resolveEncoding(
        preference: FilenameEncodingPreference,
        picker: (any FilenameEncodingPicker)?,
        rawNames: [[UInt8]],
        token: ExtractCancelToken
    ) -> String? {
        switch preference {
        case .fixed(let ianaName):
            // A fixed preference applies without prompting; an unknown charset name falls
            // back to the lossy reading (never a prompt — that is the automatic mode's job).
            return stringEncoding(forIANA: ianaName) != nil ? ianaName : nil
        case .automatic:
            guard let picker else { return nil }
            let offered = candidates(for: rawNames)
            guard !offered.isEmpty else { return nil }
            let chosen = EncodingPickerBroker(picker: picker, token: token)
                .chooseSync(candidates: offered)
            // Only honor an offered charset — anything else reads as a decline.
            return offered.contains { $0.ianaName == chosen } ? chosen : nil
        }
    }

    private static func stringEncoding(forIANA ianaName: String) -> String.Encoding? {
        let encoding = CFStringConvertIANACharSetNameToEncoding(ianaName as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    private static func localizedName(forIANA ianaName: String) -> String? {
        guard let encoding = stringEncoding(forIANA: ianaName) else { return nil }
        let name = String.localizedName(of: encoding)
        return name.isEmpty ? nil : name
    }
}

/// Blocking bridge from the engine queue to the async encoding-selection sheet — the
/// `PasswordBroker` shape (poll the cancel token so a cancelled run never leaves the engine
/// thread waiting on UI forever). Consulted at most once per run. (ROADMAP Phase 7)
final class EncodingPickerBroker: @unchecked Sendable {
    private let picker: any FilenameEncodingPicker
    private let token: ExtractCancelToken

    init(picker: any FilenameEncodingPicker, token: ExtractCancelToken) {
        self.picker = picker
        self.token = token
    }

    /// Returns the chosen IANA charset name, or nil when the user declines or the run is
    /// cancelled while the sheet is up.
    func chooseSync(candidates: [FilenameEncodingCandidate]) -> String? {
        if token.isCancelled { return nil }  // never raise a prompt for a dead run
        let semaphore = DispatchSemaphore(value: 0)
        let box = ValueBox<String?>(nil)
        let picker = picker
        Task.detached {
            box.set(await picker.chooseEncoding(candidates: candidates))
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if token.isCancelled { return nil }
        }
        return box.get()
    }
}
