import Foundation
import ModernPARCore

/// Translates par2cmdline-turbo's textual output into `EngineEvent`s. Shared by the embedded
/// engine (lines arrive via the Par2Shim callback) and, later, the helper-process fallback
/// (lines arrive via stdout) — one vocabulary, snapshot-tested against the real engine.
/// (ARCHITECTURE.md §4.3; vendored par2repairer.cpp is the source of the string contract.)
///
/// Per-file recoverability is a set-level verdict in PAR2: the engine reports files as
/// found/damaged/missing first and only later prints "Repair is possible/not possible", so
/// damaged/missing files are held pending and their final status is emitted with the verdict.
/// Their "Blocks needed" counts settle with it too: the file's source-block count minus the
/// blocks the scan found for it — in its own file and in any other file that holds its data.
public struct TurboOutputParser {
    /// Maps the names the ENGINE prints (Description-packet names after the engine's
    /// par2→local translation) to the native parser's row ids. Names the map doesn't know
    /// are reported with log lines only.
    private let fileIDsByName: [String: UUID]
    /// Source blocks per recovery-set file (row id → `ceil(size / sliceSize)`). Files absent
    /// here — non-recovery files, undescribed IDs — never get a blocks-needed count.
    private let blockCounts: [UUID: Int]
    /// Row ids of NON-recovery ("other") files — listed in the Main packet but not protected by
    /// the recovery set. They can't be repaired and aren't part of the recovery verdict, so they
    /// stay "not in set" whatever the engine says about them; if one is absent or unreadable the
    /// terminal verdict is `.onlyNonRecoverableMissing`, not `.allFilesOK`.
    private let nonRecoveryIDs: Set<UUID>
    /// Non-recovery files the engine confirmed present-and-matching under their own name (a
    /// whole-file "perfect match"). Any non-recovery row NOT in here by verdict time is
    /// missing, unreadable, or only present as data under some other name.
    private var nonRecoveryPresent: Set<UUID> = []
    /// Longest roster key in UTF-8 bytes, which bounds the perfect-match line split: the
    /// engine's par2-to-local translation never shortens a name, so a longer candidate cannot
    /// name a roster file and is skipped without decoding it.
    private let maxRosterKeyBytes: Int
    /// How many ambiguous splits of one perfect-match line are decoded before giving up. An
    /// honest line has exactly one; the cap keeps a crafted name from costing quadratic work.
    private static let maxDecodedSplits = 8
    /// Whether this run repairs after verify — "Repair is required." means "now repairing"
    /// only then; in verify-only runs the engine prints it but stops after the verdict.
    private let repairsAutomatically: Bool

    private var pendingDamaged: Set<String> = []
    private var pendingMissing: Set<String> = []
    /// Files the repair pass will restore (set when the repairable verdict arrives).
    private var awaitingRepair: Set<String> = []
    private var repairPhaseStarted = false
    private var lastProgress = 0.0

    // Per-phase block tallies (the verify scan, then the post-repair re-verify), keyed by row
    // id and consumed when the phase's verdict settles the pending files.
    /// Data blocks found in the target's OWN file: `damaged. Found N of M data blocks.`
    private var blocksFoundInOwnFile: [UUID: Int] = [:]
    /// Targets whose own-file count also covers other targets' blocks (`… from several target
    /// files`), so only part of it is surely theirs.
    private var ownCountIsMixed: Set<UUID> = []
    /// Data blocks found in OTHER files, one entry per reporting file: extra files and other
    /// targets holding misplaced data (`… N of M data blocks from "X".`) — e.g. the `name.1` an
    /// interrupted repair leaves. Entries can overlap: the engine counts blocks again when it
    /// finds them in a second file.
    private var blocksFoundElsewhere: [UUID: [Int]] = [:]
    /// Blocks the engine found for targets it didn't name (`… from several target files`).
    private var unattributedBlocks = 0
    /// The engine's own exact shortfall for the phase — S − A from `You have A out of S data
    /// blocks available.`, printed just before the verdict.
    private var engineShortfall: Int?
    /// Rows that got a disposition this phase — a later `File: "X" - no data found.` for one of
    /// them is the extra-file scan re-reading it under another spelling, not news.
    private var reportedIDs: Set<UUID> = []

