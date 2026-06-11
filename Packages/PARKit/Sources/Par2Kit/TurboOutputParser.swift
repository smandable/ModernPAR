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
public struct TurboOutputParser {
    /// Maps the names the ENGINE prints (Description-packet names after the engine's
    /// par2→local translation) to the native parser's row ids. Names the map doesn't know
    /// are reported with log lines only.
    private let fileIDsByName: [String: UUID]
    /// Whether this run repairs after verify — "Repair is required." means "now repairing"
    /// only then; in verify-only runs the engine prints it but stops after the verdict.
    private let repairsAutomatically: Bool

    private var pendingDamaged: Set<String> = []
    private var pendingMissing: Set<String> = []
    /// Files the repair pass will restore (set when the repairable verdict arrives).
    private var awaitingRepair: Set<String> = []
    private var repairPhaseStarted = false
    private var lastProgress = 0.0

    public private(set) var repairedCount = 0
    public private(set) var unrecoverableCount = 0
    /// Files the repairable verdict covered (damaged + missing at verify time).
    public private(set) var recoverableCount = 0
    /// Targets whose data was found under another name ("is a match for") — repair renames.
    public private(set) var renamedCount = 0
    private var renamedTargets: Set<String> = []

    public init(fileIDsByName: [String: UUID], repairsAutomatically: Bool) {
        self.fileIDsByName = fileIDsByName
        self.repairsAutomatically = repairsAutomatically
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
            renamedTargets.insert(target)
            pendingMissing.remove(target)
            pendingDamaged.remove(target)
            // The Target:-variant means the wrong-named file is itself a roster target whose
            // own slot is rename-satisfied too (the swap case prints one line for both).
            if line.hasPrefix("Target: "), fileIDsByName[foundName] != nil {
                renamedTargets.insert(foundName)
                pendingMissing.remove(foundName)
                pendingDamaged.remove(foundName)
                if let id = fileIDsByName[foundName] {
                    events.append(.fileStatusChanged(id: id, status: renameStatus(from: target)))
                }
            }
            renamedCount = renamedTargets.count
            if let id = fileIDsByName[target] {
                events.append(.fileStatusChanged(id: id, status: renameStatus(from: foundName)))
            }
            return events
        }

        if let (name, disposition) = Self.targetLine(line) {
            switch disposition {
            case .found:
                if let id = fileIDsByName[name] {
                    // "found" after the repairable verdict is the re-verify of a restored file.
                    if awaitingRepair.remove(name) != nil {
                        repairedCount += 1
                        events.append(.fileStatusChanged(id: id, status: .recovered))
                    } else {
                        events.append(.fileStatusChanged(id: id, status: .ok))
                    }
                }
            case .damaged:
                // Rename-satisfied targets stay renamed: scan parallelism can deliver the
                // match line before the donor target's own damaged/missing line.
                if !renamedTargets.contains(name) {
                    pendingDamaged.insert(name)
                    if let id = fileIDsByName[name] {
                        events.append(.fileStatusChanged(id: id, status: .checking))
                    }
                }
            case .missing:
                if !renamedTargets.contains(name) {
                    pendingMissing.insert(name)
                    if let id = fileIDsByName[name] {
                        events.append(.fileStatusChanged(id: id, status: .checking))
                    }
                }
            }
            return events
        }

        if line.hasPrefix("All files are correct") {
            events.append(.docStatusChanged(.allFilesOK))
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

    private mutating func settlePending(damaged: FileStatus, missing: FileStatus)
        -> [EngineEvent]
    {
        var events: [EngineEvent] = []
        for name in pendingDamaged {
            if let id = fileIDsByName[name] {
                events.append(.fileStatusChanged(id: id, status: damaged))
            }
        }
        for name in pendingMissing {
            if let id = fileIDsByName[name] {
                events.append(.fileStatusChanged(id: id, status: missing))
            }
        }
        pendingDamaged.removeAll()
        pendingMissing.removeAll()
        return events
    }
}
