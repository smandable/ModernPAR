import Foundation
import Observation

/// Where unrar/unzip place their output (the original's "Where must unrar create the
/// extracted items", doc-01 §5.4).
public enum UnrarDestinationChoice: String, Sendable, Codable {
    case besideArchive  // "Inside the folder where the rar archive is" (default)
    case ask  // "Always let me choose a location"
    case fixed  // "Inside this folder:" — the folder bookmark is stored separately
}

/// What happens to the archive's volumes ("segments") after a successful extraction
/// (doc-01 §5.4 "After successful unrar"; keys `AutoDeleteSeg` + `DeleteSegOption`).
public enum SegmentDisposal: String, Sendable, Codable {
    case leave
    case moveToTrash  // the original's default
    case deletePermanently  // armed only past an explicit warning in the Settings UI
}

/// The app's preferences, persisted to `UserDefaults` under the ORIGINAL MacPAR deLuxe
/// defaults key wherever one is carried over, so doc-01 §5 stays the authoritative mapping.
/// All values are read on the main actor; anything an engine needs off-main travels by value
/// in `ExtractOptions`, captured when the run starts. (ROADMAP Phase 7)
@MainActor
@Observable
public final class Settings {
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Basic (doc-01 §5.1)

    /// Default document type when the program starts (`DefaultPar`). The original chose
    /// PAR1 vs PAR2 for the untitled create document; ModernPAR's launch window is either
    /// the verify/repair document or a create document (PAR1 create arrives in Phase 8).
    public var defaultMode: SessionRoute.Mode {
        didSet {
            defaults.set(
                defaultMode == .createSet ? "createSet" : "verifyRepair", forKey: Keys.defaultPar)
        }
    }
    /// Automatically repair after a verify finds repairable damage (ModernPAR's own knob —
    /// the original always repaired).
    public var autoRepair: Bool {
        didSet { defaults.set(autoRepair, forKey: Keys.autoRepair) }
    }
    /// Move the set's par files to the Trash after a successful restore (`AutoDeletePnn`).
    public var autoDeleteParFiles: Bool {
        didSet { defaults.set(autoDeleteParFiles, forKey: Keys.autoDeletePnn) }
    }
    /// Close the par window after automatic post-processing succeeds (`AutoCloseDocument`).
    public var autoCloseAfterPostProcess: Bool {
        didSet { defaults.set(autoCloseAfterPostProcess, forKey: Keys.autoCloseDocument) }
    }
    /// Run unattended: no dialogs, safe defaults (keep-both on conflict, decline passwords),
    /// errors surface as user notifications (`UnattendedOperation`).
    public var unattendedOperation: Bool {
        didSet { defaults.set(unattendedOperation, forKey: Keys.unattendedOperation) }
    }

    // MARK: - Par1 (doc-01 §5.2 — stored now, consumed by Phase 8's native PAR1 create)

    /// How many Pnn volumes a PAR1 create makes: derived from the file count, or fixed.
    public enum Par1VolumeMode: String, Sendable, Codable {
        case byFileCount
        case fixed
    }
    public var par1VolumeMode: Par1VolumeMode {
        didSet { defaults.set(par1VolumeMode.rawValue, forKey: Keys.par1VolumeMode) }
    }
    /// "Number of files per Pnn" when deriving by file count. 1…99 (`WrongNumFilesPerPARErr`).
    public var par1FilesPerVolume: Int {
        didSet { defaults.set(par1FilesPerVolume, forKey: Keys.par1FilesPerVolume) }
    }
    /// The fixed Pnn count, independent of the number of files. 0…99 (`WrongNumPARErr`).
    public var par1FixedVolumeCount: Int {
        didSet { defaults.set(par1FixedVolumeCount, forKey: Keys.par1FixedVolumeCount) }
    }

    // MARK: - Par2 create defaults (doc-01 §5.3)

