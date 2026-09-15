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
        _ lines: [(String, Bool)], map: [String: UUID]? = nil, counts: [UUID: Int] = [:],
        repairs: Bool = true
    ) -> [EngineEvent] {
        var parser = TurboOutputParser(
            fileIDsByName: map ?? ["a.bin": idA, "b.bin": idB], blockCounts: counts,
            repairsAutomatically: repairs)
        return lines.flatMap { parser.consume($0.0, isError: $0.1) }
    }

    private func blocksNeeded(in events: [EngineEvent]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for case .fileBlocksNeeded(let id, let blocks) in events { counts[id] = blocks }
        return counts
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

    // MARK: - Blocks needed (the column never showed a number; report of 2026-09-15)

    @Test func reportedVolumeSetCountsSettleWithTheVerdict() {
        // The report's engine lines: one volume missing, two damaged (1 and 9 blocks short).
        let part01 = UUID()
        let part03 = UUID()
        let part05 = UUID()
        let part08 = UUID()
        var parser = TurboOutputParser(
            fileIDsByName: [
                "movie.part01.rar": part01, "movie.part03.rar": part03,
                "movie.part05.rar": part05, "movie.part08.rar": part08,
            ],
            blockCounts: [part01: 100, part03: 100, part05: 100, part08: 100],
            repairsAutomatically: false)
        let scan = [
            "Target: \"movie.part01.rar\" - found.",
            "Target: \"movie.part08.rar\" - damaged. Found 91 of 100 data blocks.",
            "Target: \"movie.part03.rar\" - missing.",
            "Target: \"movie.part05.rar\" - damaged. Found 99 of 100 data blocks.",
            "Repair is required.",
            "You have 290 out of 400 data blocks available.",
        ].flatMap { parser.consume($0, isError: false) }
        #expect(blocksNeeded(in: scan).isEmpty, "counts wait for the set-level verdict")

        let verdict = parser.consume("Repair is possible.", isError: false)
        #expect(blocksNeeded(in: verdict) == [part03: 100, part05: 1, part08: 9])
        // Each count follows its row's final damaged/missing status — the session drops a
        // count that lands on a row in any other state.
        for (index, event) in verdict.enumerated() {
            guard case .fileBlocksNeeded(let id, _) = event else { continue }
            let statusFirst = verdict[..<index].contains {
                if case .fileStatusChanged(id, let status) = $0 { return status.isDamagedOrMissing }
                return false
            }
            #expect(statusFirst)
        }
    }

    @Test func unrecoverableFilesStillReportTheirCounts() {
        let all = events(
            [
                ("Target: \"a.bin\" - damaged. Found 9 of 10 data blocks.", false),
                ("Target: \"b.bin\" - missing.", false),
                ("Repair is not possible.", false),
                ("You need 4 more recovery blocks to be able to repair.", false),
            ], counts: [idA: 10, idB: 3])
        #expect(blocksNeeded(in: all) == [idA: 1, idB: 3])
        #expect(docStatuses(in: all) == [.needMoreRecovery(blocks: 4)])
    }

    @Test func blocksFoundInOtherFilesCountTowardTheirTarget() {
        // Line shapes pinned against par2cmdline (DamagedVolumeSet.foreignDamage): a target
        // whose file holds ANOTHER target's blocks, a partial copy under another name, and an
        // interrupted repair's `name.1` backup. Double-found blocks clamp at zero.
        let all = events(
            [
                ("Target: \"a.bin\" - missing.", false),
                ("Target: \"b.bin\" - damaged. Found 50 of 100 data blocks from \"a.bin\".", false),
                ("File: \"a.bin.partial\" - found 30 of 100 data blocks from \"a.bin\".", false),
                ("Repair is required.", false),
                ("Repair is possible.", false),
            ], counts: [idA: 100, idB: 100])
        // a.bin: 100 − 50 − 30 (disjoint sources, pinned by the engine's own total below).
        // b.bin's own file holds none of b.bin's blocks.
        let pinned = events(
            [
                ("Target: \"a.bin\" - missing.", false),
                ("Target: \"b.bin\" - damaged. Found 50 of 100 data blocks from \"a.bin\".", false),
                ("File: \"a.bin.partial\" - found 30 of 100 data blocks from \"a.bin\".", false),
                ("Repair is required.", false),
                ("You have 80 out of 200 data blocks available.", false),
                ("Repair is possible.", false),
            ], counts: [idA: 100, idB: 100])
        #expect(blocksNeeded(in: pinned) == [idA: 20, idB: 100])
        #expect(statuses(in: pinned)[idB]?.last == .recoverableCorrupt)
        // Without the engine's total, the best single source (50) is the estimate.
        #expect(blocksNeeded(in: all) == [idA: 50, idB: 100])
    }

    @Test func blocksCountedTwiceReconcileToTheEnginesShortfall() {
        // An interrupted repair, verbatim (review repro, 2026-09-15): the partly rewritten
        // target holds 177 blocks, its `.1` backup 1436, and the engine counts the overlap in
        // both. The sum would clamp to "—"; the engine's shortfall pins the one ambiguous file.
        let interrupted = events(
            [
                ("Target: \"a.bin\" - damaged. Found 177 of 1536 data blocks.", false),
                ("File: \"a.bin.1\" - found 1436 of 1536 data blocks from \"a.bin\".", false),
                ("Repair is required.", false),
                ("You have 1436 out of 1536 data blocks available.", false),
                ("Repair is possible.", false),
            ], counts: [idA: 1536])
        #expect(blocksNeeded(in: interrupted) == [idA: 100])

        // Disjoint sources instead: 60 in the file, the other 30 in a partial copy.
        let disjoint = events(
            [
                ("Target: \"a.bin\" - damaged. Found 60 of 100 data blocks.", false),
                ("File: \"a.tail\" - found 30 of 100 data blocks from \"a.bin\".", false),
                ("You have 90 out of 100 data blocks available.", false),
                ("Repair is possible.", false),
            ], counts: [idA: 100])
        #expect(blocksNeeded(in: disjoint) == [idA: 10])
    }

    @Test func unattributedBlocksReconcileToo() {
        // A joined file holding both damaged parts (review repro): the engine names neither.
        let all = events(
            [
                ("Target: \"a.bin\" - damaged. Found 40 of 100 data blocks.", false),
                ("Target: \"b.bin\" - missing.", false),
                ("File: \"joined.bin\" - found 160 data blocks from several target files.", false),
                ("Repair is required.", false),
                ("You have 200 out of 200 data blocks available.", false),
                ("Repair is possible.", false),
            ], counts: [idA: 100, idB: 100])
        #expect(blocksNeeded(in: all) == [idA: 0, idB: 0])
    }

    @Test func aShortfallOutsideTheBracketsLeavesTheEstimates() {
        // More shortfall than the settled files can hold means the parse missed a file; the
        // per-file numbers must not absorb it.
        let all = events(
            [
                ("Target: \"a.bin\" - damaged. Found 91 of 100 data blocks.", false),
                ("You have 50 out of 200 data blocks available.", false),
                ("Repair is possible.", false),
            ], counts: [idA: 100])
        #expect(blocksNeeded(in: all) == [idA: 9])
    }

    @Test func reconciliationSharesTheCorrectionByRoom() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        var estimates: [UUID: TurboOutputParser.NeedEstimate] = [
            a: .init(need: 50, floor: 10, ceiling: 50),
            b: .init(need: 30, floor: 0, ceiling: 30),
            c: .init(need: 7, floor: 7, ceiling: 7),  // exact: never moves
        ]
        TurboOutputParser.reconcile(&estimates, toTotal: 67)
        #expect(estimates.values.reduce(0) { $0 + $1.need } == 67)
        #expect(estimates[c]?.need == 7)
        for estimate in estimates.values {
            #expect(estimate.floor <= estimate.need && estimate.need <= estimate.ceiling)
        }
        // Room 40 vs 30 for a 20-block correction: 11.4 and 8.6 → 11 and 9.
        #expect(estimates[a]?.need == 39)
        #expect(estimates[b]?.need == 21)
    }

    @Test func blocksFromSeveralTargetsCountAsTheHoldersOwn() {
        // A damaged file also holding another incomplete target's block (an all-zero block):
        // the engine gives no per-target split, so the holder's N counts as its own.
        let all = events(
            [
                ("Target: \"b.bin\" - missing.", false),
                (
                    "Target: \"a.bin\" - damaged, found 18 data blocks from several target files.",
                    false
                ),
                ("Repair is required.", false),
                ("You have 18 out of 25 data blocks available.", false),
                ("Repair is possible.", false),
            ], counts: [idA: 20, idB: 5])
        #expect(blocksNeeded(in: all) == [idA: 2, idB: 5])
        #expect(statuses(in: all)[idA]?.last == .recoverableCorrupt)
    }

    @Test func zeroDataTargetIsDamagedNeedsEveryBlockAndCountsAsRepaired() {
        // A target holding none of its blocks prints `File: "…" - no data found.` and no
        // Target line; it used to get no status at all and end a repair as plain .ok.
        var parser = TurboOutputParser(
            fileIDsByName: ["a.bin": idA, "b.bin": idB], blockCounts: [idA: 10, idB: 3],
            repairsAutomatically: true)
        let all = [
            "File: \"a.bin\" - no data found.",
            "Target: \"b.bin\" - found.",
            "Repair is required.",
            "Repair is possible.",
            "Verifying repaired files:",
            "Target: \"a.bin\" - found.",
            "Repair complete.",
        ].flatMap { parser.consume($0, isError: false) }
        #expect(blocksNeeded(in: all) == [idA: 10])
        #expect(statuses(in: all)[idA] == [.checking, .recoverableCorrupt, .recovered])
        #expect(parser.repairedCount == 1)
    }

    @Test func perfectMatchSettlesAFileTheEngineHashedWhole() {
        // Empty files and files without slice checksums are checked by whole-file hash: the
        // engine prints `no data found`, then the perfect match — the file is intact (review
        // find: the no-data rule alone marked such files damaged).
        var parser = TurboOutputParser(
            fileIDsByName: ["empty.txt": idA, "b.bin": idB], blockCounts: [idA: 0, idB: 3],
            repairsAutomatically: true)
        let all = [
            "File: \"empty.txt\" - no data found.",
            "/Volumes/Set/empty.txt is a perfect match for empty.txt",
            "Target: \"b.bin\" - damaged. Found 2 of 3 data blocks.",
            "Repair is required.",
            "Repair is possible.",
        ].flatMap { parser.consume($0, isError: false) }
        #expect(statuses(in: all)[idA] == [.checking, .ok])
        #expect(blocksNeeded(in: all) == [idB: 1])
        #expect(parser.recoverableCount == 1)

        let intact = events(
            [
                ("File: \"empty.txt\" - no data found.", false),
                ("/Volumes/Set/empty.txt is a perfect match for empty.txt", false),
                ("All files are correct, repair is not required.", false),
            ], map: ["empty.txt": idA], counts: [idA: 0])
        #expect(statuses(in: intact)[idA]?.last == .ok)
    }

    @Test func perfectMatchUnderAnotherNameIsARename() {
        // The description name is printed RAW (a backslash stays a backslash) while Target
        // lines print the translated local name.
        let all = events(
            [
                ("Target: \"sub/a.bin\" - missing.", false),
                ("/Volumes/Set/stray copy.bin is a perfect match for sub\\a.bin", false),
                ("Repair is required.", false),
                ("Repair is possible.", false),
                ("Repair complete.", false),
            ], map: ["sub/a.bin": idA], counts: [idA: 4])
        #expect(statuses(in: all)[idA]?.last == .renamed(from: "stray copy.bin"))
        #expect(blocksNeeded(in: all).isEmpty)
        #expect(docStatuses(in: all).last == .restoredWithRenames)
    }

    @Test func noDataLinesForExtraFilesAndFoundTargetsChangeNothing() {
        let all = events(
            [
                ("Target: \"a.bin\" - found.", false),
                ("Target: \"b.bin\" - missing.", false),
                ("File: \"readme.nfo\" - no data found.", false),  // unrelated extra file
                ("File: \"a.bin\" - no data found.", false),  // a found target re-read
                ("Repair is required.", false),
                ("Repair is possible.", false),
            ], counts: [idA: 10, idB: 3])
        #expect(statuses(in: all)[idA] == [.ok])
        #expect(blocksNeeded(in: all) == [idB: 3])
    }

    @Test func filesWithoutABlockCountGetNone() {
        // Non-recovery files are left out of blockCounts: no recovery block rebuilds them.
        let all = events(
            [
                ("Target: \"a.bin\" - damaged. Found 9 of 10 data blocks.", false),
                ("Target: \"b.bin\" - missing.", false),
                ("Repair is possible.", false),
            ], counts: [idA: 10])
        #expect(blocksNeeded(in: all) == [idA: 1])
        #expect(statuses(in: all)[idB]?.last == .recoverableMissing)
    }

    @Test func renameSatisfiedTargetsGetNoCount() {
        let all = events(
            [
                ("Target: \"b.bin\" - damaged. Found 1 of 3 data blocks.", false),
                ("File: \"wrong-name.bin\" - is a match for \"b.bin\".", false),
                ("Target: \"a.bin\" - damaged. Found 9 of 10 data blocks.", false),
                ("Repair is possible.", false),
            ], counts: [idA: 10, idB: 3])
        #expect(blocksNeeded(in: all) == [idA: 1])
    }

    @Test func repairFailedCountsComeFromTheReVerifyAlone() {
        let all = events(
            [
                ("Target: \"a.bin\" - damaged. Found 5 of 10 data blocks.", false),
                ("Repair is required.", false),
                ("Repair is possible.", false),
                ("Verifying repaired files:", false),
                ("Target: \"a.bin\" - damaged. Found 8 of 10 data blocks.", false),
                ("Repair Failed.", true),
            ], counts: [idA: 10])
        let trail = all.compactMap { event -> Int? in
            if case .fileBlocksNeeded(idA, let blocks) = event { return blocks }
            return nil
        }
        #expect(trail == [5, 2], "the verdict's count, then the re-verify's — never 5 + 8")
    }

    @Test func blockCountLinesSplitHostileNamesExactly() {
        let quoteID = UUID()
        let markID = UUID()
        // Delimiter text inside a name; a combining mark that fuses with the opening quote
        // into one Character (String-level prefix checks miss it; the byte parse must not).
        let quoteName = "q\" - damaged. Found 1 of 2 data blocks."
        let markName = "\u{301}accent.bin"
        let map = ["a.bin": idA, "b.bin": idB, quoteName: quoteID, markName: markID]
        let all = events(
            [
                ("Target: \"\(quoteName)\" - damaged. Found 6 of 8 data blocks.", false),
                ("Target: \"\(markName)\" - damaged. Found 2 of 5 data blocks.", false),
                // An extra file named to impersonate a credit to a.bin: only the rightmost,
                // roster-valid split (b.bin) may be credited.
                (
                    "File: \"x\" - found 99 of 100 data blocks from \"a.bin\" - found 3 of 10 data blocks from \"b.bin\".",
                    false
                ),
                ("Target: \"a.bin\" - damaged. Found 99999999999 of 10 data blocks.", false),
                ("Target: \"b.bin\" - missing.", false),
                ("Repair is possible.", false),
            ], map: map, counts: [quoteID: 8, markID: 5, idA: 10, idB: 10])
        // a.bin's impossible count is not an engine number: no own tally, needs all 10.
        #expect(blocksNeeded(in: all) == [quoteID: 2, markID: 3, idA: 10, idB: 7])
    }

    @Test func engineNameTranslationMatchesTheEngine() {
        // descriptionpacket.cpp TranslateFilenameFromPar2ToLocal on macOS at nlNormal:
        #expect(EngineRunSupport.engineDisplayName(for: "plain.bin") == "plain.bin")
        #expect(EngineRunSupport.engineDisplayName(for: "back\\slash.bin") == "back/slash.bin")
        #expect(EngineRunSupport.engineDisplayName(for: "ctl\u{01}x.bin") == "ctl%01x.bin")
        #expect(EngineRunSupport.engineDisplayName(for: "naïve-ü.bin") == "naïve-ü.bin")
    }

    // MARK: - Non-recovery ("other") files (Main packet non-recovery set)

    private let idOther = UUID()

    /// Parser configured with `a.bin`/`b.bin` recoverable and `readme.txt` non-recovery.
    private func eventsWithOther(_ lines: [(String, Bool)], repairs: Bool = true) -> [EngineEvent] {
        var parser = TurboOutputParser(
            fileIDsByName: ["a.bin": idA, "b.bin": idB, "readme.txt": idOther],
            nonRecoveryIDs: [idOther],
            repairsAutomatically: repairs)
        return lines.flatMap { parser.consume($0.0, isError: $0.1) }
    }

    @Test func presentNonRecoveryFileStaysNotInSetAndKeepsAllFilesOK() {
        // The recoverable files verify; the non-recovery file whole-file matches (present).
        let all = eventsWithOther([
            ("Target: \"a.bin\" - found.", false),
            ("Target: \"b.bin\" - found.", false),
            ("File: \"readme.txt\" - no data found.", false),
            ("/tmp/set/readme.txt is a perfect match for readme.txt", false),
            ("All files are correct, repair is not required.", false),
        ])
        #expect(docStatuses(in: all) == [.allFilesOK])
        #expect(statuses(in: all)[idOther]?.last == .notInSet)
    }

    @Test func missingNonRecoveryFileReportsOnlyNonRecoverableMissing() {
        let all = eventsWithOther([
            ("Target: \"a.bin\" - found.", false),
            ("Target: \"b.bin\" - found.", false),
            ("Target: \"readme.txt\" - missing.", false),
            ("All files are correct, repair is not required.", false),
        ])
        #expect(docStatuses(in: all) == [.onlyNonRecoverableMissing])
        // The row stays "not in set" — never a dangling "checking"/"missing".
        #expect(statuses(in: all)[idOther] == [.notInSet])
    }

    @Test func corruptNonRecoveryFileReportsOnlyNonRecoverableMissing() {
        // Present but no whole-file match (no "perfect match" line for it).
        let all = eventsWithOther([
            ("Target: \"a.bin\" - found.", false),
            ("Target: \"b.bin\" - found.", false),
            ("File: \"readme.txt\" - no data found.", false),
            ("All files are correct, repair is not required.", false),
        ])
        #expect(docStatuses(in: all) == [.onlyNonRecoverableMissing])
        // No recoverable row is dragged into a damaged/missing state by the "other" file.
        #expect(statuses(in: all)[idA]?.last == .ok)
        #expect(statuses(in: all)[idB]?.last == .ok)
    }
}
