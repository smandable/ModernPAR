import ModernPARCore
import SwiftUI

/// The file list: status icon, name, size, blocks-needed. SwiftUI `Table` at the PAR2 32 768-row
/// limit is the top UI performance risk (ARCHITECTURE.md §7.2) — stable ids + equatable rows +
/// event coalescing in `OperationSession` are the mitigations; an `NSTableView` representable is
/// the escape hatch kept in reserve.
public struct FileTable: View {
    let rows: [FileEntry]
    @Binding var selection: Set<UUID>
    /// Column order/visibility/width persist app-wide (ROADMAP Phase 7 "column-width
    /// persistence"; the original's NSTableView autosave).
    @AppStorage("FileTableColumns")
    private var columnCustomization: TableColumnCustomization<FileEntry>

    public init(rows: [FileEntry], selection: Binding<Set<UUID>>) {
        self.rows = rows
        self._selection = selection
    }

    public var body: some View {
        Table(rows, selection: $selection, columnCustomization: $columnCustomization) {
            TableColumn("") { row in
                StatusIconImage(icon: row.status.icon)
            }
            .width(24)
            .customizationID("status")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Name", value: \.name)
                .customizationID("name")

            TableColumn("Size") { row in
                Text(row.sizeBytes.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 90)
            .customizationID("size")

            TableColumn("Blocks needed") { row in
                Text(row.blocksNeeded == 0 ? "—" : row.blocksNeeded.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 100)
            .customizationID("blocksNeeded")
        }
        // Edit ▸ Copy (⌘C) on a focused table copies the selected file names — the
        // original's "Copy selected file names to clipboard" (v3.7; doc-01 §7.1).
        .copyable(rows.filter { selection.contains($0.id) }.map(\.name))
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No PAR set open",
                    systemImage: "doc.badge.gearshape",
                    description: Text("Open a .par2 file to verify and repair, or drop one here.")
                )
            }
        }
    }
}

/// Reaches the focused window's file table from the Edit menu (Select All Non-OK).
public struct FileTableActions {
    public let selectAllNonOK: () -> Void
    public init(selectAllNonOK: @escaping () -> Void) {
        self.selectAllNonOK = selectAllNonOK
    }
}

extension FocusedValues {
    @Entry public var fileTableActions: FileTableActions?
}