    public private(set) var repairedCount = 0
    public private(set) var unrecoverableCount = 0
    /// Files the repairable verdict covered (damaged + missing at verify time).
    public private(set) var recoverableCount = 0
    /// Targets whose data was found under another name ("is a match for") — repair renames.
    public private(set) var renamedCount = 0
    private var renamedTargets: Set<String> = []

    public init(
        fileIDsByName: [String: UUID], blockCounts: [UUID: Int] = [:],
        nonRecoveryIDs: Set<UUID> = [], repairsAutomatically: Bool
    ) {
        self.fileIDsByName = fileIDsByName
        self.blockCounts = blockCounts
        self.nonRecoveryIDs = nonRecoveryIDs
        self.repairsAutomatically = repairsAutomatically
        self.maxRosterKeyBytes = fileIDsByName.keys.lazy.map { $0.utf8.count }.max() ?? 0
    }

    /// Feed one engine output line; returns the events it implies (often just `.logLine`).
    public mutating func consume(_ line: String, isError: Bool) -> [EngineEvent] {
        if let fraction = monotonicProgress(of: line) {
            // Progress spam ("Scanning: 12.3%") feeds the bar, not the log pane.
            return [.overallProgress(fraction: fraction)]
        }

        var events: [EngineEvent] = [.logLine(isError ? "[err] \(line)" : line)]

        // `Target: "X" - is a match for "Y".` / `File: "X" - is a match for "Y".` —
        // target Y's data was found under the name X; repair renames it. (par2repairer.cpp)
        // Checked before the generic Target-line match: the renamed form also starts with
        // `Target: "` but must not be parsed as a found/damaged/missing disposition.
        if let (foundName, target) = matchLine(line) {
            // The Target:-variant means the holder is itself a roster target — and one whose
            // OWN data is gone, since its file holds the target's. The engine prints one line
            // per holder, so a real swap prints a second line naming this file as ITS target;
            // whichever arrives first wins, because markPending skips rename-satisfied names
            // and the rename below clears a pending one. Holding the holder keeps its own
            // shortfall counted (and a non-recovery holder stays "not in set" via markPending).
            if line.hasPrefix("Target: "), foundName != target, fileIDsByName[foundName] != nil {
                events.append(contentsOf: markPending(foundName, missing: false))
            }
            if let id = fileIDsByName[target], nonRecoveryIDs.contains(id) {
                // A repair never renames data into a non-recovery file's name (vendor patch 5),
                // so the row stays "not in set" and the file is not present under its own name.
                events.append(otherFileStatus(id, present: false))
                return events
            }
            renamedTargets.insert(target)
            pendingMissing.remove(target)
            pendingDamaged.remove(target)
            renamedCount = renamedTargets.count
            if let id = fileIDsByName[target] {
                events.append(.fileStatusChanged(id: id, status: renameStatus(from: foundName)))
            }
            return events
        }

        let bytes = Array(line.utf8)

        // `/path/Z is a perfect match for X` — a whole-file hash match, printed for files the
        // engine can't check block by block (empty files, files without slice checksums), right
        // after that file's `no data found` line, which was therefore not damage. Z is X's own
        // file, or X's data under another name (repair renames it).
        if let match = perfectMatchLine(bytes) {
            let displayName = EngineRunSupport.engineDisplayName(for: match.name)
            let isOwnFile = match.path.utf8.reversed().starts(
                with: ("/" + displayName).utf8.reversed())
            // A non-recovery file is only ever checked as a whole, so this line is how the
            // engine confirms it is there — but only under its OWN name: a repair never renames
            // another file into its place (vendor patch 5), so data found elsewhere leaves the
            // set still missing it. Either way the row stays "not in set".
            if nonRecoveryIDs.contains(match.id) {
                events.append(otherFileStatus(match.id, present: isOwnFile))
                return events
            }
            reportedIDs.insert(match.id)
            for name in [match.name, displayName] {
                pendingDamaged.remove(name)
                pendingMissing.remove(name)
            }
            if isOwnFile {
                let restored =
                    awaitingRepair.remove(displayName) ?? awaitingRepair.remove(match.name)
                if restored != nil { repairedCount += 1 }
                events.append(
                    .fileStatusChanged(id: match.id, status: restored != nil ? .recovered : .ok))
            } else {
                renamedTargets.insert(displayName)
                renamedCount = renamedTargets.count
                let foundName = URL(fileURLWithPath: match.path).lastPathComponent
                events.append(
                    .fileStatusChanged(id: match.id, status: renameStatus(from: foundName)))
            }
            return events
        }

        // `… N of M data blocks from "X".` — target X's blocks found in ANOTHER file: an
        // extra file (`File: "Z" - found …`) or a target whose own data is gone
        // (`Target: "Y" - damaged. Found …`, which also leaves Y pending as damaged).
        if let foreign = foreignBlocksLine(bytes) {
            // Skip only the target's own file re-read under the SAME printed name (the
            // extra-file scan), which would count its blocks twice. Comparing names rather
            // than row ids keeps a genuine credit from a file the roster maps to the same row
            // under a different spelling — an ASCII-field name plus its Unicode alias.
            if foreign.holder != foreign.target {
                blocksFoundElsewhere[foreign.targetID, default: []].append(foreign.found)
            }
            if foreign.holderIsTarget {
                events.append(contentsOf: markPending(foreign.holder, missing: false))
            }
            return events
        }

        // `Target: "X" - damaged. Found N of M data blocks.` — X's own file holds N blocks.
        if let own = Self.ownBlocksLine(bytes) {
            if let id = fileIDsByName[own.name] { blocksFoundInOwnFile[id] = own.found }
            events.append(contentsOf: markPending(own.name, missing: false))
            return events
        }

        // `Target: "X" - damaged, found N data blocks from several target files.` — X's file
        // also holds blocks of other incomplete targets (typically all-zero blocks) and the
        // engine doesn't say whose; `File: "Z" - found N …` is the same for an extra file.
        // X's estimate counts all N as its own; the reconciliation knows they may not be.
        if let mixed = Self.mixedBlocksLine(bytes) {
            if let id = fileIDsByName[mixed.name] {
                blocksFoundInOwnFile[id] = mixed.found
                ownCountIsMixed.insert(id)
            }
            unattributedBlocks += mixed.found
            events.append(contentsOf: markPending(mixed.name, missing: false))
            return events
        }
        if let found = Self.unattributedBlocksLine(bytes) {
            unattributedBlocks += found
            return events
        }

        // `File: "X" - no data found.` for a TARGET: the file exists but holds none of its
        // blocks (overwritten, zero-filled, emptied). The engine counts it as damaged but
        // prints no `Target:` line for it, so without this the row never got a status.
        if let name = Self.noDataLine(bytes), let id = fileIDsByName[name],
            !reportedIDs.contains(id)
        {
            events.append(contentsOf: markPending(name, missing: false))
            return events
        }

        if let (name, disposition) = Self.targetLine(line) {
            switch disposition {
            case .found:
                if let id = fileIDsByName[name] {
                    reportedIDs.insert(id)
                    if nonRecoveryIDs.contains(id) {
                        events.append(otherFileStatus(id, present: true))
                    } else if awaitingRepair.remove(name) != nil {
                        // "found" after the repairable verdict is the re-verify of a restored file.
                        repairedCount += 1
                        events.append(.fileStatusChanged(id: id, status: .recovered))
                    } else {
                        events.append(.fileStatusChanged(id: id, status: .ok))
                    }
                }
            case .damaged:
                events.append(contentsOf: markPending(name, missing: false))
            case .missing:
                events.append(contentsOf: markPending(name, missing: true))
            }
            return events
        }

        if line.hasPrefix("All files are correct") {
            // The recovery set is intact. If a NON-recovery ("other") file is absent or
            // unreadable, say so instead of overstating "all files are correct" — the original's
            // DocStatus13. (Renames can't reach this line: the engine prints "Repair is
            // required." whenever any recoverable file is renamed/damaged/missing.)
            if nonRecoveryIDs.subtracting(nonRecoveryPresent).isEmpty {
                events.append(.docStatusChanged(.allFilesOK))
            } else {
                events.append(.docStatusChanged(.onlyNonRecoverableMissing))
            }
        } else if let shortfall = Self.shortfall(of: bytes) {
            engineShortfall = shortfall
        } else if line.hasPrefix("Repair is possible.") {
            awaitingRepair = pendingDamaged.union(pendingMissing)
            recoverableCount = awaitingRepair.count
            events.append(
                contentsOf: settlePending(
                    damaged: .recoverableCorrupt, missing: .recoverableMissing))
            if !repairsAutomatically {
                // Verify-only runs end here; the engine returns without repairing.
                events.append(.docStatusChanged(.repairNeeded))
            }
        } else if line.hasPrefix("Repair is not possible.") {
            unrecoverableCount = pendingDamaged.count + pendingMissing.count
            events.append(
                contentsOf: settlePending(
                    damaged: .unrecoverableCorrupt, missing: .unrecoverableMissing))
        } else if let needed = Self.neededBlocks(of: line) {
            events.append(.docStatusChanged(.needMoreRecovery(blocks: needed)))
        } else if line.hasPrefix("Repair is required.") {
            if repairsAutomatically {
                repairPhaseStarted = true
                events.append(.docStatusChanged(.repairing))
            }
        } else if line.hasPrefix("Verifying repaired files:") {
            repairPhaseStarted = true
        } else if line.hasPrefix("Repair complete.") {
            // Belt and braces: rename-only repairs print no per-file re-verify lines.
            for name in awaitingRepair {
                if let id = fileIDsByName[name] {
                    repairedCount += 1
                    events.append(.fileStatusChanged(id: id, status: .recovered))
                }
            }
            awaitingRepair.removeAll()
            events.append(
                .docStatusChanged(renamedCount > 0 ? .restoredWithRenames : .restoredSuccessfully))
        } else if line.hasPrefix("Repair Failed.") {
            // Repair ran but re-verification still found damage (engine result code 5).
            unrecoverableCount = pendingDamaged.count + pendingMissing.count
            events.append(
                contentsOf: settlePending(
                    damaged: .unrecoverableCorrupt, missing: .unrecoverableMissing))
            awaitingRepair.removeAll()
            events.append(.docStatusChanged(.internalError))
        }
        return events
    }

