import Testing

@testable import ModernPARCore

/// Asserts the icon + recoverable mapping for every state in the MacPAR deLuxe status catalog
/// (doc-01 §2.2–2.3) — the Phase 1 exit criterion for the status model.
struct StatusCatalogTests {

    @Test func iconMappingMatchesTheOriginalCatalog() {
        #expect(FileStatus.ok.icon == .ok)
        #expect(FileStatus.recovered.icon == .ok)
        #expect(FileStatus.renamed(from: "old").icon == .ok)  // "OK after renaming"
        #expect(FileStatus.recoverableMissing.icon == .recoverable)
        #expect(FileStatus.recoverableCorrupt.icon == .recoverable)
        #expect(FileStatus.possibleError.icon == .recoverable)
        #expect(FileStatus.unrecoverableMissing.icon == .error)
        #expect(FileStatus.unrecoverableCorrupt.icon == .error)
        #expect(FileStatus.notInSet.icon == .notInVolumeSet)
        #expect(FileStatus.pending.icon == .neutral)
        #expect(FileStatus.checking.icon == .neutral)
    }

    @Test func recoverableFlagMatchesTheOriginalDistinction() {
        let recoverable: [FileStatus] = [
            .recoverableMissing, .recoverableCorrupt, .possibleError,
        ]
        let notRecoverable: [FileStatus] = [
            .pending, .checking, .ok, .recovered, .renamed(from: "x"),
            .unrecoverableMissing, .unrecoverableCorrupt, .notInSet,
        ]
        for status in recoverable { #expect(status.isRecoverable, "\(status)") }
        for status in notRecoverable { #expect(!status.isRecoverable, "\(status)") }
    }

    @Test func terminalOKStatesAreStickyAcrossRetry() {
        #expect(FileStatus.ok.isTerminalOK)
        #expect(FileStatus.recovered.isTerminalOK)
        #expect(!FileStatus.recoverableCorrupt.isTerminalOK)
        #expect(!FileStatus.pending.isTerminalOK)
    }

    @Test func greenEndStatesMatchTheOriginalStatusLineColors() {
        let green: [DocStatus] = [.allFilesOK, .restoredSuccessfully, .restoredWithRenames]
        let notGreen: [DocStatus] = [
            .waitingToStart, .checking, .repairing, .repairNeeded,
            .needMoreRecovery(blocks: 3),
            .onlyNonRecoverableMissing, .notValid, .internalError,
        ]
        for status in green { #expect(status.isGreenEndState, "\(status)") }
        for status in notGreen { #expect(!status.isGreenEndState, "\(status)") }
    }
}
