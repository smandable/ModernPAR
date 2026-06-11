import ModernPARCore
import SwiftUI

/// Menu commands + keyboard shortcuts, mirroring the original's menu map. Pure SwiftUI — no
/// AppKit needed for menus; panels go through the powerbox helpers. (ARCHITECTURE.md §7.3)
public struct ModernPARCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.activeSession) private var activeSession
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open and Repair…") {
                if let url = OpenSetPanel.present() {
                    openWindow(value: model.makeRoute(opening: url))
                }
            }
            .keyboardShortcut("o")

            Button("Create PAR Set…") {
                openWindow(value: SessionRoute(mode: .createSet))
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Unrar Archive…") {
                openWindow(value: SessionRoute(mode: .extractArchive))
            }
            .keyboardShortcut("u")
        }

        CommandMenu("Operation") {
            // Always verify-only — the deliberate no-side-effects check, distinct from the
            // toolbar Verify which follows the auto-repair preference.
            Button("Verify Only") {
                activeSession?.requestVerify(using: model.par2Engine, autoRepair: false)
            }
            .keyboardShortcut("k")
            .disabled(activeSession?.anchorURL == nil || activeSession?.isBusy != false)

            Button("Repair Again") {
                activeSession?.requestVerify(using: model.par2Engine, autoRepair: true)
            }
            .keyboardShortcut("r")
            .disabled(activeSession?.anchorURL == nil || activeSession?.isBusy != false)

            Button("Cancel Operation") {
                activeSession?.cancel()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(activeSession?.isBusy != true)
        }
    }
}
