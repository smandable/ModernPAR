import Foundation
import Par2Kit
import Testing

@testable import ModernPARCore

/// The Phase 7 preferences store: every knob persists under the original MacPAR deLuxe
/// defaults key (doc-01 §5), defaults match the original where carried over, and engine
/// options are folded from settings by value. (ROADMAP Phase 7)
@MainActor
final class SettingsTests {
    private var suiteNames: [String] = []

    /// A scratch suite so tests never touch the developer's real preferences. The domain is
    /// removed again in deinit — without that, every run leaks one plist per test into
    /// ~/Library/Preferences forever. (Phase 7 review)
    private func makeDefaults() -> UserDefaults {
        let name = "modernpar-settings-tests-\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    deinit {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
    }

    @Test func defaultsMatchTheOriginalWhereCarriedOver() {
        let settings = Settings(defaults: makeDefaults())
        #expect(settings.defaultMode == .verifyRepair)
        #expect(settings.autoRepair)
        #expect(!settings.autoDeleteParFiles)
        #expect(!settings.autoCloseAfterPostProcess)
        #expect(!settings.unattendedOperation)
        #expect(settings.par2Redundancy == 10)
        #expect(settings.par2BlockSizeAutomatic)
        #expect(settings.par2BlockSizeKB == 300)  // the original nib's default
        #expect(settings.par2LimitFileSize)
        #expect(!settings.keepBrokenFiles)
        #expect(settings.unrarDestinationChoice == .besideArchive)
        #expect(settings.conflictDefault == .ask)
        #expect(settings.segmentDisposal == .moveToTrash)  // the original's default
        #expect(settings.filenameEncodingIANAName.isEmpty)
        #expect(settings.filenameEncodingPreference == .automatic)
        #expect(settings.autoPostProcess)
        #expect(settings.postProcessRules == .standard)
        #expect(!settings.simultaneousProcessing)
        #expect(settings.showParOutput)
    }

    @Test func valuesRoundTripThroughASecondInstance() {
        let defaults = makeDefaults()
        let first = Settings(defaults: defaults)
        first.defaultMode = .createSet
        first.autoRepair = false
        first.autoDeleteParFiles = true
        first.autoCloseAfterPostProcess = true
        first.unattendedOperation = true
        first.par1VolumeMode = .fixed
        first.par1FilesPerVolume = 7
        first.par1FixedVolumeCount = 12
        first.par2Redundancy = 25
        first.par2BlockSizeAutomatic = false
        first.par2BlockSizeKB = 640
        first.par2LimitFileSize = false
        first.keepBrokenFiles = true
        first.unrarDestinationChoice = .ask
        first.conflictDefault = .overwrite
        first.segmentDisposal = .leave
        first.filenameEncodingIANAName = "windows-1251"
        first.autoPostProcess = false
        first.simultaneousProcessing = true
        first.showParOutput = false

        let second = Settings(defaults: defaults)
        #expect(second.defaultMode == .createSet)
        #expect(!second.autoRepair)
        #expect(second.autoDeleteParFiles)
        #expect(second.autoCloseAfterPostProcess)
        #expect(second.unattendedOperation)
        #expect(second.par1VolumeMode == .fixed)
        #expect(second.par1FilesPerVolume == 7)
        #expect(second.par1FixedVolumeCount == 12)
        #expect(second.par2Redundancy == 25)
        #expect(!second.par2BlockSizeAutomatic)
        #expect(second.par2BlockSizeKB == 640)
        #expect(!second.par2LimitFileSize)
        #expect(second.keepBrokenFiles)
        #expect(second.unrarDestinationChoice == .ask)
        #expect(second.conflictDefault == .overwrite)
        #expect(second.segmentDisposal == .leave)
        #expect(second.filenameEncodingIANAName == "windows-1251")
        #expect(second.filenameEncodingPreference == .fixed(ianaName: "windows-1251"))
        #expect(!second.autoPostProcess)
        #expect(second.simultaneousProcessing)
        #expect(!second.showParOutput)
    }

    @Test func originalDefaultsKeysAreUsed() {
        let defaults = makeDefaults()
        let settings = Settings(defaults: defaults)
        settings.autoDeleteParFiles = true
        settings.autoCloseAfterPostProcess = true
        settings.unattendedOperation = true
        settings.par2Redundancy = 42
        settings.keepBrokenFiles = true
        settings.autoPostProcess = false
        settings.simultaneousProcessing = true
        settings.defaultMode = .createSet
        #expect(defaults.bool(forKey: "AutoDeletePnn"))
        #expect(defaults.bool(forKey: "AutoCloseDocument"))
        #expect(defaults.bool(forKey: "UnattendedOperation"))
        #expect(defaults.integer(forKey: "Par2Redundancy") == 42)
        #expect(defaults.bool(forKey: "KeepBrokenFiles"))
        #expect(defaults.object(forKey: "AutoPostProcess") as? Bool == false)
        #expect(defaults.bool(forKey: "SimultaneousProcessing"))
        #expect(defaults.string(forKey: "DefaultPar") == "createSet")
    }

