import AppKit
import ModernPARCore
import SwiftUI
import UniformTypeIdentifiers

/// The post-processing rules editor (the original's Preferences ▸ Post-processing list with
/// New/Modify/Delete/Up/Down/Standard, `EditPPRuleController`). The built-in Unrar rule is
/// pinned last and cannot be edited, deleted, or moved. (doc-01 §4.2; ROADMAP Phase 7)
struct RuleEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var sheet: RuleSheet?
    @State private var confirmingStandard = false

    private enum RuleSheet: Identifiable {
        case new
        case modify(PostProcessRule)
        var id: String {
            switch self {
            case .new: return "new"
            case .modify(let rule): return rule.id.uuidString
            }
        }
    }

    var body: some View {
        let rules = model.settings.postProcessRules
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach(rules.allRules) { rule in
                    row(for: rule, pinned: rule.id == PostProcessRules.builtInUnrarID)
                        .tag(rule.id)
                }
            }
            .frame(minHeight: 150)
            .border(.separator)

            HStack(spacing: 8) {
                Button("New Rule…") { sheet = .new }
                Button("Modify…") {
                    if let rule = selectedEditableRule { sheet = .modify(rule) }
                }
                .disabled(selectedEditableRule == nil)
                Button("Delete") {
                    if let id = selection, rules.canEdit(id) {
                        model.settings.postProcessRules.delete(id)
                        selection = nil
                    }
                }
                .disabled(selectedEditableRule == nil)

                Divider().frame(height: 16)

                Button {
                    if let id = selection { model.settings.postProcessRules.moveUp(id) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canMoveSelection(up: true))
                Button {
                    if let id = selection { model.settings.postProcessRules.moveDown(id) }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(!canMoveSelection(up: false))

                Spacer()

                Button("Standard") { confirmingStandard = true }
            }
            .controlSize(.small)
        }
        .sheet(item: $sheet) { mode in
            switch mode {
            case .new:
                RuleEditSheet(rule: nil) { model.settings.postProcessRules.upsert($0) }
            case .modify(let rule):
                RuleEditSheet(rule: rule) { model.settings.postProcessRules.upsert($0) }
            }
        }
        .alert("Replace all rules with the standard set?", isPresented: $confirmingStandard) {
            Button("Restore Standard Rules", role: .destructive) {
                model.settings.postProcessRules = .standard
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your custom rules will be removed.")
        }
    }

    private func row(for rule: PostProcessRule, pinned: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name)
                Text("\(rule.pattern)  —  \(Self.summary(of: rule.action))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if pinned {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .help("The built-in Unrar rule is always last and cannot be changed.")
            }
        }
        .padding(.vertical, 2)
    }

    private var selectedEditableRule: PostProcessRule? {
        guard let id = selection else { return nil }
        return model.settings.postProcessRules.rules.first { $0.id == id }
    }

    private func canMoveSelection(up: Bool) -> Bool {
        let rules = model.settings.postProcessRules.rules
        guard let id = selection, let index = rules.firstIndex(where: { $0.id == id }) else {
            return false
        }
        return up ? index > 0 : index < rules.count - 1
    }

    static func summary(of action: PostProcessRule.Action) -> String {
        switch action {
        case .builtInUnrar: return "Extract with built-in Unrar"
        case .builtInUnzip: return "Extract with built-in Unzip"
        case .openInFinder: return "Open in Finder"
        case .openWithApp(_, let appName): return "Open with \(appName)"
        }
    }
}

/// The New/Modify rule sheet: description, trigger pattern, and the action — the original's
/// EditRule.nib minus the dropped Terminal action. (doc-01 §4.2)
private struct RuleEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let rule: PostProcessRule?
    let onSave: (PostProcessRule) -> Void

    private enum ActionKind: Hashable {
        case unzip, unrar, finder, app
    }
    @State private var name: String
    @State private var pattern: String
    @State private var kind: ActionKind
    @State private var appPath: String
    @State private var appName: String

    init(rule: PostProcessRule?, onSave: @escaping (PostProcessRule) -> Void) {
        self.rule = rule
        self.onSave = onSave
        _name = State(initialValue: rule?.name ?? "")
        _pattern = State(initialValue: rule?.pattern ?? "")
        switch rule?.action {
        case .builtInUnrar: _kind = State(initialValue: .unrar)
        case .openInFinder: _kind = State(initialValue: .finder)
        case .openWithApp(let path, let app):
            _kind = State(initialValue: .app)
            _appPath = State(initialValue: path)
            _appName = State(initialValue: app)
            _name = State(initialValue: rule?.name ?? "")
            _pattern = State(initialValue: rule?.pattern ?? "")
            return
        case .builtInUnzip, nil: _kind = State(initialValue: .unzip)
        }
        _appPath = State(initialValue: "")
        _appName = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(rule == nil ? "New Rule" : "Modify Rule")
                .font(.headline)
            Form {
                TextField("Description:", text: $name, prompt: Text("Unrar TV episodes"))
                TextField("File name pattern:", text: $pattern, prompt: Text("*.rar"))
                Picker("Action:", selection: $kind) {
                    Text("Extract with built-in Unzip").tag(ActionKind.unzip)
                    Text("Extract with built-in Unrar").tag(ActionKind.unrar)
                    Text("Open in Finder").tag(ActionKind.finder)
                    Text("Open with application").tag(ActionKind.app)
                }
                if kind == .app {
                    LabeledContent("Application:") {
                        HStack {
                            Text(appName.isEmpty ? "None selected" : appName)
                                .foregroundStyle(appName.isEmpty ? .secondary : .primary)
                            Button("Choose…") { chooseApp() }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(builtRule())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedPattern.isEmpty else { return false }
        if kind == .app, appPath.isEmpty { return false }
        return true
    }

    private func builtRule() -> PostProcessRule {
        let action: PostProcessRule.Action
        switch kind {
        case .unzip: action = .builtInUnzip
        case .unrar: action = .builtInUnrar
        case .finder: action = .openInFinder
        case .app: action = .openWithApp(appPath: appPath, appName: appName)
        }
        return PostProcessRule(
            id: rule?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            pattern: pattern.trimmingCharacters(in: .whitespaces),
            action: action)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.message = "Choose the application that will open the matched file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appPath = url.path
        appName = FileManager.default.displayName(atPath: url.path)
    }
}
