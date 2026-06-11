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

    @Test func standardRulesCoverRarThenZip() {
        let rules = PostProcessRules.standard
        #expect(rules.rules.map(\.action) == [.builtInUnrar, .builtInUnzip])

        // .rar outranks .zip when both are present (top-to-bottom).
        let both = rules.firstMatch(in: ["data.zip", "data.rar"])
        #expect(both?.rule.action == .builtInUnrar)
        #expect(both?.filename == "data.rar")

        let zipOnly = rules.firstMatch(in: ["readme.txt", "data.zip"])
        #expect(zipOnly?.rule.action == .builtInUnzip)
        #expect(zipOnly?.filename == "data.zip")

        #expect(rules.firstMatch(in: ["readme.txt", "video.mkv"]) == nil)
        #expect(rules.firstMatch(in: []) == nil)
    }

    @Test func firstMatchHonorsRosterOrderWithinARule() {
        let rules = PostProcessRules.standard
        let match = rules.firstMatch(in: ["b.part02.rar", "a.part01.rar"])
        // Roster order, not alphabetical — the extractor normalizes volumes itself.
        #expect(match?.filename == "b.part02.rar")
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