    /// Default level of redundancy in percent (`Par2Redundancy`). 1…100.
    public var par2Redundancy: Int {
        didSet { defaults.set(par2Redundancy, forKey: Keys.par2Redundancy) }
    }
    /// Automatic block size vs the manual KB field (`Par2BlockSizeChoice`).
    public var par2BlockSizeAutomatic: Bool {
        didSet { defaults.set(par2BlockSizeAutomatic, forKey: Keys.par2BlockSizeChoice) }
    }
    /// Manual block size in KB (`Par2BlockSize`). 1…419430. The original's nib default: 300.
    public var par2BlockSizeKB: Int {
        didSet { defaults.set(par2BlockSizeKB, forKey: Keys.par2BlockSize) }
    }
    /// Limit the largest recovery volume to the largest data file (`Par2LimitFileSize`,
    /// par2's `-l`) vs uniform sizing (`-u`).
    public var par2LimitFileSize: Bool {
        didSet { defaults.set(par2LimitFileSize, forKey: Keys.par2LimitFileSize) }
    }

    /// The persisted Par2 tab folded into engine options — what a new create window starts
    /// from. Out-of-range stored values (hand-edited plists) are clamped to the valid bounds.
    public var par2CreateOptions: CreateOptions {
        CreateOptions(
            redundancyPercent: par2Redundancy.clamped(to: CreateOptions.redundancyRange),
            blockSize: par2BlockSizeAutomatic
                ? .automatic
                : .kilobytes(par2BlockSizeKB.clamped(to: CreateOptions.blockSizeKilobytesRange)),
            fileScheme: par2LimitFileSize ? .limitToLargest : .uniform)
    }

    // MARK: - Unrar (doc-01 §5.4)

    /// Keep files that fail their checksum instead of deleting them (`KeepBrokenFiles`;
    /// migrated from the Phase 4 key "unrar.keepBrokenFiles").
    public var keepBrokenFiles: Bool {
        didSet { defaults.set(keepBrokenFiles, forKey: Keys.keepBrokenFiles) }
    }
    /// Where extraction output lands (`chooseUnrarDestinationFolder`).
    public var unrarDestinationChoice: UnrarDestinationChoice {
        didSet {
            defaults.set(unrarDestinationChoice.rawValue, forKey: Keys.unrarDestinationChoice)
        }
    }
    /// Security-scoped bookmark for the fixed destination folder (used when the choice is
    /// `.fixed`; falls back to beside-the-archive when absent or stale).
    public var unrarDestinationBookmark: Data? {
        didSet { defaults.set(unrarDestinationBookmark, forKey: Keys.unrarDestinationBookmark) }
    }
    /// Display name of the fixed destination folder for the Settings UI.
    public var unrarDestinationDisplayName: String {
        didSet {
            defaults.set(unrarDestinationDisplayName, forKey: Keys.unrarDestinationDisplayName)
        }
    }
    /// The default answer when extraction output collides with an existing item
    /// (`existingUnrarDestinationAction`): `.ask` prompts, anything else auto-answers.
    public var conflictDefault: ConflictPolicy {
        didSet { defaults.set(conflictDefault.rawValue, forKey: Keys.conflictDefault) }
    }
    /// What happens to the RAR volumes after a successful extraction (`AutoDeleteSeg` +
    /// `DeleteSegOption`). The original's default: move to Trash.
    public var segmentDisposal: SegmentDisposal {
        didSet {
            defaults.set(segmentDisposal != .leave, forKey: Keys.autoDeleteSeg)
            defaults.set(
                segmentDisposal == .deletePermanently ? "delete" : "trash",
                forKey: Keys.deleteSegOption)
        }
    }
    /// IANA charset name for legacy (pre-RAR5) entry names that are not valid UTF-8
    /// (`PrefFilenameEncoding`). Empty = automatic: UTF-8 first, then ask.
    public var filenameEncodingIANAName: String {
        didSet { defaults.set(filenameEncodingIANAName, forKey: Keys.filenameEncoding) }
    }
    public var filenameEncodingPreference: FilenameEncodingPreference {
        filenameEncodingIANAName.isEmpty
            ? .automatic : .fixed(ianaName: filenameEncodingIANAName)
    }

