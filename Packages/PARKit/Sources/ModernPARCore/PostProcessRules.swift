import Foundation

/// One post-processing rule: after a set verifies/repairs successfully, the first rule (top to
/// bottom) whose filename pattern matches a file in the set fires — exactly one per set.
/// (doc-01 §4 "Post-processing rules"; ROADMAP Phase 5, editor in Phase 7)
public struct PostProcessRule: Sendable, Equatable, Codable, Identifiable {
    /// The original's action types (doc-01 §4.2) minus the Terminal/AppleScript action,
    /// which is deliberately dropped for v1; plus the two built-in extractors, which user
    /// rules may also target (e.g. `*.cbr` → built-in Unrar).
    public enum Action: Sendable, Equatable, Codable {
        case builtInUnrar
        case builtInUnzip
        /// Open the matched file as if double-clicked in Finder (`PostProcess1`).
        case openInFinder
        /// Open the matched file with a chosen application (`PostProcess2`/`3`).
        case openWithApp(appPath: String, appName: String)
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

/// The ordered rule list the editor manages. Matching the original (doc-01 §4.2): the
/// built-in Unrar rule is ALWAYS LAST and cannot be edited, deleted, or moved — it is not
/// stored in `rules` at all, which makes the invariant structural. (This reconciles Phase 5's
/// deliberate rar-first divergence: a set carrying both a `.zip` and a `.rar` now consumes
/// the zip, as the original did.)
public struct PostProcessRules: Sendable, Equatable, Codable {
    /// The user-editable, reorderable rules. The pinned built-in Unrar rule is appended at
    /// match time, never persisted.
    public var rules: [PostProcessRule]

    public init(rules: [PostProcessRule]) {
        self.rules = rules
    }

    /// Stable ids so the standard rules and the pinned rule keep their editor selection and
    /// equality across launches (a random UUID would differ per process).
    public static let builtInUnrarID = UUID(uuidString: "B0117177-0000-4000-8000-0000004E5241")!
    static let standardUnzipID = UUID(uuidString: "B0117177-0000-4000-8000-0000005A4950")!

    /// The original's non-editable "Built-in Unrar" rule, always evaluated last.
    public static let builtInUnrarRule = PostProcessRule(
        id: builtInUnrarID, name: "Built-in Unrar", pattern: "*.rar", action: .builtInUnrar)

    /// Every rule in match order: user rules first, the pinned built-in Unrar rule last.
    public var allRules: [PostProcessRule] { rules + [Self.builtInUnrarRule] }

    /// The default rule set: `.zip` → built-in Unzip (system libarchive) as the only user
    /// rule, then the pinned Unrar rule. StuffIt is dropped (dead tech, doc-01 §4.1).
    public static let standard = PostProcessRules(rules: [
        PostProcessRule(
            id: standardUnzipID, name: "Built-in Unzip", pattern: "*.zip", action: .builtInUnzip)
    ])

    /// Top-to-bottom over `allRules`, first match wins, ONE rule fires per set. Within a
    /// rule, the first matching filename (roster order) is the payload — for multi-volume
    /// sets the extractor normalizes any volume to the set's first volume itself.
    public func firstMatch(in filenames: [String]) -> (rule: PostProcessRule, filename: String)? {
        for rule in allRules {
            if let filename = filenames.first(where: rule.matches) {
                return (rule, filename)
            }
        }
        return nil
    }

    // MARK: - Editor operations (ROADMAP Phase 7 "New/Modify/Delete/Up/Down/Standard")

    /// The pinned rule rejects every edit; these are no-ops for it and out-of-range ids.
    public func canEdit(_ id: UUID) -> Bool {
        rules.contains { $0.id == id }
    }

    public mutating func delete(_ id: UUID) {
        rules.removeAll { $0.id == id }
    }

    public mutating func moveUp(_ id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }), index > 0 else { return }
        rules.swapAt(index, index - 1)
    }

    public mutating func moveDown(_ id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }), index < rules.count - 1
        else { return }
        rules.swapAt(index, index + 1)
    }

    public mutating func upsert(_ rule: PostProcessRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
    }
}