    // MARK: - Line shapes (string contract pinned by TurboOutputParserTests)

    private enum TargetDisposition { case found, damaged, missing }

    /// The rename presentation depends on the run mode: with auto-repair the rename happens
    /// moments later, so "OK after renaming" is honest; a verify-only run leaves the file
    /// under the wrong name on disk, so the row must stay in a needs-attention state.
    private func renameStatus(from foundName: String) -> FileStatus {
        repairsAutomatically ? .renamed(from: foundName) : .possibleError
    }

    /// `Target: "X" - is a match for "Y".` / `File: "X" - is a match for "Y".`
    /// Returns (foundName X, targetName Y).
    ///
    /// Filenames may legally contain the delimiter (or the line suffix — partial-match lines
    /// like `…found N data blocks from "b.bin".` share the same shape), so every candidate
    /// split is tried and accepted only when the target half is a roster name. Garbage
    /// "targets" from hostile names never are, and those lines fall through to `targetLine`.
    private func matchLine(_ line: String) -> (String, String)? {
        let prefix: String
        if line.hasPrefix("Target: \"") {
            prefix = "Target: \""
        } else if line.hasPrefix("File: \"") {
            prefix = "File: \""
        } else {
            return nil
        }
        guard line.hasSuffix("\".") else { return nil }
        let nameStart = line.index(line.startIndex, offsetBy: prefix.count)
        let nameEnd = line.index(line.endIndex, offsetBy: -2)
        var searchRange = nameStart..<nameEnd
        while let delimiter = line.range(
            of: "\" - is a match for \"", options: .backwards, range: searchRange)
        {
            let target = String(line[delimiter.upperBound..<nameEnd])
            if fileIDsByName[target] != nil {
                return (String(line[nameStart..<delimiter.lowerBound]), target)
            }
            searchRange = nameStart..<delimiter.lowerBound
        }
        return nil
    }

