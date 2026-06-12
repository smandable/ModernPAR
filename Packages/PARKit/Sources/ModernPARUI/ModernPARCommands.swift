import ModernPARCore
import SwiftUI

/// Menu commands + keyboard shortcuts, mirroring the original's menu map. Pure SwiftUI — no
/// AppKit needed for menus; panels go through the powerbox helpers. (ARCHITECTURE.md §7.3)
public struct ModernPARCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.activeSession) private var activeSession
    @FocusedValue(\.fileTableActions) private var fileTableActions
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        // Edit-menu extras (doc-01 §7.1, v3.7). Copying the selected file names rides the
        // standard Edit ▸ Copy through the table's `.copyable` — no custom item needed.
        CommandGroup(after: .pasteboard) {
            Button("Select All Non-OK") {
                fileTableActions?.selectAllNonOK()
            }
            .disabled(fileTableActions == nil || activeSession == nil)
        }

        CommandGroup(after: .newItem) {
            Button("Open and Repair…") {
                if let url = OpenSetPanel.present() {
                    openWindow(value: model.makeRoute(opening: url))
                }
            }
            .keyboardShortcut("o")

            Button("New PAR 2 Set") {
                openWindow(value: SessionRoute(mode: .createSet))
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            // PAR1 authoring rides the native RS engine (ROADMAP Phase 8; the original's
            // onNewPar1:).
            Button("New PAR 1 Set") {
                openWindow(value: SessionRoute(mode: .createSet, createsPar1: true))
            }

            Button("Extract Archive…") {
                if let url = OpenArchivePanel.present() {
                    openWindow(value: model.makeRoute(extracting: url))
                }
            }
            .keyboardShortcut("u")
        }

        CommandMenu("Operation") {
            // Always verify-only — the deliberate no-side-effects check, distinct from the
            // toolbar Verify which follows the auto-repair preference. Disabled for archive
            // sessions: running the PAR2 engine against a .rar anchor is never meaningful.
            Button("Verify Only") {
                activeSession?.requestVerify(using: model.par2Engine, autoRepair: false)
            }
            .keyboardShortcut("k")
            .disabled(par2CommandsUnavailable)

            Button("Repair Again") {
                activeSession?.requestVerify(using: model.par2Engine, autoRepair: true)
            }
            .keyboardShortcut("r")
            .disabled(par2CommandsUnavailable)

            Button("Cancel Operation") {
                activeSession?.cancel()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(activeSession?.isBusy != true)

            Divider()

            // The original's Process ▸ Apply Rule: run post-processing manually — the path
            // for when "Automatically post-process" is off. (doc-01 §4; ROADMAP Phase 5)
            Button("Apply Rule") {
                guard let activeSession else { return }
                PostProcessor.apply(session: activeSession, model: model, manual: true)
            }
            .disabled(par2CommandsUnavailable)
        }

        // In-app help instead of a Help book (ROADMAP Phase 8).
        CommandGroup(replacing: .help) {
            Button("ModernPAR Help") {
                openWindow(id: "modernpar-help")
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }

    /// Verify/Repair require a non-archive anchor and an idle session — running the PAR2
    /// engine against a .rar/.zip anchor (e.g. after a chained extraction moved the anchor to
    /// the payload) is never meaningful and would wipe the extraction results. Reads the
    /// session's cached flag: menu validation must never sniff file bytes. (Phase 8 review)
    private var par2CommandsUnavailable: Bool {
        guard let session = activeSession, session.anchorURL != nil, !session.isBusy
        else { return true }
        return session.anchorIsArchive
    }
}
