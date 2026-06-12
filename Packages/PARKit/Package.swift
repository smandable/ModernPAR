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
    // Localization scaffolding (ROADMAP Phase 8): English first; String Catalogs slot in
    // per-target as translations arrive.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],  // deployment floor; the app target may raise it
    products: [
        .library(name: "ModernPARUI", targets: ["ModernPARUI"]),
        .library(name: "ModernPARCore", targets: ["ModernPARCore"]),
        .library(name: "Par2Kit", targets: ["Par2Kit"]),
        .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
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
        // The vendored par2 CLI, built as `par2helper` for the HelperProcessEngine fallback
        // (and the standby GPL license firewall). Unity-includes the two CLI-only translation
        // units straight from the pinned vendor tree.
        .executableTarget(
            name: "Par2HelperCLI",
            dependencies: ["Par2Cxx"],
            cxxSettings: [.headerSearchPath("../Par2Cxx/config")]
                + par2CxxDefines.map { .define($0) }
        ),
        // Swift PAR2 engine layer: MockEngine + EmbeddedEngine (primary, drives Par2Cxx via
        // the C shim) + HelperProcessEngine (subprocess fallback / standby license firewall).
        .target(name: "Par2Kit", dependencies: ["ModernPARCore", "Par2Cxx"]),
        // The vendored RARLAB UnRAR engine (unrarsrc 7.2.4) behind the extern "C"
        // unrarshim umbrella — extraction/listing ONLY (the UnRAR license forbids using
        // this source to develop a RAR-compatible archiver). Swift consumes it as a plain
        // C module, so no .Cxx interop propagates. LICENSE ISOLATION: the UnRAR license is
        // GPL-incompatible; this target is a separately-licensed component and must never
        // be merged into the Par2Cxx (GPL) target or its translation units
        // (ARCHITECTURE.md §1.4). Compiled-source list mirrors the upstream makefile's
        // `lib:` target; carries LOCAL PATCHES — see vendor/VENDORED.txt before any
        // version bump.
        .target(
            name: "CUnrar",
            exclude: [
                "vendor/VENDORED.txt",
                "vendor/unrar/license.txt",
                "vendor/unrar/readme.txt",
                "vendor/unrar/acknow.txt",
                "vendor/unrar/makefile",
                "vendor/unrar/dll.def",
                "vendor/unrar/dll_nocrypt.def",
                "vendor/unrar/dll.rc",
                "vendor/unrar/UnRAR.vcxproj",
                "vendor/unrar/UnRARDll.vcxproj",
                // #included into other translation units (NOT standalone objects):
                "vendor/unrar/arccmt.cpp",  // → archive.cpp
                "vendor/unrar/blake2s_sse.cpp",  // → blake2s.cpp
                "vendor/unrar/blake2sp.cpp",  // → blake2s.cpp
                "vendor/unrar/cmdfilter.cpp",  // → cmddata.cpp
                "vendor/unrar/cmdmix.cpp",  // → cmddata.cpp
                "vendor/unrar/coder.cpp",  // → unpack.cpp
                "vendor/unrar/crypt1.cpp",  // → crypt.cpp
                "vendor/unrar/crypt2.cpp",  // → crypt.cpp
                "vendor/unrar/crypt3.cpp",  // → crypt.cpp
                "vendor/unrar/crypt5.cpp",  // → crypt.cpp
                "vendor/unrar/hardlinks.cpp",  // → extinfo.cpp
                "vendor/unrar/log.cpp",  // → consio.cpp
                "vendor/unrar/model.cpp",  // → unpack.cpp
                "vendor/unrar/recvol3.cpp",  // → recvol.cpp
                "vendor/unrar/recvol5.cpp",  // → recvol.cpp
                "vendor/unrar/suballoc.cpp",  // → unpack.cpp
                "vendor/unrar/threadmisc.cpp",  // → threadpool.cpp
                "vendor/unrar/uicommon.cpp",  // → ui.cpp
                "vendor/unrar/uiconsole.cpp",  // → ui.cpp
                "vendor/unrar/uisilent.cpp",  // → ui.cpp
                "vendor/unrar/ulinks.cpp",  // → extinfo.cpp
                "vendor/unrar/unpack15.cpp",  // → unpack.cpp
                "vendor/unrar/unpack20.cpp",  // → unpack.cpp
                "vendor/unrar/unpack30.cpp",  // → unpack.cpp
                "vendor/unrar/unpack50.cpp",  // → unpack.cpp
                "vendor/unrar/unpack50frag.cpp",  // → unpack.cpp
                "vendor/unrar/unpack50mt.cpp",  // → unpack.cpp
                "vendor/unrar/unpackinline.cpp",  // → unpack.cpp
                "vendor/unrar/uowners.cpp",  // → extinfo.cpp
                "vendor/unrar/win32acl.cpp",  // → extinfo.cpp
                "vendor/unrar/win32lnk.cpp",  // → extinfo.cpp
                "vendor/unrar/win32stm.cpp",  // → extinfo.cpp
                // Not part of the upstream `lib:` (RARDLL) build at all:
                "vendor/unrar/isnt.cpp",
                "vendor/unrar/motw.cpp",
                "vendor/unrar/rarpch.cpp",
                "vendor/unrar/recvol.cpp",
                "vendor/unrar/rs.cpp",
            ],
            cxxSettings: [
                .headerSearchPath("vendor/unrar"),
                .define("RARDLL"),  // library build: no main(), implies SILENT
                .define("RAR_SMP"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .define("NDEBUG"),
            ]
        ),
        // Header bridge to the SYSTEM libarchive (BSD): the macOS SDK ships the
        // libarchive.2.tbd link stub but not the headers, so archive.h/archive_entry.h are
        // vendored at the runtime-matching version — see CLibArchive/VENDORED.txt for the
        // version-skew rule before using any new API.
        .target(
            name: "CLibArchive",
            exclude: ["COPYING", "VENDORED.txt"],
            linkerSettings: [.linkedLibrary("archive")]
        ),
        // Swift archive-extraction layer: RARExtractor (CUnrar consumed as a plain C module —
        // no .Cxx interop) + ZipExtractor (system libarchive via CLibArchive). Injected into
        // Core/UI behind the ArchiveExtractor protocol only.
        .target(name: "ArchiveKit", dependencies: ["ModernPARCore", "CUnrar", "CLibArchive"]),
        // SwiftUI views, scenes, commands. Engine-agnostic: depends only on Core's protocols.
        // Resources: verbatim third-party license texts for the Acknowledgements view —
        // ModernPARUITests gates them against the canonical files in the source tree.
        .target(
            name: "ModernPARUI", dependencies: ["ModernPARCore"],
            resources: [.copy("Resources/Licenses")]),
        .testTarget(
            name: "ModernPARCoreTests",
            dependencies: ["ModernPARCore", "Par2Kit"],
            resources: [.copy("Fixtures")]
        ),
        // Compliance gate (Phase 9): bundled license texts exist, match their canonical
        // originals byte-for-byte, and the mandatory UnRAR paragraph stays verbatim.
        .testTarget(
            name: "ModernPARUITests", dependencies: ["ModernPARUI", "ModernPARCore"]),
        // Par2HelperCLI is a dependency so `swift test` builds the helper binary the
        // HelperProcessEngine tests spawn.
        .testTarget(
            name: "Par2KitTests", dependencies: ["Par2Kit", "Par2Cxx", "Par2HelperCLI"]),
        // Par2Kit joins for the Phase 5 end-to-end pipeline test (create set → verify →
        // chain into extraction with the real engines).
        .testTarget(
            name: "ArchiveKitTests",
            dependencies: ["ArchiveKit", "ModernPARCore", "Par2Kit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .cxx14
)