    // MARK: - Post-processing (doc-01 §5.5)

    /// "Automatically post-process files after repair" (`AutoPostProcess`): a successful
    /// verify/repair chains into the first matching rule — the SABnzbd/NZBGet pipeline.
    /// Off = trigger manually via Operation ▸ Apply Rule. (ROADMAP Phase 5)
    public var autoPostProcess: Bool {
        didSet { defaults.set(autoPostProcess, forKey: Keys.autoPostProcess) }
    }
    /// Ordered post-processing rules, persisted as JSON (the original used `PostProcessRule`
    /// + `RuleDescription` arrays; the format is ours, the semantics are theirs).
    public var postProcessRules: PostProcessRules {
        didSet {
            defaults.set(try? JSONEncoder().encode(postProcessRules), forKey: Keys.rules)
        }
    }

    // MARK: - Other (doc-01 §5.6)

    /// When opening multiple files at once: process them one by one (default; queue) or
    /// simultaneously (`SimultaneousProcessing`).
    public var simultaneousProcessing: Bool {
        didSet { defaults.set(simultaneousProcessing, forKey: Keys.simultaneousProcessing) }
    }
    /// Whether new windows show the par output pane (owner preference: visible by default;
    /// the toolbar toggle persists the last choice).
    public var showParOutput: Bool {
        didSet { defaults.set(showParOutput, forKey: Keys.showParOutput) }
    }
    /// Last par-window size — the DEFAULT size for new windows (the system restores the
    /// frames of restored windows itself). 0 = never resized.
    public var lastWindowWidth: Double {
        didSet { defaults.set(lastWindowWidth, forKey: Keys.lastWindowWidth) }
    }
    public var lastWindowHeight: Double {
        didSet { defaults.set(lastWindowHeight, forKey: Keys.lastWindowHeight) }
    }
    /// "Limit CPU cores" preference → par2 `-t<n>`. `nil` means use all cores. [later] —
    /// not surfaced in the UI yet, so not persisted.
    public var cpuCoreLimit: Int?

    // MARK: - Init / keys

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // One-time migration: Phase 4 stored keep-broken under its own key before the
        // doc-01 §5 mapping landed.
        if defaults.object(forKey: Keys.keepBrokenFiles) == nil,
            let legacy = defaults.object(forKey: Keys.legacyKeepBroken) as? Bool
        {
            defaults.set(legacy, forKey: Keys.keepBrokenFiles)
            defaults.removeObject(forKey: Keys.legacyKeepBroken)
        }

        defaultMode =
            (defaults.string(forKey: Keys.defaultPar) == "createSet") ? .createSet : .verifyRepair
        autoRepair = Self.bool(Keys.autoRepair, default: true, in: defaults)
        autoDeleteParFiles = Self.bool(Keys.autoDeletePnn, default: false, in: defaults)
        autoCloseAfterPostProcess = Self.bool(Keys.autoCloseDocument, default: false, in: defaults)
        unattendedOperation = Self.bool(Keys.unattendedOperation, default: false, in: defaults)

        par1VolumeMode =
            defaults.string(forKey: Keys.par1VolumeMode).flatMap(Par1VolumeMode.init(rawValue:))
            ?? .byFileCount
        par1FilesPerVolume = Self.int(Keys.par1FilesPerVolume, default: 10, in: defaults)
        par1FixedVolumeCount = Self.int(Keys.par1FixedVolumeCount, default: 9, in: defaults)

        par2Redundancy = Self.int(Keys.par2Redundancy, default: 10, in: defaults)
        par2BlockSizeAutomatic = Self.bool(Keys.par2BlockSizeChoice, default: true, in: defaults)
        par2BlockSizeKB = Self.int(Keys.par2BlockSize, default: 300, in: defaults)
        par2LimitFileSize = Self.bool(Keys.par2LimitFileSize, default: true, in: defaults)

