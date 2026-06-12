import AppKit
import ModernPARCore

/// Builds one extraction run's engine options and prompt providers from the persisted
/// preferences — the single place the Unrar tab's choices (destination, conflict default,
/// keep-broken, segment disposal, filename encoding) meet an actual run. (ROADMAP Phase 7)
@MainActor
public enum ExtractionRunSupport {
    public struct Run {
        public let options: ExtractOptions
        public let password: UIPasswordProvider
        public let conflicts: UIConflictResolver
    }

    /// Returns nil when the user cancels the "choose a destination" panel (the `.ask`
    /// preference) — the run never starts.
    public static func makeRun(model: AppModel, retryAfterFailure: Bool = false) -> Run? {
        let settings = model.settings
        var options = model.makeExtractOptions()
        if case .ask = options.destination {
            guard let folder = ExtractDestinationPanel.present(),
                let bookmark = try? ScopedAccess.bookmark(for: folder)
            else { return nil }
            options.destination = .fixed(bookmark: bookmark)
        }
        if !settings.unattendedOperation {
            options.encodingPicker = UIFilenameEncodingPicker()
        }
        return Run(
            options: options,
            password: UIPasswordProvider(
                previousAttemptFailed: retryAfterFailure,
                unattended: settings.unattendedOperation),
            conflicts: UIConflictResolver(
                defaultPolicy: settings.conflictDefault,
                unattended: settings.unattendedOperation))
    }
}

/// Folder chooser for the "Always let me choose a location" destination preference. The
/// powerbox grant doubles as the write scope for the chosen folder. (doc-01 §5.4)
@MainActor
enum ExtractDestinationPanel {
    static func present() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder where the extracted items will be placed."
        panel.prompt = "Extract Here"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// The encoding-selection prompt for legacy RAR names that are not valid UTF-8 — the
/// original's EncodingSelection sheet: "Some file names contain special characters. Please
/// select the most likely interpretation." (doc-01 §3.7)
public struct UIFilenameEncodingPicker: FilenameEncodingPicker {
    public init() {}

    public func chooseEncoding(candidates: [FilenameEncodingCandidate]) async -> String? {
        await MainActor.run {
            guard !candidates.isEmpty else { return nil }
            let alert = NSAlert()
            alert.messageText = "Some file names contain special characters"
            alert.informativeText =
                "The archive stores file names in a legacy encoding. Select the most likely interpretation."
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
            for candidate in candidates {
                popup.addItem(withTitle: "\(candidate.localizedName) — \(candidate.preview)")
            }
            alert.accessoryView = popup
            alert.addButton(withTitle: "Use Selected Encoding")
            alert.addButton(withTitle: "Keep UTF-8")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let index = popup.indexOfSelectedItem
            return candidates.indices.contains(index) ? candidates[index].ianaName : nil
        }
    }
}
