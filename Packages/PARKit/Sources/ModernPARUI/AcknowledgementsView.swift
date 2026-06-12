import ModernPARCore
import SwiftUI

/// The bundled third-party components and their license obligations (ROADMAP Phase 9;
/// THIRD-PARTY-LICENSES.md is the repo-side index). The license texts ship as verbatim
/// copies of the canonical files in the source tree — `ModernPARUITests` fails the build
/// if a bundled copy drifts from its canonical original.
public enum Acknowledgements {
    public struct Component: Identifiable, Sendable {
        public let name: String
        public let version: String?
        public let licenseName: String
        public let role: String
        /// File name (without extension) under Resources/Licenses.
        public let licenseResource: String

        public var id: String { name }
    }

    /// Order matches THIRD-PARTY-LICENSES.md: the app's own license first (the GPL is why
    /// in-process turbo is legal at all), then the components.
    public static let components: [Component] = [
        Component(
            name: "ModernPAR",
            version: appVersion,
            licenseName: "GPL-2.0-or-later",
            role: "This application. Free software — see the corresponding-source offer above.",
            licenseResource: "GPL-2.0"),
        Component(
            name: "par2cmdline-turbo",
            version: "1.4.0",
            licenseName: "GPL-2.0-or-later",
            role: "PAR2 create, verify, and repair engine, embedded in-process.",
            licenseResource: "GPL-2.0"),
        Component(
            name: "RARLAB UnRAR",
            version: "7.2.4",
            licenseName: "UnRAR license",
            role:
                "RAR extraction only — ModernPAR never creates RAR archives. "
                + "A separately licensed component (see ARCHITECTURE.md §1.4).",
            licenseResource: "UnRAR"),
        Component(
            name: "libarchive",
            version: "system (headers 3.7.4)",
            licenseName: "BSD-2-Clause",
            role: "Zip extraction via the macOS system libarchive. Never used for RAR.",
            licenseResource: "libarchive"),
        Component(
            name: "Sparkle",
            version: sparkleVersion,
            licenseName: "MIT (with included components)",
            role: "Software updates (EdDSA-signed appcast).",
            licenseResource: "Sparkle"),
    ]

    /// GPL §3: where recipients get the complete corresponding source.
    public static let correspondingSourceOffer = """
        ModernPAR is free software, released under the GNU General Public License v2 or \
        later. The complete corresponding source for every release — the application, the \
        embedded par2cmdline-turbo engine, and all local patches — is published at \
        https://github.com/smandable/ModernPAR, tagged per release.
        """

    public static func licenseText(for component: Component) -> String? {
        guard
            let url = Bundle.module.url(
                forResource: component.licenseResource, withExtension: "txt",
                subdirectory: "Licenses")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Read from the embedded framework so the displayed version can never drift from the
    /// pinned package resolution (nil outside the app bundle, e.g. in unit tests).
    private static var sparkleVersion: String? {
        Bundle(identifier: "org.sparkle-project.Sparkle")?
            .infoDictionary?["CFBundleShortVersionString"] as? String
    }
}

/// Help ▸ Acknowledgements: every bundled component with its full license text, headed by
/// the GPL corresponding-source offer. The UnRAR attribution paragraph also stays in
/// Settings ▸ Unrar, where the original kept it.
public struct AcknowledgementsView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Acknowledgements")
                    .font(.title.bold())

                Text(Acknowledgements.correspondingSourceOffer)
                    .textSelection(.enabled)

                ForEach(Acknowledgements.components) { component in
                    ComponentSection(component: component)
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
    }
}

private struct ComponentSection: View {
    let component: Acknowledgements.Component
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(component.name)
                    .font(.headline)
                if let version = component.version {
                    Text(version)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(component.licenseName)
                    .foregroundStyle(.secondary)
            }
            Text(component.role)
                .font(.callout)
                .foregroundStyle(.secondary)

            DisclosureGroup("License text", isExpanded: $isExpanded) {
                // Loaded lazily — the GPL alone is ~18 KB and nobody reads five licenses
                // at once.
                if isExpanded {
                    Text(
                        Acknowledgements.licenseText(for: component)
                            ?? "License text missing from the bundle — this is a build "
                            + "defect; the text is in the repository's license files."
                    )
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .font(.callout)
        }
    }
}