        keepBrokenFiles = Self.bool(Keys.keepBrokenFiles, default: false, in: defaults)
        unrarDestinationChoice =
            defaults.string(forKey: Keys.unrarDestinationChoice)
            .flatMap(UnrarDestinationChoice.init(rawValue:)) ?? .besideArchive
        unrarDestinationBookmark = defaults.data(forKey: Keys.unrarDestinationBookmark)
        unrarDestinationDisplayName =
            defaults.string(forKey: Keys.unrarDestinationDisplayName) ?? ""
        conflictDefault =
            defaults.string(forKey: Keys.conflictDefault).flatMap(ConflictPolicy.init(rawValue:))
            ?? .ask
        if Self.bool(Keys.autoDeleteSeg, default: true, in: defaults) {
            segmentDisposal =
                defaults.string(forKey: Keys.deleteSegOption) == "delete"
                ? .deletePermanently : .moveToTrash
        } else {
            segmentDisposal = .leave
        }
        filenameEncodingIANAName = defaults.string(forKey: Keys.filenameEncoding) ?? ""

        autoPostProcess = Self.bool(Keys.autoPostProcess, default: true, in: defaults)
        if let data = defaults.data(forKey: Keys.rules),
            let stored = try? JSONDecoder().decode(PostProcessRules.self, from: data)
        {
            postProcessRules = stored
        } else {
            postProcessRules = .standard
        }

        simultaneousProcessing = Self.bool(
            Keys.simultaneousProcessing, default: false, in: defaults)
        showParOutput = Self.bool(Keys.showParOutput, default: true, in: defaults)
        lastWindowWidth = defaults.double(forKey: Keys.lastWindowWidth)
        lastWindowHeight = defaults.double(forKey: Keys.lastWindowHeight)
    }

    /// The original MacPAR deLuxe defaults keys (doc-01 §5), plus ModernPAR's own where the
    /// original had no equivalent.
    public enum Keys {
        public static let defaultPar = "DefaultPar"
        public static let autoRepair = "AutoRepair"
        public static let autoDeletePnn = "AutoDeletePnn"
        public static let autoCloseDocument = "AutoCloseDocument"
        public static let unattendedOperation = "UnattendedOperation"
        public static let par1VolumeMode = "Par1VolumeMode"
        public static let par1FilesPerVolume = "Par1FilesPerVolume"
        public static let par1FixedVolumeCount = "Par1FixedVolumeCount"
        public static let par2Redundancy = "Par2Redundancy"
        public static let par2BlockSizeChoice = "Par2BlockSizeChoice"
        public static let par2BlockSize = "Par2BlockSize"
        public static let par2LimitFileSize = "Par2LimitFileSize"
        public static let keepBrokenFiles = "KeepBrokenFiles"
        public static let legacyKeepBroken = "unrar.keepBrokenFiles"
        public static let unrarDestinationChoice = "chooseUnrarDestinationFolder"
        public static let unrarDestinationBookmark = "UnrarDestinationBookmark"
        public static let unrarDestinationDisplayName = "UnrarDestinationDisplayName"
        public static let conflictDefault = "existingUnrarDestinationAction"
        public static let autoDeleteSeg = "AutoDeleteSeg"
        public static let deleteSegOption = "DeleteSegOption"
        public static let filenameEncoding = "PrefFilenameEncoding"
        public static let autoPostProcess = "AutoPostProcess"
        public static let rules = "PostProcessRules"
        public static let simultaneousProcessing = "SimultaneousProcessing"
        public static let showParOutput = "ShowParOutput"
        public static let lastWindowWidth = "ParWindowWidth"
        public static let lastWindowHeight = "ParWindowHeight"
    }

    private static func bool(_ key: String, default value: Bool, in defaults: UserDefaults)
        -> Bool
    {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    private static func int(_ key: String, default value: Int, in defaults: UserDefaults) -> Int {
        defaults.object(forKey: key) == nil ? value : defaults.integer(forKey: key)
    }
}

extension Int {
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
