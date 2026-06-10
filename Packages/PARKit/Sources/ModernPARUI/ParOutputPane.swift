import SwiftUI

/// Collapsible "Show/Hide par Output" pane showing the raw engine log lines. (ARCHITECTURE.md §7.2)
public struct ParOutputPane: View {
    let lines: [String]
    public init(lines: [String]) { self.lines = lines }

    public var body: some View {
        ScrollView {
            Text(lines.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: 80, maxHeight: 160)
        .background(.background.secondary)
    }
}
