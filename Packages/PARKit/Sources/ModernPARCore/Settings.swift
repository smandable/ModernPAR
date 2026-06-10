import Foundation
import Observation

/// Mirrors the original's Preferences panes. Phase 7 fleshes this out and persists to defaults;
/// for now it is a plain observable with the most-used knobs.
@MainActor
@Observable
public final class Settings {
    /// Default document type when the program starts (the original's "Default document type").
    public var defaultMode: SessionRoute.Mode = .verifyRepair
    /// "Limit CPU cores" preference → par2 `-t<n>`. `nil` means use all cores.
    public var cpuCoreLimit: Int?
    /// Automatically post-process / repair after a verify finds repairable damage.
    public var autoRepair: Bool = true
    /// Move par/par2/pNN files to Trash after a successful verify/repair.
    public var autoDeleteParFiles: Bool = false

    public init() {}
}