    @Test func segmentDisposalPersistsAcrossTheTwoOriginalKeys() {
        let defaults = makeDefaults()
        let settings = Settings(defaults: defaults)

        settings.segmentDisposal = .deletePermanently
        #expect(defaults.bool(forKey: "AutoDeleteSeg"))
        #expect(defaults.string(forKey: "DeleteSegOption") == "delete")
        #expect(Settings(defaults: defaults).segmentDisposal == .deletePermanently)

        settings.segmentDisposal = .leave
        #expect(defaults.object(forKey: "AutoDeleteSeg") as? Bool == false)
        #expect(Settings(defaults: defaults).segmentDisposal == .leave)

        settings.segmentDisposal = .moveToTrash
        #expect(defaults.bool(forKey: "AutoDeleteSeg"))
        #expect(defaults.string(forKey: "DeleteSegOption") == "trash")
        #expect(Settings(defaults: defaults).segmentDisposal == .moveToTrash)
    }

    @Test func legacyKeepBrokenKeyMigratesOnce() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "unrar.keepBrokenFiles")
        let settings = Settings(defaults: defaults)
        #expect(settings.keepBrokenFiles)
        #expect(defaults.bool(forKey: "KeepBrokenFiles"))
        #expect(defaults.object(forKey: "unrar.keepBrokenFiles") == nil)
    }

    @Test func migrationNeverClobbersTheNewKey() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "KeepBrokenFiles")
        defaults.set(true, forKey: "unrar.keepBrokenFiles")
        let settings = Settings(defaults: defaults)
        #expect(!settings.keepBrokenFiles)
    }

    @Test func rulesPersistAsJSONAndRoundTrip() {
        let defaults = makeDefaults()
        let first = Settings(defaults: defaults)
        var rules = first.postProcessRules
        rules.rules.insert(
            PostProcessRule(name: "Music", pattern: "*.flac", action: .builtInUnzip), at: 0)
        first.postProcessRules = rules

        let second = Settings(defaults: defaults)
        #expect(second.postProcessRules == rules)
        #expect(second.postProcessRules.rules.first?.name == "Music")
    }

    @Test func corruptStoredRulesFallBackToStandard() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: Settings.Keys.rules)
        #expect(Settings(defaults: defaults).postProcessRules == .standard)
    }

    @Test func par2CreateOptionsClampOutOfRangeStoredValues() {
        let defaults = makeDefaults()
        defaults.set(0, forKey: "Par2Redundancy")
        defaults.set(false, forKey: "Par2BlockSizeChoice")
        defaults.set(9_999_999, forKey: "Par2BlockSize")
        var options = Settings(defaults: defaults).par2CreateOptions
        #expect(options.redundancyPercent == 1)
        #expect(options.blockSize == .kilobytes(419_430))

        defaults.set(1000, forKey: "Par2Redundancy")
        defaults.set(true, forKey: "Par2BlockSizeChoice")
        options = Settings(defaults: defaults).par2CreateOptions
        #expect(options.redundancyPercent == 100)
        #expect(options.blockSize == .automatic)
    }

    @Test func par2CreateOptionsReflectTheTab() {
        let settings = Settings(defaults: makeDefaults())
        settings.par2Redundancy = 15
        settings.par2BlockSizeAutomatic = false
        settings.par2BlockSizeKB = 512
        settings.par2LimitFileSize = false
        let options = settings.par2CreateOptions
        #expect(options.redundancyPercent == 15)
        #expect(options.blockSize == .kilobytes(512))
        #expect(options.fileScheme == .uniform)
    }

    // MARK: - Folding settings into one run's engine options

    @Test func extractOptionsCarryThePersistedChoices() {
        let model = AppModel(par2Engine: MockEngine(), settings: Settings(defaults: makeDefaults()))
        model.settings.keepBrokenFiles = true
        model.settings.segmentDisposal = .leave
        model.settings.filenameEncodingIANAName = "ibm866"
        let options = model.makeExtractOptions()
        #expect(options.keepBrokenFiles)
        #expect(options.segmentDisposal == .leave)
        #expect(options.filenameEncoding == .fixed(ianaName: "ibm866"))
        if case .besideArchive = options.destination {
        } else {
            Issue.record("expected besideArchive, got \(options.destination)")
        }
    }

    @Test func fixedDestinationWithoutABookmarkFallsBackBesideTheArchive() {
        let model = AppModel(par2Engine: MockEngine(), settings: Settings(defaults: makeDefaults()))
        model.settings.unrarDestinationChoice = .fixed
        model.settings.unrarDestinationBookmark = nil
        if case .besideArchive = model.makeExtractOptions().destination {
        } else {
            Issue.record("a stale fixed destination must degrade to beside-the-archive")
        }
    }

    @Test func unattendedRunsNeverAskForADestination() {
        let model = AppModel(par2Engine: MockEngine(), settings: Settings(defaults: makeDefaults()))
        model.settings.unrarDestinationChoice = .ask
        model.settings.unattendedOperation = true
        if case .besideArchive = model.makeExtractOptions().destination {
        } else {
            Issue.record("unattended + ask must fall back to beside-the-archive")
        }
    }
}
