import Foundation
import ModernPARCore

/// Translates engine intents into par2cmdline-turbo CLI arguments:
/// `c|v|r [options] <par2file> [files]` — the exact contract MacPAR deLuxe's `par2SL` already
/// used, so the option mapping is a near-direct port. Used by `HelperProcessEngine`; the
/// embedded engine passes the same values through the Par2Shim ABI instead. (ARCHITECTURE.md §1.1)
public enum ArgumentBuilder {
    /// The leading par2 command verb for a given session mode.
    public static func command(for mode: SessionRoute.Mode) -> String? {
        switch mode {
        case .verifyRepair: return "v"  // verify; "r" when repairing
        case .createSet: return "c"
        case .extractArchive: return nil  // handled by ArchiveExtractor, not par2
        }
    }

    /// Arguments for a verify (`repair == false`) or repair (`repair == true`) run.
    /// `extraFiles` are the folder's data files, scanned for misnamed/renamed data —
    /// the `par2 r set.par2 *` pattern. `threads` 0 = automatic (`-t` omitted).
    public static func verifyRepair(
        par2Path: String,
        repair: Bool,
        extraFiles: [String] = [],
        threads: UInt32 = 0
    ) -> [String] {
        var arguments = [repair ? "r" : "v"]
        if threads > 0 { arguments.append("-t\(threads)") }
        // "--" terminates option parsing so a par2 file or data file whose name starts
        // with "-" cannot be misread as a flag.
        arguments.append("--")
        arguments.append(par2Path)
        arguments.append(contentsOf: extraFiles)
        return arguments
    }

    public static func build(for route: SessionRoute) -> [String] {
        guard let verb = command(for: route.mode) else { return [] }
        return [verb]
    }
}
