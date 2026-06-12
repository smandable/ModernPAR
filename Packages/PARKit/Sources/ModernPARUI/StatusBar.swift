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

    private var label: String { docStatus.label }
}

/// The user-facing status line per document state — shared by the status bar and the
/// unattended-mode failure notifications. (doc-01 §5.1)
extension DocStatus {
    var label: String {
        switch self {
        case .waitingToStart: return "Waiting to start"
        case .cancelled: return "Canceled."
        case .newParFileNeeded: return "New PAR file should be generated."
        case .checking: return "Verifying the files…"
        case .allFilesOK: return "All files checked out fine."
        case .allFilesOKWithRenames:
            return "All files checked out fine; one or more files were renamed."
        case .repairing: return "Restoring files…"
        case .restoredSuccessfully: return "Files restored successfully."
        case .restoredWithRenames: return "Files restored successfully; one or more were renamed."
        case .repairNeeded: return "Damage found — repair is possible."
        case .needMoreRecovery(let b):
            return "Cannot restore; need \(b) more recovery block\(b == 1 ? "" : "s")."
        case .needMoreFiles(let n):
            return n == 1
                ? "Cannot restore; need one more file." : "Cannot restore; need \(n) more files."
        case .cannotRestore: return "Cannot restore."
        case .onlyNonRecoverableMissing: return "Only non-recoverable files are missing."
        case .onlyNonRecoverableMissingWithRenames:
            return "Only non-recoverable files are missing; one or more files were renamed."
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
