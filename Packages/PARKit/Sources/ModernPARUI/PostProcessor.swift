import AppKit
import Foundation
import ModernPARCore

/// Applies post-processing rules to a verified set: the first rule (top to bottom) whose
/// pattern matches a file in the set fires — the SABnzbd/NZBGet pipeline, reproducing the
/// original's `AutoPostProcess`/Apply Rule behavior. Extractor actions chain the session into
/// extraction; open actions hand the payload to Finder/an app and end there.
/// (doc-01 §4; ROADMAP Phase 5, actions extended in Phase 7)
@MainActor
public enum PostProcessor {
    /// What applying the rules did — `AutoCloseDocument` closes the window immediately after
    /// an `.opened` action, or once a `.chained` extraction ends green. (doc-01 §5.1)
    public enum Outcome {
        case none
        /// The session chained into an extraction run (built-in Unrar/Unzip).
        case chained
        /// The payload was handed to Finder or an application; nothing else will run.
        case opened
    }

    /// `manual` is the Operation ▸ Apply Rule path — it logs the no-match outcome; the
    /// automatic path stays silent.
    @discardableResult
    public static func apply(session: OperationSession, model: AppModel, manual: Bool) -> Outcome {
        guard !session.isBusy, let anchor = session.anchorURL,
            !session.anchorIsArchive
        else { return .none }
        let names = session.rows.map(\.name)
        guard let match = model.settings.postProcessRules.firstMatch(in: names) else {
            if manual {
                session.note("No post-processing rule matches the files in this set.")
            }
            return .none
        }
        // The matched name comes from the parsed PAR2 roster (untrusted). Refuse anything but
        // a single safe path component so a hostile set cannot point the action at a sibling
        // or parent folder (an out-of-folder powerbox prompt, or worse). (Phase 5 review)
        guard match.filename == (match.filename as NSString).lastPathComponent,
            !match.filename.hasPrefix("."), !match.filename.contains("/")
        else {
            session.note("Refusing post-process target \"\(match.filename)\" (unsafe name).")
            return .none
        }
        let payload = anchor.deletingLastPathComponent().appendingPathComponent(match.filename)

        switch match.rule.action {
        case .builtInUnrar, .builtInUnzip:
            guard let extractor = model.extractor(for: match.rule.action) else {
                session.note(
                    "Rule \(match.rule.name) matched \(match.filename), but its extractor is unavailable."
                )
                return .none
            }
            guard let run = ExtractionRunSupport.makeRun(model: model) else {
                session.note("Post-processing cancelled — no destination was chosen.")
                return .none
            }
            session.chainIntoArchive(
                payload, ruleName: match.rule.name, using: extractor, options: run.options,
                password: run.password, conflicts: run.conflicts)
            return .chained

        case .openInFinder:
            // The original's PostProcess1: open as if double-clicked in Finder.
            session.note("Post-processing (\(match.rule.name)): opening \(match.filename).")
            let opened = withFolderScope(of: anchor) { NSWorkspace.shared.open(payload) }
            if !opened {
                session.note("Could not open \(match.filename).")
                return .none
            }
            return .opened

        case .openWithApp(let appPath, let appName):
            session.note(
                "Post-processing (\(match.rule.name)): opening \(match.filename) with \(appName)."
            )
            let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
            withFolderScope(of: anchor) {
                NSWorkspace.shared.open(
                    [payload], withApplicationAt: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    guard let error else { return }
                    Task { @MainActor in
                        session.note(
                            "Could not open \(payload.lastPathComponent) with \(appName): \(error.localizedDescription)"
                        )
                    }
                }
            }
            return .opened
        }
    }

    /// Brackets an open action in the set folder's remembered security scope (when one
    /// exists) — LaunchServices resolves the payload at call time, and the target app then
    /// receives its own access from the system.
    private static func withFolderScope<T>(of anchor: URL, _ body: () -> T) -> T {
        let folder = anchor.deletingLastPathComponent()
        guard let bookmark = FolderAccessStore.bookmark(forFolder: folder),
            let scope = try? ScopedAccess.resolve(bookmark)
        else { return body() }
        defer { if scope.didStart { scope.url.stopAccessingSecurityScopedResource() } }
        return body()
    }
}
