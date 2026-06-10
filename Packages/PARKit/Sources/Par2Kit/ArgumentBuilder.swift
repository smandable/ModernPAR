import Foundation
import ModernPARCore

/// Translates a `SessionRoute` (and, later, a `CreateConfig`) into par2cmdline-turbo CLI arguments:
/// `c|v|r [options] <par2file> [files]` with `-b -s -r -c -f -u -l -n -m -t` — the exact contract
/// MacPAR deLuxe's `par2SL` already used. Phase 0 returns only the leading command verb; Phase 2
/// adds option mapping and file paths. (ARCHITECTURE.md §1.1)
public enum ArgumentBuilder {
    /// The leading par2 command verb for a given session mode.
    public static func command(for mode: SessionRoute.Mode) -> String? {
        switch mode {
        case .verifyRepair: return "v"  // verify; a follow-up "r" repairs if needed
        case .createSet: return "c"
        case .extractArchive: return nil  // handled by ArchiveExtractor, not par2
        }
    }

    public static func build(for route: SessionRoute) -> [String] {
        guard let verb = command(for: route.mode) else { return [] }
        return [verb]
    }
}
