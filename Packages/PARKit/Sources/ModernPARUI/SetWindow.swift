import ModernPARCore
import SwiftUI

/// One window per `SessionRoute`; owns the window's `OperationSession`. (ARCHITECTURE.md §7.2)
public struct SetWindow: View {
    @Environment(AppModel.self) private var model
    @State private var session = OperationSession()
    @State private var showOutput = false

    let route: SessionRoute?
    public init(route: SessionRoute?) { self.route = route }

    public var body: some View {
        VStack(spacing: 0) {
            FileTable(rows: session.rows)

            if showOutput {
                Divider()
                ParOutputPane(lines: session.log)
            }

            Divider()
            StatusBar(
                docStatus: session.docStatus,
                progress: session.progress,
                isBusy: session.isBusy,
                onCancel: { session.cancel() }
            )
        }
        .frame(minWidth: 560, minHeight: 360)
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showOutput.toggle()
                } label: {
                    Label("par Output", systemImage: "text.alignleft")
                }
                .help(showOutput ? "Hide par Output" : "Show par Output")

                Button {
                    verify()
                } label: {
                    Label("Verify", systemImage: "checkmark.shield")
                }
                .disabled(session.isBusy || route == nil)
            }
        }
    }

    private func verify() {
        guard let route else { return }
        session.start(route, engine: model.par2Engine)
    }

    private var title: String {
        switch route?.mode {
        case .createSet: return "New PAR Set"
        case .extractArchive: return "Extract Archive"
        case .verifyRepair, .none: return "ModernPAR"
        }
    }
}
