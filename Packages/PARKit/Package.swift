// swift-tools-version: 6.0
import PackageDescription

// Compile-time defines shared by the C and C++ pieces of the vendored turbo engine,
// mirroring upstream's AM_CPPFLAGS (Makefile.am) plus our committed config.h.
let par2CxxDefines: [String] = [
    "HAVE_CONFIG_H",
    "NDEBUG",
    "PARPAR_ENABLE_HASHER_MD5CRC",
    "PARPAR_INVERT_SUPPORT",
    "PARPAR_SLIM_GF16",
    "_DARWIN_C_SOURCE",
]

let package = Package(
    name: "PARKit",
    platforms: [.macOS(.v14)],  // deployment floor; the app target may raise it
    products: [
        .library(name: "ModernPARUI", targets: ["ModernPARUI"]),
        .library(name: "ModernPARCore", targets: ["ModernPARCore"]),
        .library(name: "Par2Kit", targets: ["Par2Kit"]),
    ],
    targets: [
        // Pure Swift, UI-free, C/C++-free. The domain model + engine seams.
        .target(name: "ModernPARCore"),
        // The embedded PAR2 engine: vendored par2cmdline-turbo v1.4.0 (GPL-2.0-or-later;
        // carries LOCAL PATCHES for safe cancellation — see vendor/VENDORED.txt before any
        // version bump) behind the extern "C" Par2Shim umbrella.
        // Swift imports this as a plain C module, so no .Cxx interop propagates
        // (ARCHITECTURE.md §1.1, §2). SIMD note: SwiftPM cannot set per-file ISA flags, so
        // the per-ISA kernels rely on their internal platform guards — on arm64 the x86/SVE
        // variants compile to empty objects and the runtime dispatcher picks NEON.
        .target(
            name: "Par2Cxx",
            exclude: [
                "vendor/COPYING",
                "vendor/VENDORED.txt",
                // CLI-only translation units (par2cmdline.cpp defines main()).
                "vendor/src/par2cmdline.cpp",
                "vendor/src/commandline.cpp",
                // Upstream's own unit tests (each defines main()).
                "vendor/src/commandline_test.cpp",
                "vendor/src/crc_test.cpp",
                "vendor/src/criticalpacket_test.cpp",
                "vendor/src/descriptionpacket_test.cpp",
                "vendor/src/diskfile_test.cpp",
                "vendor/src/galois_test.cpp",
                "vendor/src/letype_test.cpp",
                "vendor/src/libpar2_test.cpp",
                "vendor/src/md5_test.cpp",
                "vendor/src/reedsolomon_test.cpp",
                "vendor/src/utf8_test.cpp",
                // OpenCL output is not built (PARPAR_OPENCL_SUPPORT undefined).
                "vendor/parpar/gf16/controller_ocl.cpp",
                "vendor/parpar/gf16/controller_ocl_init.cpp",
                "vendor/parpar/gf16/opencl-include",
                "vendor/parpar/gf16/suppressions-valgrind.supp",
                "vendor/parpar/gf16/xor_jit_stub_masm64.asm",
                // Build-system probe, not a library source.
                "vendor/parpar/src/platform_warnings.c",
            ],
            cSettings: [.headerSearchPath("config")] + par2CxxDefines.map { .define($0) },
            cxxSettings: [.headerSearchPath("config")] + par2CxxDefines.map { .define($0) }
        ),
        // Swift PAR2 engine layer: MockEngine + (Phase 2) EmbeddedEngine driving Par2Cxx via
        // the C shim, and HelperProcessEngine (designed-in subprocess fallback / standby
        // license firewall).
        .target(name: "Par2Kit", dependencies: ["ModernPARCore", "Par2Cxx"]),
        // SwiftUI views, scenes, commands. Engine-agnostic: depends only on Core's protocols.
        .target(name: "ModernPARUI", dependencies: ["ModernPARCore"]),
        .testTarget(
            name: "ModernPARCoreTests",
            dependencies: ["ModernPARCore", "Par2Kit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "Par2KitTests", dependencies: ["Par2Kit", "Par2Cxx"]),
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .cxx14
)
