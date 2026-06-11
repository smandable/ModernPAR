import AppKit
import ModernPARCore
import SwiftUI

/// The one-time "grant this folder" powerbox flow: opening a single `.par2` grants only that
/// file, but verify/repair reads and writes the whole folder. An `NSOpenPanel` pre-pointed at
/// the parent IS the grant mechanism under the sandbox. (ARCHITECTURE.md §5.2; ROADMAP Phase 3)
@MainActor
public enum FolderGrantPanel {
    /// Returns the granted folder URL, or nil if the user declined.
    public static func present(suggestedFolder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggestedFolder
        panel.message =
            "ModernPAR needs access to this folder to read the set's files and write its output (repaired files or extracted archives)."
        panel.prompt = "Grant Access"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Open panel for PAR sets: `.par2` / `.par` files or a folder containing a set.
@MainActor
public enum OpenSetPanel {
    public static func present() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message =
            "Choose a .par2 / .par file, a .rar/.zip archive, or a folder containing a set."
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Open panel for archives (Cmd-U). Any volume of a RAR set works — extraction normalizes
/// to the first volume. (ROADMAP Phase 4–5)
@MainActor
public enum OpenArchivePanel {
    public static func present() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .rar archive (any volume of a multi-part set) or a .zip file."
        panel.prompt = "Extract"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Lets menu commands reach the key window's session (Cmd-., Repair Again…). (ROADMAP Phase 3)
extension FocusedValues {
    @Entry public var activeSession: OperationSession?
}
