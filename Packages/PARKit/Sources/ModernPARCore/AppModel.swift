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
    public var par2Engine: any PAR2Engine
    /// The archive extractor (RARExtractor from ArchiveKit in the app; nil where extraction
    /// is unavailable, e.g. previews). Injected behind the protocol so Core/UI stay C++-free.
    /// (ARCHITECTURE.md §2; ROADMAP Phase 4)
    public var archiveExtractor: (any ArchiveExtractor)?

    /// Routes created by a user action DURING THIS LAUNCH. Only these auto-run the
    /// open → verify → repair loop; windows restored by the system re-carry their persisted
    /// route but must never auto-fire a destructive repair without consent. (ROADMAP Phase 3)
    private var freshRouteIDs: Set<UUID> = []

    public init(
        par2Engine: any PAR2Engine,
        archiveExtractor: (any ArchiveExtractor)? = nil,
        settings: Settings = Settings(),
        recents: RecentsStore = RecentsStore()
    ) {
        self.par2Engine = par2Engine
        self.archiveExtractor = archiveExtractor
        self.settings = settings
        self.recents = recents
    }

    /// Builds the route for a user-opened file or folder, minting the security-scoped
    /// bookmarks immediately (dropped/dock URLs lose their grant otherwise). RAR archives
    /// route to the extraction flow; everything else to verify/repair.
    public func makeRoute(opening url: URL) -> SessionRoute {
        let isDirectory =
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if !isDirectory, ArchiveFileTypes.isRARArchive(url) {
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
