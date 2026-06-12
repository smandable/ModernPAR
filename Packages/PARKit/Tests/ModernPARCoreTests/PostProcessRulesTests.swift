import Foundation
import Testing

@testable import ModernPARCore

/// The post-processing rule model: deterministic top-to-bottom matching, first match wins,
/// one rule fires per set. (doc-01 §4; ROADMAP Phase 5 exit criterion)
struct PostProcessRulesTests {

    @Test func globMatchingIsCaseInsensitive() {
        let rule = PostProcessRule(name: "Unrar", pattern: "*.rar", action: .builtInUnrar)
        #expect(rule.matches("archive.rar"))
        #expect(rule.matches("ARCHIVE.RAR"))
        #expect(rule.matches("set.part01.rar"))
        #expect(!rule.matches("archive.r00"))
        #expect(!rule.matches("archive.zip"))
        #expect(!rule.matches("rar"))
    }

    @Test func globSupportsQuestionMarkAndClasses() {
        let rule = PostProcessRule(name: "Vols", pattern: "*.r0?", action: .builtInUnrar)
        #expect(rule.matches("a.r00"))
        #expect(rule.matches("a.r01"))
        #expect(!rule.matches("a.r10"))
    }

    @Test func standardRulesAreZipThenPinnedUnrarLast() {
        let rules = PostProcessRules.standard
        // Only the zip rule is a user rule; the built-in Unrar rule is pinned last and not
        // stored (doc-01 §4.2 "always last, cannot be edited/deleted"). This reconciles the
        // Phase 5 rar-first divergence back to the original's ordering.
        #expect(rules.rules.map(\.action) == [.builtInUnzip])
        #expect(rules.allRules.map(\.action) == [.builtInUnzip, .builtInUnrar])
        #expect(rules.allRules.last?.id == PostProcessRules.builtInUnrarID)

        // A user rule outranks the pinned Unrar rule when both match (the original's order).
        let both = rules.firstMatch(in: ["data.zip", "data.rar"])
        #expect(both?.rule.action == .builtInUnzip)
        #expect(both?.filename == "data.zip")

        // A rar-only set still reaches the pinned rule.
        let rarOnly = rules.firstMatch(in: ["readme.txt", "data.rar"])
        #expect(rarOnly?.rule.action == .builtInUnrar)
        #expect(rarOnly?.filename == "data.rar")

        #expect(rules.firstMatch(in: ["readme.txt", "video.mkv"]) == nil)
        #expect(rules.firstMatch(in: []) == nil)
    }

    @Test func pinnedUnrarRuleIsAlwaysLastAndImmutable() {
        var rules = PostProcessRules.standard
        let pinned = PostProcessRules.builtInUnrarID

        // The pinned rule is not editable, deletable, or movable — every operation is a no-op.
        #expect(!rules.canEdit(pinned))
        rules.delete(pinned)
        rules.moveUp(pinned)
        rules.moveDown(pinned)
        #expect(rules.allRules.last?.id == pinned)

        // Even after every user rule is deleted, the pinned rule still matches.
        for rule in rules.rules { rules.delete(rule.id) }
        #expect(rules.rules.isEmpty)
        #expect(rules.firstMatch(in: ["a.rar"])?.rule.action == .builtInUnrar)
    }

    @Test func userRulesOutrankThePinnedRuleInListOrder() {
        var rules = PostProcessRules.standard
        // A user rule can target the built-in Unrar engine for OTHER patterns (e.g. comics).
        rules.upsert(PostProcessRule(name: "Comics", pattern: "*.cbr", action: .builtInUnrar))
        rules.upsert(
            PostProcessRule(
                name: "Player", pattern: "*.mkv",
                action: .openWithApp(appPath: "/Applications/IINA.app", appName: "IINA")))
        let match = rules.firstMatch(in: ["movie.mkv", "comic.cbr"])
        // List order decides: Comics sits above Player (upsert appends).
        #expect(match?.rule.name == "Comics")
    }

    @Test func editorOperationsReorderDeleteAndUpsert() {
        var rules = PostProcessRules(rules: [
            PostProcessRule(name: "A", pattern: "*.a", action: .openInFinder),
            PostProcessRule(name: "B", pattern: "*.b", action: .openInFinder),
            PostProcessRule(name: "C", pattern: "*.c", action: .openInFinder),
        ])
        let a = rules.rules[0].id
        let b = rules.rules[1].id
        let c = rules.rules[2].id

        rules.moveUp(b)
        #expect(rules.rules.map(\.id) == [b, a, c])
        rules.moveUp(b)  // already first — no-op
        #expect(rules.rules.map(\.id) == [b, a, c])
        rules.moveDown(c)  // already last — no-op
        #expect(rules.rules.map(\.id) == [b, a, c])
        rules.moveDown(b)
        #expect(rules.rules.map(\.id) == [a, b, c])

        rules.delete(b)
        #expect(rules.rules.map(\.id) == [a, c])

        // Upsert replaces in place by id, preserving position.
        var modified = rules.rules[0]
        modified.pattern = "*.changed"
        rules.upsert(modified)
        #expect(rules.rules.map(\.id) == [a, c])
        #expect(rules.rules[0].pattern == "*.changed")
    }

    @Test func firstMatchHonorsRosterOrderWithinARule() {
        let rules = PostProcessRules.standard
        let match = rules.firstMatch(in: ["b.part02.rar", "a.part01.rar"])
        // Roster order, not alphabetical — the extractor normalizes volumes itself.
        #expect(match?.filename == "b.part02.rar")
    }

    @Test func openWithAppActionRoundTripsThroughCodable() throws {
        let rules = PostProcessRules(rules: [
            PostProcessRule(
                name: "Player", pattern: "*.mkv",
                action: .openWithApp(appPath: "/Applications/IINA.app", appName: "IINA")),
            PostProcessRule(name: "Reveal", pattern: "*.iso", action: .openInFinder),
        ])
        let data = try JSONEncoder().encode(rules)
        let decoded = try JSONDecoder().decode(PostProcessRules.self, from: data)
        #expect(decoded == rules)
        #expect(
            decoded.rules.first?.action
                == .openWithApp(appPath: "/Applications/IINA.app", appName: "IINA"))
    }

    @Test func globNeverSpansASlash() {
        // FNM_PATHNAME: a roster name with traversal components must not match "*.zip" and
        // drive extraction outside the set's folder. (Phase 5 review)
        let rule = PostProcessRule(name: "Unzip", pattern: "*.zip", action: .builtInUnzip)
        #expect(!rule.matches("../evil.zip"))
        #expect(!rule.matches("sub/evil.zip"))
        #expect(rule.matches("evil.zip"))
    }

    @Test func rulesRoundTripThroughCodable() throws {
        let original = PostProcessRules.standard
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PostProcessRules.self, from: data)
        #expect(decoded == original)
    }
}
