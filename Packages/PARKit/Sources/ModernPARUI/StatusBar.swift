import ModernPARCore
import SwiftUI

/// Bottom status line — green on an OK end-state, otherwise primary — plus the progress indicator
/// and Cancel button (Cmd-.). Reproduces the original's status area. (ARCHITECTURE.md §7.2)
public struct StatusBar: View {
    let docStatus: DocStatus
    let progress: Double
    let isBusy: Bool
    let onCancel: () -> Void

    public init(
        docStatus: DocStatus,
        progress: Double,
        isBusy: Bool,
        onCancel: @escaping () -> Void
    ) {
        self.docStatus = docStatus
        self.progress = progress
        self.isBusy = isBusy
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(docStatus.isGreenEndState ? Color.green : Color.primary)
                .lineLimit(1)
            Spacer()
            if isBusy {
                ProgressView(value: progress)
                    .frame(width: 120)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
    }

    private var label: String {
        switch docStatus {
        case .waitingToStart: return "Waiting to start"
        case .checking: return "Verifying the files…"
        case .allFilesOK: return "All files checked out fine."
        case .repairing: return "Restoring files…"
        case .restoredSuccessfully: return "Files restored successfully."
        case .restoredWithRenames: return "Files restored successfully; one or more were renamed."
        case .repairNeeded: return "Damage found — repair is possible."
        case .needMoreRecovery(let b):
            return "Cannot restore; need \(b) more recovery block\(b == 1 ? "" : "s")."
        case .onlyNonRecoverableMissing: return "Only non-recoverable files are missing."
        case .notValid: return "The PAR file is not valid."
        case .internalError: return "An internal error occurred during processing."
        case .extracting: return "Extracting files…"
        case .extractedSuccessfully: return "Extraction finished successfully."
        case .extractionFailed: return "Extraction failed."
        case .creating: return "Creating recovery data…"
        case .createdSuccessfully: return "Recovery set created successfully."
        case .createFailed: return "Could not create the recovery set."
        }
    }
}
