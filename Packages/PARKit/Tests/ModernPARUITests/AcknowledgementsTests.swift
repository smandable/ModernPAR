import Foundation
import Testing

@testable import ModernPARUI

/// Compliance gate for the bundled license texts (ROADMAP Phase 9; THIRD-PARTY-LICENSES.md).
/// The Acknowledgements resources are verbatim COPIES of canonical files elsewhere in the
/// tree — these tests fail the build the moment a copy drifts, and they pin the UnRAR
/// license's one hard obligation: the attribution paragraph reproduced verbatim.
struct AcknowledgementsTests {
    /// Repo root, derived from this file's path — the canonical files live in the source
    /// tree, not in any test bundle.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ModernPARUITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // PARKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root

    private func bundled(_ resource: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: resource, withExtension: "txt", subdirectory: "Licenses"),
            "license resource \(resource).txt missing from ModernPARUI bundle")
        return try Data(contentsOf: url)
    }

    @Test func everyComponentLicenseLoadsNonEmpty() throws {
        #expect(!Acknowledgements.components.isEmpty)
        for component in Acknowledgements.components {
            let text = try #require(
                Acknowledgements.licenseText(for: component),
                "no license text for \(component.name)")
            #expect(text.count > 200, "license for \(component.name) suspiciously short")
        }
    }

    /// The bundled copies must stay byte-identical to their canonical originals. (Sparkle's
    /// canonical file lives in the resolved package checkout, which CI doesn't have during
    /// `swift test` — it is pinned by content markers below instead.)
    @Test func bundledCopiesMatchCanonicalFiles() throws {
        let pairs: [(resource: String, canonical: String)] = [
            ("GPL-2.0", "COPYING"),
            ("UnRAR", "Packages/PARKit/Sources/CUnrar/vendor/unrar/license.txt"),
            ("libarchive", "Packages/PARKit/Sources/CLibArchive/COPYING"),
        ]
        for pair in pairs {
            let canonical = try Data(
                contentsOf: Self.repoRoot.appendingPathComponent(pair.canonical))
            let copy = try bundled(pair.resource)
            #expect(
                copy == canonical,
                "\(pair.resource).txt drifted from canonical \(pair.canonical)")
        }
    }

    @Test func gplTextIsTheRealGPL2() throws {
        let text = try #require(String(data: bundled("GPL-2.0"), encoding: .utf8))
        #expect(text.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(text.contains("Version 2, June 1991"))
        #expect(text.contains("Free Software Foundation"))
    }

    @Test func sparkleLicenseIsMIT() throws {
        let text = try #require(String(data: bundled("Sparkle"), encoding: .utf8))
        #expect(text.contains("Permission is hereby granted"))
        #expect(text.contains("WITHOUT WARRANTY OF ANY KIND") || text.contains("MIT"))
    }

    /// Byte-compare the bundled Sparkle license against the RESOLVED package's LICENSE
    /// whenever a local build has materialized it (any dev machine; absent under bare
    /// `swift test` in CI, where the content markers above are the fallback and
    /// Scripts/release.sh repeats this byte-compare as a hard release gate).
    @Test func sparkleLicenseMatchesResolvedPackageWhenPresent() throws {
        let canonical = Self.repoRoot.appendingPathComponent(
            "build/SourcePackages/artifacts/sparkle/Sparkle/LICENSE")
        guard FileManager.default.fileExists(atPath: canonical.path) else { return }
        let copy = try bundled("Sparkle")
        #expect(
            try Data(contentsOf: canonical) == copy,
            "Sparkle.txt drifted from the resolved package's LICENSE — update the copy")
    }

    /// The UnRAR license's mandatory paragraph must appear VERBATIM in every place the
    /// license obliges or the docs claim: the bundled license text, Settings ▸ Unrar, and
    /// the source comments of the resulting package (unrarshim.h — "included … in source
    /// code comments"). Compared word-for-word: the sources wrap lines (and prefix comment
    /// markers) differently, which the license allows; the words may not change.
    @Test func unrarAttributionParagraphIsVerbatimEverywhere() throws {
        let paragraphStart = ["UnRAR", "source", "code", "may", "be", "used"]
        func paragraph(in text: String, label: String) throws -> [String] {
            // Strip C-comment decoration so the shim header tokenizes like plain text.
            let words = text.split(whereSeparator: \.isWhitespace)
                .map(String.init).filter { $0 != "//" && $0 != "*" }
            let start = try #require(
                words.indices.first(where: {
                    Array(words[$0..<min($0 + paragraphStart.count, words.count)])
                        == paragraphStart
                }), "attribution paragraph not found in \(label)")
            // The paragraph ends at "resulting package." in every source.
            let end = try #require(
                words[start...].indices.first(where: {
                    words[$0].hasPrefix("package.") && words[$0 - 1] == "resulting"
                }), "attribution paragraph end not found in \(label)")
            return Array(words[start...end])
        }

        let fromLicense = try paragraph(
            in: #require(String(data: bundled("UnRAR"), encoding: .utf8)),
            label: "UnRAR.txt")
        let fromSettings = try paragraph(
            in: SettingsView.unrarAcknowledgement, label: "Settings ▸ Unrar text")
        let shimHeader = Self.repoRoot.appendingPathComponent(
            "Packages/PARKit/Sources/CUnrar/include/unrarshim.h")
        let fromShim = try paragraph(
            in: String(contentsOf: shimHeader, encoding: .utf8),
            label: "unrarshim.h source comment")

        #expect(fromLicense == fromSettings, "UnRAR paragraph drifted in Settings")
        #expect(fromLicense == fromShim, "UnRAR paragraph drifted in unrarshim.h")
    }

    @Test func correspondingSourceOfferNamesTheRepo() {
        #expect(
            Acknowledgements.correspondingSourceOffer.contains(
                "https://github.com/smandable/ModernPAR"))
        #expect(Acknowledgements.correspondingSourceOffer.contains("corresponding source"))
    }
}
