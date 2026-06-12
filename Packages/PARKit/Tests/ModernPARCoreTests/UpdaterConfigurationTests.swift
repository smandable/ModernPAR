import Foundation
import Testing

@testable import ModernPARCore

/// The Sparkle start gate (ROADMAP Phase 9): the updater must never start against a
/// half-configured feed — no key yet, placeholder values, or a non-https URL.
struct UpdaterConfigurationTests {
    /// A syntactically valid Ed25519 public key: 32 bytes, base64 encoded.
    private let validKey = Data(repeating: 0xAB, count: 32).base64EncodedString()

    @Test func completeConfigurationPasses() {
        #expect(
            UpdaterConfiguration.isConfigured(
                feedURL: "https://example.com/appcast.xml", publicEDKey: validKey))
    }

    @Test func missingPiecesFail() {
        #expect(!UpdaterConfiguration.isConfigured(feedURL: nil, publicEDKey: nil))
        #expect(
            !UpdaterConfiguration.isConfigured(
                feedURL: "https://example.com/appcast.xml", publicEDKey: nil))
        #expect(!UpdaterConfiguration.isConfigured(feedURL: nil, publicEDKey: validKey))
        // The shipped scaffold: feed URL pre-filled, key still the empty placeholder.
        #expect(
            !UpdaterConfiguration.isConfigured(
                feedURL: "https://example.com/appcast.xml", publicEDKey: ""))
    }

    @Test func feedURLMustBeHTTPSWithHost() {
        #expect(UpdaterConfiguration.isPlausibleFeedURL("https://example.com/appcast.xml"))
        #expect(UpdaterConfiguration.isPlausibleFeedURL("  https://example.com/a.xml\n"))
        #expect(UpdaterConfiguration.isPlausibleFeedURL("HTTPS://example.com/a.xml"))

        #expect(!UpdaterConfiguration.isPlausibleFeedURL("http://example.com/appcast.xml"))
        #expect(!UpdaterConfiguration.isPlausibleFeedURL("ftp://example.com/appcast.xml"))
        #expect(!UpdaterConfiguration.isPlausibleFeedURL("file:///tmp/appcast.xml"))
        #expect(!UpdaterConfiguration.isPlausibleFeedURL("https://"))
        #expect(!UpdaterConfiguration.isPlausibleFeedURL("appcast.xml"))
        #expect(!UpdaterConfiguration.isPlausibleFeedURL(""))
        #expect(!UpdaterConfiguration.isPlausibleFeedURL("   "))
        #expect(!UpdaterConfiguration.isPlausibleFeedURL("not a url at all"))
    }

    @Test func publicKeyMustDecodeToExactly32Bytes() {
        #expect(UpdaterConfiguration.isPlausiblePublicEDKey(validKey))
        #expect(UpdaterConfiguration.isPlausiblePublicEDKey(" \(validKey)\n"))

        #expect(!UpdaterConfiguration.isPlausiblePublicEDKey(""))
        #expect(!UpdaterConfiguration.isPlausiblePublicEDKey("    "))
        #expect(!UpdaterConfiguration.isPlausiblePublicEDKey("not-base64!!"))
        #expect(
            !UpdaterConfiguration.isPlausiblePublicEDKey(
                Data(repeating: 1, count: 31).base64EncodedString()))
        #expect(
            !UpdaterConfiguration.isPlausiblePublicEDKey(
                Data(repeating: 1, count: 33).base64EncodedString()))
        // A plausible-looking placeholder someone might leave behind.
        #expect(!UpdaterConfiguration.isPlausiblePublicEDKey("REPLACE-WITH-REAL-KEY"))
    }
}
