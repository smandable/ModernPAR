import Foundation
import Observation

/// The build-a-set window's state: the source file list (all in one folder), the create
/// options, and the derived preview (computed block size, source/recovery block counts). Pure
/// model — the window binds to it; the engine run goes through `OperationSession.startCreate`.
/// (ROADMAP Phase 6)
@MainActor
@Observable
public final class CreateModel {
    /// One source file row.
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: URL
        public var name: String { url.lastPathComponent }
        public var url: URL { id }
        public var sizeBytes: UInt64
        public init(url: URL, sizeBytes: UInt64) {
            self.id = url
            self.sizeBytes = sizeBytes
        }
    }

    public private(set) var items: [Item] = []
    public var options = CreateOptions()
    /// The most recent rejection reason for an add attempt (cleared on a successful add).
    public private(set) var lastRejection: String?

    /// Which format this window authors. PAR2 uses `options`; PAR1 uses the volume knobs
    /// below (the original's SaveOptions panel; ROADMAP Phase 8).
    public let kind: ParKind
    /// How the PAR1 volume count is derived (doc-01 §5.2; seeded from the Par1 Settings tab).
    public var par1VolumeMode: Settings.Par1VolumeMode = .byFileCount
    /// "Number of files per Pnn" when deriving by file count. 1…99.
    public var par1FilesPerVolume = 10
    /// The fixed Pnn count, independent of the number of files. 0…99.
    public var par1FixedVolumeCount = 9

    public init(kind: ParKind = .par2) {
        self.kind = kind
    }

    /// The PAR1 volume count the current knobs produce.
    public var par1VolumeCount: Int {
        switch par1VolumeMode {
        case .fixed:
            return par1FixedVolumeCount
        case .byFileCount:
            guard !items.isEmpty, par1FilesPerVolume > 0 else { return 0 }
            return (items.count + par1FilesPerVolume - 1) / par1FilesPerVolume
        }
    }

    /// The single folder every source file must live in (nil when empty).
    public var folder: URL? { items.first?.url.deletingLastPathComponent() }

    /// A default output `.par2` name: the folder's name, or the first file's stem.
    public var defaultParName: String {
        guard let folder else { return "recovery" }
        let folderName = folder.lastPathComponent
        if !folderName.isEmpty, folderName != "/" { return folderName }
        return (items.first?.name as NSString?)?.deletingPathExtension ?? "recovery"
    }

    /// Adds files, enforcing "all in one folder" (the original's hard rule — the recovery set
    /// is folder-relative). Directories are expanded one level into their regular files.
    /// Returns the names actually added.
    @discardableResult
    public func add(_ urls: [URL]) -> [String] {
        lastRejection = nil
        let expanded = urls.flatMap { expand($0) }
        guard !expanded.isEmpty else { return [] }

        // The target folder is the existing set's folder, or the first new file's folder.
        // Resolve symlinks so e.g. /tmp and /private/tmp (or an aliased mount) compare equal.
        let targetFolder = (folder ?? expanded.first?.deletingLastPathComponent())
            .map { Self.canonicalFolder(of: $0) }
        var added: [String] = []
        for url in expanded {
            if Self.canonicalFolder(of: url.deletingLastPathComponent()) != targetFolder {
                lastRejection =
                    "All files must be in one folder. “\(url.lastPathComponent)” is in a different folder and was skipped."
                continue
            }
            guard !items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL })
            else { continue }
            items.append(Item(url: url, sizeBytes: Self.fileSize(of: url)))
            added.append(url.lastPathComponent)
        }
        items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return added
    }

    public func remove(_ ids: Set<URL>) {
        items.removeAll { ids.contains($0.id) }
    }

    public func removeAll() {
        items.removeAll()
        lastRejection = nil
    }

    // MARK: - Derived preview

    public var totalBytes: UInt64 { items.reduce(0) { $0 &+ $1.sizeBytes } }
    private var fileSizes: [UInt64] { items.map(\.sizeBytes) }

    public var effectiveBlockSize: UInt64 {
        options.effectiveBlockSize(fileSizes: fileSizes)
    }
    public var sourceBlockCount: Int {
        RecoveryMath.sourceBlockCount(fileSizes: fileSizes, blockSize: effectiveBlockSize)
    }
    public var recoveryBlockCount: Int {
        RecoveryMath.recoveryBlockCount(
            sourceBlocks: sourceBlockCount, redundancyPercent: options.redundancyPercent)
    }

    public var validationErrors: [String] {
        switch kind {
        case .par2:
            return options.validationErrors(fileSizes: fileSizes)
        case .par1:
            return par1ValidationErrors
        }
    }
    public var canCreate: Bool { !items.isEmpty && validationErrors.isEmpty }

    /// PAR1 validation, mirroring the originals' wording (doc-01 §5.2: `WrongNumPARErr`,
    /// `WrongNumFilesPerPARErr`, `TooManyFilesForPar1Err`).
    private var par1ValidationErrors: [String] {
        var errors: [String] = []
        if items.isEmpty {
            errors.append("Add at least one file to protect.")
        }
        if items.count > 255 {
            errors.append("A PAR1 set can protect at most 255 files.")
        }
        switch par1VolumeMode {
        case .fixed:
            if !(0...99).contains(par1FixedVolumeCount) {
                errors.append("The number of Pnn files must be a number between 0 and 99")
            }
        case .byFileCount:
            if !(1...99).contains(par1FilesPerVolume) {
                errors.append("The number of files must be a number between 1 and 99")
            }
        }
        let volumes = par1VolumeCount
        if volumes > 99 {
            errors.append("A PAR1 set allows at most 99 parity volumes (.p01–.p99).")
        } else if items.count + volumes > Par1RS.maxEntities {
            errors.append(
                "Files plus parity volumes cannot exceed \(Par1RS.maxEntities) (a PAR1 format limit)."
            )
        }
        return errors
    }

    /// Builds the engine request for an output `.par2`/`.par` URL in the source folder.
    public func makeRequest(parFile: URL, folderBookmark: Data?) -> CreateRequest {
        CreateRequest(
            parFile: parFile, files: items.map(\.url), options: options,
            folderBookmark: folderBookmark,
            par1VolumeCount: kind == .par1 ? par1VolumeCount : nil)
    }

    // MARK: - Helpers

    /// Expands a dropped directory into the regular files DIRECTLY inside it. Nested
    /// subdirectories are NOT recursed (the recovery set is one flat folder); when a dropped
    /// folder contains subfolders, the user is told their contents were skipped rather than
    /// silently dropping data they think is protected. (Phase 6 review)
    private func expand(_ url: URL) -> [URL] {
        let isDirectory =
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard isDirectory else { return [url] }
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        else { return [] }
        var files: [URL] = []
        var skippedSubfolder = false
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isRegularFile == true {
                files.append(entry)
            } else if values?.isDirectory == true {
                skippedSubfolder = true
            }
        }
        if skippedSubfolder {
            lastRejection =
                "Only the files directly inside “\(url.lastPathComponent)” were added — a PAR2 set covers one flat folder, so subfolders were skipped."
        }
        return files
    }

    /// Symlink-resolved folder path for comparing "same folder" (POSIX realpath; Foundation's
    /// standardizedFileURL keeps the /var alias).
    private static func canonicalFolder(of url: URL) -> String {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return url.standardizedFileURL.path
    }

    private static func fileSize(of url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            .map(UInt64.init) ?? 0
    }
}
