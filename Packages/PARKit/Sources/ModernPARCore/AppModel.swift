import Foundation
import Observation

/// App-wide observable model: settings, recents, and the injected PAR2 engine.
///
/// The engine is injected (Phase 0 wires `MockEngine`; Phase 2 swaps in `EmbeddedEngine` — with
/// `HelperProcessEngine` as fallback — behind the same `PAR2Engine` protocol) so the UI never
/// names a concrete engine.
@MainActor
@Observable
public final class AppModel {
    public var settings: Settings
    public var recents: RecentsStore
    /// One-by-one multi-open processing (doc-01 §5.6) — fresh windows enqueue their auto-run
    /// here unless `SimultaneousProcessing` is on.
    public let openQueue = MultiOpenQueue()
    public var par2Engine: any PAR2Engine
    /// The PAR2 creator (EmbeddedEngine in the app; nil in previews). Injected behind the
    /// protocol so Core/UI stay engine-module-free. (ROADMAP Phase 6)
    public var par2Creator: (any Par2Creator)?
    /// The native PAR1 creator (Par1CreateEngine in the app; ROADMAP Phase 8).
    public var par1Creator: (any Par2Creator)?

    /// The author engine for a create window's kind.
    public func creator(for kind: ParKind) -> (any Par2Creator)? {
        kind == .par1 ? par1Creator : par2Creator
    }
    /// The RAR extractor (RARExtractor from ArchiveKit in the app; nil where extraction is
    /// unavailable, e.g. previews). Injected behind the protocol so Core/UI stay C++-free.
    /// (ARCHITECTURE.md §2; ROADMAP Phase 4)
    public var archiveExtractor: (any ArchiveExtractor)?
    /// The zip extractor (ZipExtractor via system libarchive; ROADMAP Phase 5).
    public var zipExtractor: (any ArchiveExtractor)?

    /// The extractor for a post-processing rule's action (nil for the open actions, which
    /// never chain into an engine run).
    public func extractor(for action: PostProcessRule.Action) -> (any ArchiveExtractor)? {
        switch action {
        case .builtInUnrar: return archiveExtractor
        case .builtInUnzip: return zipExtractor
        case .openInFinder, .openWithApp: return nil
        }
    }

    /// The extractor that handles this archive URL's type (drop/open routing).
    public func extractor(forArchiveAt url: URL) -> (any ArchiveExtractor)? {
        if ArchiveFileTypes.isRARArchive(url) { return archiveExtractor }
        if ArchiveFileTypes.isZipArchive(url) { return zipExtractor }
        return nil
    }

    /// Folds the persisted Unrar preferences into one run's engine options, captured by value
    /// on the main actor. An `.ask` destination is resolved to a concrete folder by the UI
    /// before the run starts; unattended runs never ask, so they fall back beside the archive.
    /// The UI attaches the encoding-picker prompt before handing these to the engine.
    public func makeExtractOptions() -> ExtractOptions {
        let destination: ExtractDestination
        switch settings.unrarDestinationChoice {
        case .besideArchive:
            destination = .besideArchive
        case .ask:
            destination = settings.unattendedOperation ? .besideArchive : .ask
        case .fixed:
            // A missing/never-set bookmark degrades to beside-the-archive rather than failing
            // the run.
            destination =
                settings.unrarDestinationBookmark.map { .fixed(bookmark: $0) } ?? .besideArchive
        }
        return ExtractOptions(
            destination: destination,
            keepBrokenFiles: settings.keepBrokenFiles,
            segmentDisposal: settings.segmentDisposal,
            filenameEncoding: settings.filenameEncodingPreference)
    }

    /// Routes created by a user action DURING THIS LAUNCH. Only these auto-run the
    /// open → verify → repair loop; windows restored by the system re-carry their persisted
    /// route but must never auto-fire a destructive repair without consent. (ROADMAP Phase 3)
    private var freshRouteIDs: Set<UUID> = []

    public init(
        par2Engine: any PAR2Engine,
        par2Creator: (any Par2Creator)? = nil,
        par1Creator: (any Par2Creator)? = nil,
        archiveExtractor: (any ArchiveExtractor)? = nil,
        zipExtractor: (any ArchiveExtractor)? = nil,
        settings: Settings = Settings(),
        recents: RecentsStore = RecentsStore()
    ) {
        self.par2Engine = par2Engine
        self.par2Creator = par2Creator
        self.par1Creator = par1Creator
        self.archiveExtractor = archiveExtractor
        self.zipExtractor = zipExtractor
        self.settings = settings
        self.recents = recents
    }

    /// Builds the route for a user-opened file or folder, minting the security-scoped
    /// bookmarks immediately (dropped/dock URLs lose their grant otherwise). Archives
    /// route to the extraction flow; everything else to verify/repair.
    public func makeRoute(opening url: URL) -> SessionRoute {
        let isDirectory =
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if !isDirectory, ArchiveFileTypes.isArchive(url) {
            return makeRoute(extracting: url)
        }
        var route = SessionRoute(mode: .verifyRepair, autoRepair: settings.autoRepair)
        if isDirectory {
            route.folderBookmark = try? ScopedAccess.bookmark(for: url)
        } else {
            route.anchorBookmark = try? ScopedAccess.bookmark(for: url)
        }
        freshRouteIDs.insert(route.id)
        return route
    }

    /// Builds an extraction route for a RAR archive (Cmd-U, Finder open, drop).
    public func makeRoute(extracting url: URL) -> SessionRoute {
        var route = SessionRoute(mode: .extractArchive)
        route.anchorBookmark = try? ScopedAccess.bookmark(for: url)
        freshRouteIDs.insert(route.id)
        return route
    }

    /// True exactly once per launch per route — the auto-run gate.
    public func consumeFreshness(of routeID: UUID) -> Bool {
        freshRouteIDs.remove(routeID) != nil
    }
}
