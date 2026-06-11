import Foundation
import ModernPARCore
import Testing

@testable import Par2Kit

/// Pins the parser's string contract and the regressions from the Phase 2 adversarial review:
/// engine-translated roster names, verify-only terminal status, "Repair Failed." settling,
/// monotonic progress, and delimiter-hostile filenames.
struct TurboOutputParserTests {

    private let idA = UUID()
    private let idB = UUID()

    private func events(
        _ lines: [(String, Bool)], map: [String: UUID]? = nil, repairs: Bool = true
    ) -> [EngineEvent] {
        var parser = TurboOutputParser(
            fileIDsByName: map ?? ["a.bin": idA, "b.bin": idB],
            repairsAutomatically: repairs)
        return lines.flatMap { parser.consume($0.0, isError: $0.1) }
    }

    private func statuses(in events: [EngineEvent]) -> [UUID: [FileStatus]] {
        var trail: [UUID: [FileStatus]] = [:]
        for case .fileStatusChanged(let id, let status) in events {
            trail[id, default: []].append(status)
        }
        return trail
    }

    private func docStatuses(in events: [EngineEvent]) -> [DocStatus] {
        events.compactMap {
            if case .docStatusChanged(let status) = $0 { return status }
            return nil
        }
    }

    @Test func verifyOnlyRunEndsAwaitingConsentNotRepairing() {
        let all = events(
            [
                ("Target: \"a.bin\" - damaged. Found 9 of 10 data blocks.", false),
                ("Repair is required.", false),
                ("Repair is possible.", false),
            ], repairs: false)
        #expect(docStatuses(in: all) == [.repairNeeded])
        #expect(statuses(in: all)[idA]?.last == .recoverableCorrupt)
    }

    @Test func repairingRunEmitsRepairingThenRestored() {
        let all = events([
            ("Target: \"a.bin\" - damaged. Found 9 of 10 data blocks.", false),
            ("Repair is required.", false),
            ("Repair is possible.", false),
            ("Verifying repaired files:", false),
            ("Target: \"a.bin\" - found.", false),
            ("Repair complete.", false),
        ])
        #expect(docStatuses(in: all) == [.repairing, .restoredSuccessfully])
        #expect(statuses(in: all)[idA]?.last == .recovered)
    }

    @Test func repairFailedSettlesRowsAndDocStatus() {
        let all = events([
            ("Target: \"a.bin\" - damaged. Found 9 of 10 data blocks.", false),
            ("Repair is required.", false),
            ("Repair is possible.", false),
            ("Verifying repaired files:", false),
            ("Target: \"a.bin\" - damaged. Found 9 of 10 data blocks.", false),
            ("Repair Failed.", true),
        ])
        #expect(docStatuses(in: all).last == .internalError)
        #expect(statuses(in: all)[idA]?.last == .unrecoverableCorrupt)
    }

    @Test func progressIsMonotonicAcrossPhasesAndVolumes() {
        let lines: [(String, Bool)] = [
            ("Loading: 90.0%", false),
            ("Loading: 10.0%", false),  // second volume restarts — must not go backwards
            ("Scanning: 50.0%", false),
            ("Scanning: 10.0%", false),
            ("Repair is required.", false),
            ("Repair is possible.", false),
            ("Constructing: 50.0%", false),
            ("Solving: 100.0%", false),
            ("Repairing: 30.0%", false),
            ("Verifying repaired files:", false),
            ("Scanning: 40.0%", false),  // post-repair re-verify maps to the final segment
        ]
        let fractions = events(lines).compactMap { event -> Double? in
            if case .overallProgress(let fraction) = event { return fraction }
            return nil
        }
        #expect(fractions == fractions.sorted(), "progress went backwards: \(fractions)")
        #expect(fractions.last ?? 0 > 0.9)
    }

    @Test func needMoreBlocksAndUnrecoverableSettling() {
        let all = events([
            ("Target: \"a.bin\" - damaged. Found 9 of 10 data blocks.", false),
            ("Target: \"b.bin\" - missing.", false),
            ("Repair is not possible.", false),
            ("You need 4 more recovery blocks to be able to repair.", false),
        ])
        #expect(docStatuses(in: all) == [.needMoreRecovery(blocks: 4)])
        #expect(statuses(in: all)[idA]?.last == .unrecoverableCorrupt)
        #expect(statuses(in: all)[idB]?.last == .unrecoverableMissing)
    }

    @Test func filenamesContainingTheDelimiterParse() {
        // Backwards delimiter match: the name is everything up to the LAST '" - '.
        let trapID = UUID()
        let all = events(
            [("Target: \"a\" - found. b.bin\" - missing.", false)],
            map: ["a\" - found. b.bin": trapID])
        #expect(statuses(in: all)[trapID]?.last == .checking)  // pending until the verdict
    }