    /// `Target: "name" - found.` / `- missing.` / `- damaged...` (par2repairer.cpp).
    /// The delimiter is matched BACKWARDS so filenames containing `" - ` parse correctly.
    private static func targetLine(_ line: String) -> (String, TargetDisposition)? {
        guard line.hasPrefix("Target: \"") else { return nil }
        guard let nameEnd = line.range(of: "\" - ", options: .backwards) else { return nil }
        let name = String(line[line.index(line.startIndex, offsetBy: 9)..<nameEnd.lowerBound])
        let rest = line[nameEnd.upperBound...]
        if rest.hasPrefix("found") { return (name, .found) }
        if rest.hasPrefix("damaged") { return (name, .damaged) }
        if rest.hasPrefix("missing") { return (name, .missing) }
        return nil
    }

    // The block-count, perfect-match, and shortfall lines (par2repairer.cpp ScanDataFile,
    // VerifyDataFile, CheckVerificationResults) are parsed on UTF-8 bytes: every delimiter is
    // ASCII, so no filename byte — quote, combining mark, anything — can merge with one or
    // impersonate it.
    private static let targetPrefix = Array("Target: \"".utf8)
    private static let filePrefix = Array("File: \"".utf8)
    private static let damagedFoundDelimiter = Array("\" - damaged. Found ".utf8)
    private static let damagedMixedDelimiter = Array("\" - damaged, found ".utf8)
    private static let foundDelimiter = Array("\" - found ".utf8)
    private static let ofDelimiter = Array(" of ".utf8)
    private static let ownBlocksSuffix = Array(" data blocks.".utf8)
    private static let mixedBlocksSuffix = Array(" data blocks from several target files.".utf8)
    private static let perfectMatchDelimiter = Array(" is a perfect match for ".utf8)
    private static let shortfallPrefix = Array("You have ".utf8)
    private static let outOfDelimiter = Array(" out of ".utf8)
    private static let shortfallSuffix = Array(" data blocks available.".utf8)
    private static let fromTargetMarker = Array(" data blocks from \"".utf8)
    private static let quotedLineEnd = Array("\".".utf8)
    private static let noDataSuffix = Array("\" - no data found.".utf8)

