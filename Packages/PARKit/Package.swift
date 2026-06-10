// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PARKit",
    platforms: [.macOS(.v14)],          // deployment floor; the app target may raise it
    products: [
        .library(name: "ModernPARUI", targets: ["ModernPARUI"]),
        .library(name: "ModernPARCore", targets: ["ModernPARCore"]),
        .library(name: "Par2Kit", targets: ["Par2Kit"]),
    ],
    targets: [
        // Pure Swift, UI-free, C/C++-free. The domain model + engine seams.
        .target(name: "ModernPARCore"),
        // Swift PAR2 engine layer: MockEngine now; Phase 2 adds EmbeddedEngine (primary, driving
        // the Par2Cxx C++ target via its extern "C" shim, consumed as a plain C module) and
        // HelperProcessEngine (designed-in subprocess fallback / standby license firewall).
        .target(name: "Par2Kit", dependencies: ["ModernPARCore"]),
        // SwiftUI views, scenes, commands. Engine-agnostic: depends only on Core's protocols.
        .target(name: "ModernPARUI", dependencies: ["ModernPARCore"]),
        .testTarget(name: "ModernPARCoreTests", dependencies: ["ModernPARCore", "Par2Kit"]),
        .testTarget(name: "Par2KitTests", dependencies: ["Par2Kit"]),
    ]
)
