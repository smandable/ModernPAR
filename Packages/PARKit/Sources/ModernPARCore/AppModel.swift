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

    public init(
        par2Engine: any PAR2Engine,
        settings: Settings = Settings(),
        recents: RecentsStore = RecentsStore()
    ) {
        self.par2Engine = par2Engine
        self.settings = settings
        self.recents = recents
    }
}
