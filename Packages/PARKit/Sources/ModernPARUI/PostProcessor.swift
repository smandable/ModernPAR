import Foundation
import ModernPARCore

/// Applies post-processing rules to a verified set: the first rule (top to bottom) whose
/// pattern matches a file in the set chains the session into extracting that payload — the
/// SABnzbd/NZBGet pipeline, reproducing the original's `AutoPostProcess`/Apply Rule behavior.
/// (doc-01 §4; ROADMAP Phase 5)
@MainActor
public enum PostProcessor {
    /// Returns true when a rule fired. `manual` is the Operation ▸ Apply Rule path — it logs
    /// the no-match outcome; the automatic path stays silent.
    @discardableResult
    public static func apply(session: OperationSession, model: AppModel, manual: Bool) -> Bool {
        guard !session.isBusy, let anchor = session.anchorURL,
            !ArchiveFileTypes.isArchive(anchor)
        else { return false }
        let names = session.rows.map(\.name)
        guard let match = model.settings.postProcessRules.firstMatch(in: names) else {
            if manual {
                session.note("No post-processing rule matches the files in this set.")
            }
            return false
        }
        guard let extractor = model.extractor(for: match.rule.action) else {
            session.note(
                "Rule \(match.rule.name) matched \(match.filename), but its extractor is unavailable."
            )
            return false
        }
        // The matched name comes from the parsed PAR2 roster (untrusted). Refuse anything but
        // a single safe path component so a hostile set cannot point extraction at a sibling
        // or parent folder (an out-of-folder powerbox prompt, or worse). (Phase 5 review)
        guard match.filename == (match.filename as NSString).lastPathComponent,
            !match.filename.hasPrefix("."), !match.filename.contains("/")
        else {
            session.note("Refusing post-process target \"\(match.filename)\" (unsafe name).")
            return false
        }
        let payload = anchor.deletingLastPathComponent().appendingPathComponent(match.filename)
        session.chainIntoArchive(
            payload, ruleName: match.rule.name, using: extractor,
            password: UIPasswordProvider(), conflicts: UIConflictResolver())
        return true
    }
}
