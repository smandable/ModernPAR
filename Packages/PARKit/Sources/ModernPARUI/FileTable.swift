import ModernPARCore
import SwiftUI

/// The file list: status icon, name, size, blocks-needed. SwiftUI `Table` at the PAR2 32 768-row
/// limit is the top UI performance risk (ARCHITECTURE.md §7.2) — stable ids + equatable rows +
/// event coalescing in `OperationSession` are the mitigations; an `NSTableView` representable is
/// the escape hatch kept in reserve.
public struct FileTable: View {
    let rows: [FileEntry]
    public init(rows: [FileEntry]) { self.rows = rows }

    public var body: some View {
        Table(rows) {
            TableColumn("") { row in
                StatusIconImage(icon: row.status.icon)
            }
            .width(24)

            TableColumn("Name", value: \.name)

            TableColumn("Size") { row in
                Text(row.sizeBytes.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 90)

            TableColumn("Blocks needed") { row in
                Text(row.blocksNeeded == 0 ? "—" : row.blocksNeeded.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 100)
        }
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