    /// `Target: "X" - damaged. Found N of M data blocks.` → (X, N). Read right to left:
    /// everything after the name is fixed-format, so any filename splits exactly.
    private static func ownBlocksLine(_ bytes: [UInt8]) -> (name: String, found: Int)? {
        guard bytes.starts(with: targetPrefix) else { return nil }
        var scanner = ReverseScanner(bytes: bytes, nameStart: targetPrefix.count)
        guard scanner.pop(ownBlocksSuffix), scanner.popCount() != nil,
            scanner.pop(ofDelimiter), let found = scanner.popCount(),
            scanner.pop(damagedFoundDelimiter)
        else { return nil }
        return (scanner.remainder, found)
    }

    /// `Target: "X" - damaged, found N data blocks from several target files.` → (X, N).
    private static func mixedBlocksLine(_ bytes: [UInt8]) -> (name: String, found: Int)? {
        guard bytes.starts(with: targetPrefix) else { return nil }
        var scanner = ReverseScanner(bytes: bytes, nameStart: targetPrefix.count)
        guard scanner.pop(mixedBlocksSuffix), let found = scanner.popCount(),
            scanner.pop(damagedMixedDelimiter)
        else { return nil }
        return (scanner.remainder, found)
    }

    /// `File: "Z" - found N data blocks from several target files.` → N (an extra file).
    private static func unattributedBlocksLine(_ bytes: [UInt8]) -> Int? {
        guard bytes.starts(with: filePrefix) else { return nil }
        var scanner = ReverseScanner(bytes: bytes, nameStart: filePrefix.count)
        guard scanner.pop(mixedBlocksSuffix), let found = scanner.popCount(),
            scanner.pop(foundDelimiter)
        else { return nil }
        return found
    }

    /// `You have A out of S data blocks available.` → S − A, the set's exact shortfall.
    private static func shortfall(of bytes: [UInt8]) -> Int? {
        guard bytes.starts(with: shortfallPrefix) else { return nil }
        var scanner = ReverseScanner(bytes: bytes, nameStart: shortfallPrefix.count)
        guard scanner.pop(shortfallSuffix), let total = scanner.popCount(),
            scanner.pop(outOfDelimiter), let available = scanner.popCount(),
            scanner.end == shortfallPrefix.count, available <= total
        else { return nil }
        return total - available
    }

