import Foundation

/// The archive-extraction seam. Concrete extractors (`RARExtractor`, `ZipExtractor`) arrive in
/// Phase 4 inside `ArchiveKit`, where the C++ interop is quarantined; Core/UI only ever see this
/// protocol so they stay C++-free despite the `.Cxx` interop flag's propagation (Swift #66156).
/// (ARCHITECTURE.md §2, §6)
public protocol ArchiveExtractor: Sendable {
    func extract(
        _ archive: SessionRoute,
        to destination: ExtractDestination,
        password: any PasswordProvider
    ) -> AsyncStream<EngineEvent>
}

/// "Prompt once, reuse for the whole archive." The UI supplies cached/typed passwords on demand,
/// matching UnRAR's `UCM_NEEDPASSWORDW` callback. (ARCHITECTURE.md §6)
public protocol PasswordProvider: Sendable {
    func password(forVolume name: String) async -> String?
}

public enum ExtractDestination: Sendable {
    case besideArchive  // default
    case ask  // prompt for a folder
    case fixed(bookmark: Data)  // a configured fixed destination folder
}

/// What to do when an item to be extracted already exists on disk.
public enum ConflictPolicy: Sendable {
    case ask
    case overwrite
    case keepBoth
    case cancel
}
