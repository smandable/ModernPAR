import Foundation

/// The archive-extraction seam. Concrete extractors (`RARExtractor`, `ZipExtractor`) arrive in
/// Phase 4 inside `ArchiveKit`, where the C++ interop is quarantined; Core/UI only ever see this
/// protocol so they stay C++-free despite the `.Cxx` interop flag's propagation (Swift #66156).
/// (ARCHITECTURE.md §2, §6)
public protocol ArchiveExtractor: Sendable {
    func extract(
        _ archive: SessionRoute,
        options: ExtractOptions,
        password: any PasswordProvider,
        conflicts: any ConflictResolver
    ) -> AsyncStream<EngineEvent>
}

/// Everything a single extraction run needs from the preferences, captured BY VALUE on the
/// main actor when the run starts — the engine never reads settings off-main. Defaults here
/// are the safe engine-level defaults; the UI overlays the user's persisted choices.
/// (ROADMAP Phase 7)
public struct ExtractOptions: Sendable {
    public var destination: ExtractDestination
    /// Keep files that fail their checksum instead of deleting them (doc-01 §5.4).
    public var keepBrokenFiles: Bool
    /// What happens to the archive's volumes after a SUCCESSFUL extraction. Applies to the
    /// RAR volume set (the original's Unrar-tab semantics); zip archives are never touched.
    public var segmentDisposal: SegmentDisposal
    /// How legacy (pre-RAR5) entry names that are not valid UTF-8 are decoded.
    public var filenameEncoding: FilenameEncodingPreference
    /// Consulted when `filenameEncoding` is `.automatic` and names need a non-UTF-8 decode;
    /// nil falls back to lossy UTF-8.
    public var encodingPicker: (any FilenameEncodingPicker)?

    public init(
        destination: ExtractDestination = .besideArchive,
        keepBrokenFiles: Bool = false,
        segmentDisposal: SegmentDisposal = .leave,
        filenameEncoding: FilenameEncodingPreference = .automatic,
        encodingPicker: (any FilenameEncodingPicker)? = nil
    ) {
        self.destination = destination
        self.keepBrokenFiles = keepBrokenFiles
        self.segmentDisposal = segmentDisposal
        self.filenameEncoding = filenameEncoding
        self.encodingPicker = encodingPicker
    }
}

/// How legacy RAR entry names are decoded when they are not valid UTF-8 (doc-01 §3.7;
/// the original's `PrefFilenameEncoding`). RAR5 names are always UTF-8.
public enum FilenameEncodingPreference: Sendable, Equatable {
    /// UTF-8; when names fail to decode, consult the run's `FilenameEncodingPicker`.
    case automatic
    /// Always decode non-UTF-8 names with this IANA charset (e.g. "windows-1251").
    case fixed(ianaName: String)
}

/// One candidate interpretation offered by the encoding-selection prompt: the charset and a
/// preview of an affected file name decoded with it (the original's EncodingSelection table).
public struct FilenameEncodingCandidate: Sendable, Equatable {
    public let ianaName: String
    public let localizedName: String
    public let preview: String

    public init(ianaName: String, localizedName: String, preview: String) {
        self.ianaName = ianaName
        self.localizedName = localizedName
        self.preview = preview
    }
}

/// The UI's encoding-selection sheet ("Some file names contain special characters…").
/// Returns the chosen candidate's IANA name, or nil to fall back to lossy UTF-8.
public protocol FilenameEncodingPicker: Sendable {
    func chooseEncoding(candidates: [FilenameEncodingCandidate]) async -> String?
}

/// "Prompt once, reuse for the whole archive." The UI supplies cached/typed passwords on demand,
/// matching UnRAR's `UCM_NEEDPASSWORDW` callback. (ARCHITECTURE.md §6)
public protocol PasswordProvider: Sendable {
    func password(forVolume name: String) async -> String?
}

/// Decides what happens when extraction output would land on an existing item. The UI's resolver
/// presents the ask-dialog (or auto-answers from the preference); returning `.ask` or `.cancel`
/// cancels the placement. (ROADMAP Phase 4 "destination-conflict policy")
public protocol ConflictResolver: Sendable {
    func resolve(conflictAt url: URL) async -> ConflictPolicy
}

public enum ExtractDestination: Sendable {
    case besideArchive  // default
    case ask  // prompt for a folder
    case fixed(bookmark: Data)  // a configured fixed destination folder
}

/// What to do when an item to be extracted already exists on disk. The raw values persist the
/// "default answer" preference (`existingUnrarDestinationAction`, doc-01 §5.4).
/// `.overwriteAll` is a per-run ANSWER only (the dialog's "Overwrite All" — the broker
/// remembers it for the rest of the run); it is never offered as a stored default.
public enum ConflictPolicy: String, Sendable {
    case ask
    case overwrite
    case overwriteAll
    case keepBoth
    case cancel
}
