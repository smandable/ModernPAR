import Foundation

/// One post-processing rule: after a set verifies/repairs successfully, the first rule (top to
/// bottom) whose filename pattern matches a file in the set fires — exactly one per set.
/// (doc-01 §4 "Post-processing rules"; ROADMAP Phase 5)
public struct PostProcessRule: Sendable, Equatable, Codable, Identifiable {
    /// MVP ships the two built-in extractor actions; the v1 rule editor adds open-in-Finder,
    /// open-with-app, and shell-command actions (doc-01 §4.2). StuffIt is dropped entirely.
    public enum Action: String, Sendable, Codable {
        case builtInUnrar
        case builtInUnzip
    }

    public var id: UUID
    public var name: String
    /// Case-insensitive filename glob (`*`, `?`, `[…]`), matched against each file name.
    public var pattern: String
    public var action: Action

    public init(id: UUID = UUID(), name: String, pattern: String, action: Action) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.action = action
    }

    public func matches(_ filename: String) -> Bool {
        // FNM_PATHNAME so `*` never spans a `/` — a roster name like "../x.zip" cannot match
        // "*.zip" and drive extraction outside the set's folder. (Phase 5 review)
        fnmatch(pattern, filename, FNM_CASEFOLD | FNM_PATHNAME) == 0
    }
}

/// The ordered rule list. (Phase 7 persists it and adds the editor; the original's built-in
/// Unrar rule semantics — not editable, fires on `.rar` — map to the standard set here.)
public struct PostProcessRules: Sendable, Equatable, Codable {
    public var rules: [PostProcessRule]

    public init(rules: [PostProcessRule]) {
        self.rules = rules
    }

    /// The MVP default rule set: `.rar` → built-in Unrar, `.zip` → built-in Unzip (system
    /// libarchive); StuffIt dropped. RAR is ordered first deliberately — it is the dominant
    /// Usenet payload, so a set carrying both should consume the RAR. NOTE: this differs from
    /// the original, where the non-editable built-in Unrar rule sat LAST after user rules
    /// (doc-01 §4.2). When the Phase 7 rule editor lands with that "always-last" invariant,
    /// reconcile this ordering (and `PostProcessRulesTests.standardRulesCoverRarThenZip`).
    public static let standard = PostProcessRules(rules: [
        PostProcessRule(name: "Built-in Unrar", pattern: "*.rar", action: .builtInUnrar),
        PostProcessRule(name: "Built-in Unzip", pattern: "*.zip", action: .builtInUnzip),
    ])

    /// Top-to-bottom, first match wins, ONE rule fires per set. Within a rule, the first
    /// matching filename (roster order) is the payload — for multi-volume sets the extractor
    /// normalizes any volume to the set's first volume itself.
    public func firstMatch(in filenames: [String]) -> (rule: PostProcessRule, filename: String)? {
        for rule in rules {
            if let filename = filenames.first(where: rule.matches) {
                return (rule, filename)
            }
        }
        return nil
    }
}
