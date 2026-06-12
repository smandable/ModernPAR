import Foundation

/// Gate for starting the Sparkle updater (ROADMAP Phase 9; doc-06 §6).
///
/// The updater scaffolding ships *before* the EdDSA signing key and the feed-hosting decision
/// exist. Starting Sparkle against a half-configured feed surfaces error alerts at launch (and
/// assertion failures in debug), so the app starts the updater only when Info.plist carries a
/// complete, plausible configuration; until then "Check for Updates…" stays visible but
/// disabled. The checks are deliberately shallow — plausibility, not reachability.
public enum UpdaterConfiguration {
    /// True when both `SUFeedURL` and `SUPublicEDKey` values look like a real configuration.
    public static func isConfigured(feedURL: String?, publicEDKey: String?) -> Bool {
        isPlausibleFeedURL(feedURL) && isPlausiblePublicEDKey(publicEDKey)
    }

    /// https with a host, nothing else: Sparkle (and App Transport Security) reject plaintext
    /// http feeds, and a file/relative URL in a shipping Info.plist is always a configuration
    /// mistake, not a choice.
    static func isPlausibleFeedURL(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == "https",
            let host = components.host, !host.isEmpty
        else { return false }
        return true
    }

    /// An Ed25519 public key is exactly 32 bytes; Sparkle's `generate_keys` prints it base64
    /// encoded (44 characters). Anything that doesn't decode to 32 bytes is a placeholder or a
    /// paste accident.
    static func isPlausiblePublicEDKey(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let key = Data(base64Encoded: trimmed) else { return false }
        return key.count == 32
    }
}