    /// `/path/Z is a perfect match for X` — unquoted: Z is the engine's full disk path, X the
    /// RAW description name (not the translated form Target lines print). Accepted only when X
    /// names a roster file and Z is an absolute path.
    ///
    /// Either half may itself contain the delimiter, so the split is ambiguous. Candidates are
    /// tried LEFT to right and the first one naming a roster file wins: the trailing name is
    /// printed last, so a file whose own name ends in "… is a perfect match for <target>" would
    /// otherwise be read as that target and clear its damage (its own name matches at an
    /// earlier split, so it wins). Two bounds keep a crafted name cheap — the engine allows a
    /// 100 KB name and prints it verbatim on its callback thread: a candidate longer than any
    /// roster key is skipped without decoding (translation never shortens a name), and at most
    /// `maxDecodedSplits` candidates are decoded, which one honest line never exceeds.
    private func perfectMatchLine(_ bytes: [UInt8]) -> (path: String, name: String, id: UUID)? {
        let delimiter = Self.perfectMatchDelimiter
        guard bytes.first == UInt8(ascii: "/"), bytes.count > delimiter.count else { return nil }
        var decoded = 0
        for start in 1...(bytes.count - delimiter.count)
        where bytes[start..<start + delimiter.count].elementsEqual(delimiter) {
            let tail = bytes[(start + delimiter.count)...]
            guard tail.count <= maxRosterKeyBytes else { continue }
            let name = String(decoding: tail, as: UTF8.self)
            if let id = fileIDsByName[name]
                ?? fileIDsByName[EngineRunSupport.engineDisplayName(for: name)]
            {
                return (String(decoding: bytes[..<start], as: UTF8.self), name, id)
            }
            decoded += 1
            if decoded == Self.maxDecodedSplits { return nil }
        }
        return nil
    }

    /// `File: "X" - no data found.` → X (a target, or any extra file without set data).
    private static func noDataLine(_ bytes: [UInt8]) -> String? {
        guard bytes.starts(with: filePrefix) else { return nil }
        var scanner = ReverseScanner(bytes: bytes, nameStart: filePrefix.count)
        return scanner.pop(noDataSuffix) ? scanner.remainder : nil
    }

    private struct ForeignBlocks {
        let target: String
        let targetID: UUID
        let found: Int
        let holder: String
        let holderID: UUID?
        let holderIsTarget: Bool
    }

    /// `Target: "Y" - damaged. Found N of M data blocks from "X".` (target Y's file holds N of
    /// target X's M blocks and none of its own) and `File: "Z" - found N of M data blocks from
    /// "X".` (an extra file does). Both names are free-form, so every split is tried right to
    /// left and accepted only when X — and, for the `Target:` form, Y — is a roster name.
    private func foreignBlocksLine(_ bytes: [UInt8]) -> ForeignBlocks? {
        let holderIsTarget = bytes.starts(with: Self.targetPrefix)
        guard holderIsTarget || bytes.starts(with: Self.filePrefix) else { return nil }
        let prefix = holderIsTarget ? Self.targetPrefix : Self.filePrefix
        let delimiter = holderIsTarget ? Self.damagedFoundDelimiter : Self.foundDelimiter
        var lineEnd = ReverseScanner(bytes: bytes, nameStart: prefix.count)
        guard lineEnd.pop(Self.quotedLineEnd) else { return nil }
        let targetEnd = lineEnd.end
        let marker = Self.fromTargetMarker
        for markerStart in stride(from: targetEnd - marker.count, through: prefix.count, by: -1)
        where bytes[markerStart..<markerStart + marker.count].elementsEqual(marker) {
            let target = String(
                decoding: bytes[(markerStart + marker.count)..<targetEnd], as: UTF8.self)
            guard let targetID = fileIDsByName[target] else { continue }
            var scanner = ReverseScanner(bytes: bytes, nameStart: prefix.count, end: markerStart)
            guard scanner.popCount() != nil, scanner.pop(Self.ofDelimiter),
                let found = scanner.popCount(), scanner.pop(delimiter)
            else { continue }
            let holder = scanner.remainder
            let holderID = fileIDsByName[holder]
            if holderIsTarget, holderID == nil { continue }
            return ForeignBlocks(
                target: target, targetID: targetID, found: found, holder: holder,
                holderID: holderID, holderIsTarget: holderIsTarget)
        }
        return nil
    }

    /// Phase-weighted, monotonic progress. The engine restarts its percentage for every phase
    /// (and per `.par2` volume during Loading), so raw fractions would jump the bar backwards
    /// many times per run; each phase maps into a fixed segment and the result never decreases.
    /// (A phase-labeled progress event is a candidate Phase 3 upgrade.)
    private static let progressSegments: [(prefix: String, start: Double, end: Double)] = [
        ("Loading: ", 0.00, 0.05),
        ("Scanning: ", 0.05, 0.45),  // remapped to (0.90, 1.0) once the repair phase starts
        ("Constructing: ", 0.45, 0.50),
        ("Solving: ", 0.50, 0.55),
        ("Repairing: ", 0.55, 0.90),
        ("Processing: ", 0.55, 0.90),
    ]

