import ModernPARCore
import SwiftUI

/// Menu commands + keyboard shortcuts, mirroring the original's menu map. Pure SwiftUI — no AppKit
/// needed for menus. (ARCHITECTURE.md §7.3)
public struct ModernPARCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open and Repair…") {
                openWindow(value: SessionRoute(mode: .verifyRepair))
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
            Button("Repair Again") {}
                .keyboardShortcut("r")
            Button("Cancel Operation") {}
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Select All Non-OK") {}
        }
    }
}
