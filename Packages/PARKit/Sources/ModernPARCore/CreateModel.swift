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

    public init() {}

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
        options.validationErrors(fileSizes: fileSizes)
    }
    public var canCreate: Bool { !items.isEmpty && validationErrors.isEmpty }

    /// Builds the engine request for an output `.par2` URL in the source folder.
    public func makeRequest(parFile: URL, folderBookmark: Data?) -> CreateRequest {
        CreateRequest(
            parFile: parFile, files: items.map(\.url), options: options,
            folderBookmark: folderBookmark)
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