    private mutating func monotonicProgress(of line: String) -> Double? {
        for segment in Self.progressSegments where line.hasPrefix(segment.prefix) {
            let value = line.dropFirst(segment.prefix.count)
            guard value.hasSuffix("%"), let percent = Double(value.dropLast()) else { return nil }
            let fraction = min(max(percent / 100, 0), 1)
            var (start, end) = (segment.start, segment.end)
            if segment.prefix == "Scanning: ", repairPhaseStarted {
                (start, end) = (0.90, 1.0)  // post-repair re-verify
            }
            lastProgress = max(lastProgress, start + fraction * (end - start))
            return lastProgress
        }
        return nil
    }

    /// `You need N more recovery blocks to be able to repair.`
    private static func neededBlocks(of line: String) -> Int? {
        guard line.hasPrefix("You need "),
            line.hasSuffix(" more recovery blocks to be able to repair.")
        else { return nil }
        return Int(line.dropFirst("You need ".count).prefix(while: \.isNumber))
    }

    /// A non-recovery ("other") file is never part of the recovery verdict and can't be
    /// repaired, so whatever the engine prints about it, its row stays "not in set" — never a
    /// dangling "checking"/"missing". `present` records a line confirming it is there intact.
    private mutating func otherFileStatus(_ id: UUID, present: Bool) -> EngineEvent {
        if present { nonRecoveryPresent.insert(id) }
        return .fileStatusChanged(id: id, status: .notInSet)
    }

    /// Holds a damaged/missing target for the verdict. Rename-satisfied targets stay renamed:
    /// scan parallelism can deliver the match line before the donor target's own
    /// damaged/missing line. Non-recovery files are never held — this is the only way into the
    /// pending sets, so `settlePending` never gives one a recovery status or a count.
    private mutating func markPending(_ name: String, missing: Bool) -> [EngineEvent] {
        let id = fileIDsByName[name]
        if let id { reportedIDs.insert(id) }
        if let id, nonRecoveryIDs.contains(id) { return [otherFileStatus(id, present: false)] }
        guard !renamedTargets.contains(name) else { return [] }
        if missing {
            pendingMissing.insert(name)
        } else {
            pendingDamaged.insert(name)
        }
        guard let id else { return [] }
        return [.fileStatusChanged(id: id, status: .checking)]
    }

