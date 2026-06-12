import ModernPARCore
import SwiftUI

/// Inline help covering the core flows — the original shipped a Help book; ModernPAR keeps
/// it in-app (no WebKit, no external book). Reachable from Help ▸ ModernPAR Help (⌘?).
/// (ROADMAP Phase 8)
public struct HelpView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("ModernPAR Help")
                    .font(.title.bold())

                section(
                    "Verifying and repairing",
                    """
                    Open a .par2 or .par file (⌘O), drop it on a window or the Dock icon, or \
                    double-click it in Finder. ModernPAR verifies the set's files immediately \
                    and — when "Repair automatically" is on — restores damaged or missing \
                    files from the recovery data. Files that only need their name fixed are \
                    renamed. Damaged originals are kept beside the restored files with a \
                    ".1" suffix. PAR2 sets repair through the embedded par2cmdline-turbo \
                    engine; PAR1 sets (.par/.pNN) repair through ModernPAR's own native \
                    engine — no Rosetta involved.
                    """)

                section(
                    "Extracting archives",
                    """
                    Extract RAR and zip archives with ⌘U, by dropping them, or automatically \
                    after a successful check (see Post-processing). Any volume of a \
                    multi-part set works — extraction starts from the set's first volume, \
                    including name.001 splits and self-extracting .exe archives. \
                    Password-protected and encrypted-header archives prompt once per \
                    archive. The Unrar preferences control where output lands, what happens \
                    on name conflicts, and whether the archive segments are kept after a \
                    successful extraction.
                    """)

                section(
                    "Post-processing rules",
                    """
                    After a set verifies or repairs successfully, the first rule (top to \
                    bottom) whose file-name pattern matches a file in the set fires — one \
                    rule per set. Rules extract with the built-in Unrar/Unzip engines, open \
                    the matched file, or hand it to an application of your choice. Manage \
                    rules in Settings ▸ Post-processing; the built-in Unrar rule is always \
                    last and cannot be removed. Trigger rules manually with Operation ▸ \
                    Apply Rule when automatic post-processing is off.
                    """)

                section(
                    "Creating recovery sets",
                    """
                    File ▸ New PAR 2 Set (⇧⌘S) or New PAR 1 Set opens a build window: add \
                    files (all from one folder), pick the redundancy (PAR2) or the number \
                    of parity volumes (PAR1), and Create. The recovery files are written \
                    beside the data they protect and verify cleanly in other PAR tools.
                    """)

                section(
                    "Preferences",
                    """
                    ModernPAR ▸ Settings (⌘,) mirrors the original's six panes: Basic \
                    (automatic repair, par-file cleanup, unattended operation), Par 1 and \
                    Par 2 creation defaults, Unrar (destination, conflicts, segments, \
                    legacy file-name encodings), Post-processing rules, and Other \
                    (one-by-one vs simultaneous processing).
                    """)

                section(
                    "Keyboard shortcuts",
                    """
                    ⌘O Open and repair · ⌘U Extract archive · ⇧⌘S New PAR 2 set · \
                    ⌘K Verify only · ⌘R Repair again · ⌘. Cancel · ⌘, Settings
                    """)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 480, idealHeight: 640)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).foregroundStyle(.secondary)
        }
    }
}
