import Foundation

/// The user-facing PAR2 create knobs (doc-02 recommendation: surface only these, keep
/// `-c/-f/-n/-m` internal). (ROADMAP Phase 6)
public struct CreateOptions: Sendable, Equatable, Codable {
    /// How the recovery block size is chosen.
    public enum BlockSize: Sendable, Equatable, Codable {
        case automatic
        /// Manual size in KILOBYTES (the original's field; bytes = kb * 1024). 1…419430.
        case kilobytes(Int)
    }

    /// Recovery-file sizing (`-l` limit-to-largest vs `-u` uniform). doc-02; the original's
    /// "Limit file size to largest data file" vs "Uniform".
    public enum FileScheme: Sendable, Equatable, Codable {
        case limitToLargest
        case uniform
    }

    /// Recovery as a percentage of the source data. 1…100. (`-r`)
    public var redundancyPercent: Int
    public var blockSize: BlockSize
    public var fileScheme: FileScheme

    public init(
        redundancyPercent: Int = 10,
        blockSize: BlockSize = .automatic,
        fileScheme: FileScheme = .limitToLargest
    ) {
        self.redundancyPercent = redundancyPercent
        self.blockSize = blockSize
        self.fileScheme = fileScheme
    }

    // The original's validation bounds (doc-01 §4/§5; reproduced messages).
    public static let redundancyRange = 1...100
    public static let blockSizeKilobytesRange = 1...419_430
    /// PAR2 caps the source block count at 32768 and the recovery block count at 65535.
    public static let maxSourceBlocks = 32_768
    public static let maxRecoveryBlocks = 65_535

    /// Validates the options against a concrete file set; returns user-facing error messages
    /// (empty = valid). Mirrors the originals' wording. (ROADMAP Phase 6 exit criterion)
    public func validationErrors(fileSizes: [UInt64]) -> [String] {
        var errors: [String] = []
        if !Self.redundancyRange.contains(redundancyPercent) {
            errors.append("Redundancy must be between 1 and 100 percent.")
        }
        if case .kilobytes(let kb) = blockSize, !Self.blockSizeKilobytesRange.contains(kb) {
            errors.append("Block size must be between 1 and 419430 KB.")
        }
        if fileSizes.isEmpty || fileSizes.allSatisfy({ $0 == 0 }) {
            errors.append("Add at least one non-empty file to protect.")
        }
        // The source-block ceiling is checked against the EFFECTIVE block size in ALL modes
        // (effectiveBlockSize already raises an automatic or manual size to fit), so the error
        // and the window's preview never contradict each other. It can still be unfittable
        // when the set has more than 32768 separate files — no block size coalesces a file
        // below one block. (Phase 6 review)
        if !fileSizes.isEmpty, !fileSizes.allSatisfy({ $0 == 0 }) {
            let blocks = RecoveryMath.sourceBlockCount(
                fileSizes: fileSizes, blockSize: effectiveBlockSize(fileSizes: fileSizes))
            if blocks > Self.maxSourceBlocks {
                let fileCount = fileSizes.filter { $0 > 0 }.count
                errors.append(
                    fileCount > Self.maxSourceBlocks
                        ? "A PAR2 set covers at most \(Self.maxSourceBlocks) blocks, but this set has \(fileCount) files (each needs its own block). Protect fewer files per set."
                        : "This block size makes \(blocks) blocks — PAR2 allows at most \(Self.maxSourceBlocks). Use a larger block size."
                )
            }
        }
        return errors
    }

    /// Resolves the effective block size in bytes for a concrete file set: automatic derives a
    /// size targeting a healthy block count and, like a manual size, is raised until the source
    /// block count fits PAR2's 32768 ceiling. Always a positive multiple of 4.
    public func effectiveBlockSize(fileSizes: [UInt64]) -> UInt64 {
        let base: UInt64
        switch blockSize {
        case .automatic:
            base = RecoveryMath.automaticBlockSize(totalBytes: fileSizes.reduce(0, +))
        case .kilobytes(let kb):
            base = UInt64(max(1, kb)) * 1024
        }
        return RecoveryMath.blockSizeFitting(
            fileSizes: fileSizes, preferred: base, maxSourceBlocks: Self.maxSourceBlocks)
    }
}

/// A fully-specified create operation: the output `.par2` and the source files (all in one
/// folder), plus the chosen options. `folderBookmark` is the security-scoped grant for writing
/// the recovery files. (ROADMAP Phase 6)
public struct CreateRequest: Sendable {
    public var parFile: URL
    public var files: [URL]
    public var options: CreateOptions
    public var folderBookmark: Data?
    /// Set for a PAR1 create (the number of `.pNN` volumes, 0–99); nil = PAR2.
    /// (ROADMAP Phase 8 — PAR1 authoring rides the native RS code.)
    public var par1VolumeCount: Int?

    public init(
        parFile: URL, files: [URL], options: CreateOptions, folderBookmark: Data? = nil,
        par1VolumeCount: Int? = nil
    ) {
        self.parFile = parFile
        self.files = files
        self.options = options
        self.folderBookmark = folderBookmark
        self.par1VolumeCount = par1VolumeCount
    }
}

/// Authoring side of the engine seam: produces a recovery set, streaming the same
/// `EngineEvent`s as verify/repair so the window renders create with identical machinery.
/// The concrete (`EmbeddedEngine`) lives in Par2Kit and is injected, keeping Core C++-free.
/// (ARCHITECTURE.md §1.5, §6; ROADMAP Phase 6)
public protocol Par2Creator: Sendable {
    func create(_ request: CreateRequest) -> AsyncStream<EngineEvent>
}