    private mutating func settlePending(damaged: FileStatus, missing: FileStatus)
        -> [EngineEvent]
    {
        var events: [EngineEvent] = []
        var settled: Set<UUID> = []
        for (names, status) in [(pendingDamaged, damaged), (pendingMissing, missing)] {
            for name in names {
                if let id = fileIDsByName[name] {
                    events.append(.fileStatusChanged(id: id, status: status))
                    settled.insert(id)
                }
            }
        }
        // Counts follow the final statuses: the session keeps a count only on a
        // damaged/missing row.
        let needs = blocksNeeded(for: settled)
        for id in needs.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            events.append(.fileBlocksNeeded(id: id, blocks: needs[id] ?? 0))
        }
        pendingDamaged.removeAll()
        pendingMissing.removeAll()
        // The phase is over; the post-repair re-verify (if any) tallies afresh.
        blocksFoundInOwnFile.removeAll()
        ownCountIsMixed.removeAll()
        blocksFoundElsewhere.removeAll()
        unattributedBlocks = 0
        engineShortfall = nil
        reportedIDs.removeAll()
        return events
    }

    /// A file's need and the bracket the scan leaves it in.
    struct NeedEstimate: Equatable {
        var need: Int
        let floor: Int
        let ceiling: Int
    }

    /// Needs for the files a verdict settles. The scan only brackets them: the engine counts
    /// blocks again when it finds them in a second file (an interrupted repair's `name.1`, a
    /// partial copy), and "several target files" lines don't say whose blocks they found. So
    /// each estimate starts at the file's blocks minus its best single source, then moves
    /// within its bracket until the files add up to the engine's own exact shortfall — which
    /// pins it exactly when only one settled file is ambiguous.
    ///
    /// It stays an estimate otherwise. When several files share duplicate-content blocks (a
    /// set of volumes with large all-zero runs is the common case), the engine credits those
    /// blocks to whichever file its scan reached first, so its own per-file numbers — and
    /// these counts with them — can sit on the wrong row. Distinguishing them needs the set's
    /// own slice checksums, which this parser does not read.
    private func blocksNeeded(for ids: Set<UUID>) -> [UUID: Int] {
        var estimates: [UUID: NeedEstimate] = [:]
        for id in ids {
            // A PAR2 set holds at most 32768 source blocks; only a hostile description asks
            // for more, and these totals get summed below.
            guard let blocks = blockCounts[id] else { continue }
            let total = min(max(blocks, 0), CreateOptions.maxSourceBlocks)
            let own = blocksFoundInOwnFile[id] ?? 0
            let elsewhere = blocksFoundElsewhere[id] ?? []
            let bestSource = max(own, elsewhere.max() ?? 0)
            let surelyFound = max(ownCountIsMixed.contains(id) ? 0 : own, elsewhere.max() ?? 0)
            let possiblyFound = own + elsewhere.reduce(0, +) + unattributedBlocks
            estimates[id] = NeedEstimate(
                need: max(0, total - bestSource),
                floor: max(0, total - possiblyFound),
                ceiling: max(0, total - surelyFound))
        }
        if let engineShortfall {
            Self.reconcile(&estimates, toTotal: engineShortfall)
        }
        return estimates.mapValues(\.need)
    }

    /// Moves the estimates within their brackets until they sum to `total`, sharing the
    /// correction in proportion to each file's room (largest remainders take the leftover
    /// blocks). A total outside the brackets means the scan reported something this parser
    /// didn't account for, and the estimates stand.
    static func reconcile(_ estimates: inout [UUID: NeedEstimate], toTotal total: Int) {
        let ids = estimates.keys.sorted { $0.uuidString < $1.uuidString }
        let values = ids.compactMap { estimates[$0] }
        guard values.reduce(0, { $0 + $1.floor }) <= total,
            total <= values.reduce(0, { $0 + $1.ceiling })
        else { return }
        let gap = total - values.reduce(0) { $0 + $1.need }
        guard gap != 0 else { return }
        let room = values.map { gap > 0 ? $0.ceiling - $0.need : $0.need - $0.floor }
        let totalRoom = room.reduce(0, +)
        var shares = room.map { Int(Double(abs(gap)) * Double($0) / Double(totalRoom)) }
        shares = zip(shares, room).map { min($0, $1) }
        var leftover = abs(gap) - shares.reduce(0, +)
        let byRemainder = room.indices.sorted {
            let a = Double(abs(gap)) * Double(room[$0]) / Double(totalRoom) - Double(shares[$0])
            let b = Double(abs(gap)) * Double(room[$1]) / Double(totalRoom) - Double(shares[$1])
            return a != b ? a > b : $0 < $1
        }
        while leftover > 0 {
            var gave = false
            for index in byRemainder where leftover > 0 && shares[index] < room[index] {
                shares[index] += 1
                leftover -= 1
                gave = true
            }
            if !gave { break }
        }
        for (index, id) in ids.enumerated() {
            estimates[id]?.need += gap > 0 ? shares[index] : -shares[index]
        }
    }
}

/// Consumes an engine line's UTF-8 bytes from the right, never reaching into the fixed prefix;
/// whatever is left between the prefix and the cursor is the filename (if the line has one).
private struct ReverseScanner {
    let bytes: [UInt8]
    /// First byte after the fixed prefix (`Target: "`, `File: "`, `You have `).
    let nameStart: Int
    private(set) var end: Int

    init(bytes: [UInt8], nameStart: Int, end: Int? = nil) {
        self.bytes = bytes
        self.nameStart = nameStart
        self.end = end ?? bytes.count
    }

    /// Consumes `literal` when the unread bytes end with it.
    mutating func pop(_ literal: [UInt8]) -> Bool {
        let start = end - literal.count
        guard start >= nameStart, bytes[start..<end].elementsEqual(literal) else { return false }
        end = start
        return true
    }

    /// Consumes a trailing run of ASCII digits — a block count, which the engine prints as a
    /// u32 (anything larger is not an engine number and fails the parse).
    mutating func popCount() -> Int? {
        var start = end
        while start > nameStart, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[start - 1])
        {
            start -= 1
        }
        guard start < end,
            let value = UInt32(String(decoding: bytes[start..<end], as: UTF8.self))
        else { return nil }
        end = start
        return Int(value)
    }

    /// The unread bytes after the prefix: the filename once every fixed part is popped.
    var remainder: String { String(decoding: bytes[nameStart..<end], as: UTF8.self) }
}