    @Test func renamedFileLifecycle() {
        // Misnamed data found during verify: target b.bin's data lives in wrong-name.bin.
        let all = events([
            ("Target: \"a.bin\" - found.", false),
            ("File: \"wrong-name.bin\" - is a match for \"b.bin\".", false),
            ("Repair is required.", false),
            ("1 file(s) have the wrong name.", false),
            ("Repair is possible.", false),
            ("Repair complete.", false),
        ])
        #expect(statuses(in: all)[idB]?.last == .renamed(from: "wrong-name.bin"))
        #expect(docStatuses(in: all).last == .restoredWithRenames)
    }

    @Test func renamedTargetVariantAlsoParses() {
        // The engine prints "Target:" instead of "File:" when the wrong-named file is itself
        // a roster target; the rename must not be double-reported as damaged/missing.
        let all = events([
            ("Target: \"b.bin\" - missing.", false),
            ("Target: \"a.bin\" - is a match for \"b.bin\".", false),
            ("Repair is required.", false),
            ("Repair is possible.", false),
            ("Repair complete.", false),
        ])
        #expect(statuses(in: all)[idB]?.last == .renamed(from: "a.bin"))
        #expect(docStatuses(in: all).last == .restoredWithRenames)
    }

    @Test func verifyOnlyRenameStaysNeedsAttentionNotOK() {
        // The file is still under the wrong name on disk when a verify-only run ends — its
        // row must not show the OK icon until a repair actually renames it.
        let all = events(
            [
                ("File: \"wrong-name.bin\" - is a match for \"b.bin\".", false),
                ("Repair is required.", false),
                ("Repair is possible.", false),
            ], repairs: false)
        #expect(statuses(in: all)[idB]?.last == .possibleError)
        #expect(docStatuses(in: all).last == .repairNeeded)
    }

    @Test func swappedTargetsBothReportRenamed() {
        // A full swap prints ONE Target-variant match line but renames both files.
        let all = events([
            ("Target: \"a.bin\" - is a match for \"b.bin\".", false),
            ("Repair is required.", false),
            ("2 file(s) have the wrong name.", false),
            ("Repair is possible.", false),
            ("Repair complete.", false),
        ])
        #expect(statuses(in: all)[idA]?.last == .renamed(from: "b.bin"))
        #expect(statuses(in: all)[idB]?.last == .renamed(from: "a.bin"))
        #expect(docStatuses(in: all).last == .restoredWithRenames)
    }

    @Test func hostileMatchShapedLinesDoNotFireTheRenameBranch() {
        // Partial-match lines share the match line's shape; a filename containing the
        // delimiter must not spuriously count as a rename (the split is roster-validated).
        let all = events([
            (
                "Target: \"evil\" - is a match for \"trap\" - damaged. Found 1 of 2 data blocks from \"b.bin\".",
                false
            ),
            ("Target: \"a.bin\" - damaged. Found 9 of 10 data blocks.", false),
            ("Repair is required.", false),
            ("Repair is possible.", false),
            ("Verifying repaired files:", false),
            ("Target: \"a.bin\" - found.", false),
            ("Repair complete.", false),
        ])
        // No rename happened: terminal status must be plain restoredSuccessfully.
        #expect(docStatuses(in: all).last == .restoredSuccessfully)
    }

    @Test func matchThenDamagedDoesNotDowngradeTheRename() {
        // Parallel scanning can deliver the match line before the donor target's own damaged
        // line; the rename-satisfied target must stay .renamed, not regress to .recovered.
        let all = events([
            ("Target: \"a.bin\" - is a match for \"b.bin\".", false),
            ("Target: \"b.bin\" - damaged. Found 1 of 3 data blocks.", false),
            ("Repair is required.", false),
            ("Repair is possible.", false),
            ("Repair complete.", false),
        ])
        #expect(statuses(in: all)[idB]?.last == .renamed(from: "a.bin"))
    }

    @Test func errorLinesAreTaggedInTheLog() {
        let all = events([("Main packet not found.", true)])
        let logLines = all.compactMap { event -> String? in
            if case .logLine(let line) = event { return line }
            return nil
        }
        #expect(logLines == ["[err] Main packet not found."])
    }

    @Test func engineNameTranslationMatchesTheEngine() {
        // descriptionpacket.cpp TranslateFilenameFromPar2ToLocal on macOS at nlNormal:
        #expect(EngineRunSupport.engineDisplayName(for: "plain.bin") == "plain.bin")
        #expect(EngineRunSupport.engineDisplayName(for: "back\\slash.bin") == "back/slash.bin")
        #expect(EngineRunSupport.engineDisplayName(for: "ctl\u{01}x.bin") == "ctl%01x.bin")
        #expect(EngineRunSupport.engineDisplayName(for: "naïve-ü.bin") == "naïve-ü.bin")
    }
}
