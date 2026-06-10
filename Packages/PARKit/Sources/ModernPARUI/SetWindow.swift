import ModernPARCore
import SwiftUI
import UniformTypeIdentifiers

/// One window per `SessionRoute`; owns the window's `OperationSession`. (ARCHITECTURE.md §7.2)
public struct SetWindow: View {
    @Environment(AppModel.self) private var model
    @State private var session = OperationSession()
    @State private var showOutput = false
    @State private var showOpenPanel = false

    let route: SessionRoute?
    public init(route: SessionRoute?) { self.route = route }

    /// Openable types: .par2, PAR1 .par, or a folder containing a set.
    private static let parTypes: [UTType] = [
        UTType(filenameExtension: "par2"),
        UTType(filenameExtension: "par"),
        .folder,
    ].compactMap { $0 }

    public var body: some View {
        VStack(spacing: 0) {
            if let set = session.parSet {
                SetHeader(set: set)
                Divider()
            }
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
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            session.open(url)
            return true
        }
        .fileImporter(
            isPresented: $showOpenPanel,
            allowedContentTypes: Self.parTypes
        ) { result in
            if case .success(let url) = result { session.open(url) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showOpenPanel = true
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open a .par2 / .par file or a folder containing a set")
                .disabled(session.isBusy)

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
