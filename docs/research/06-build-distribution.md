# 06 — Build, Packaging, Signing, Notarization & Updates

Research doc for **ModernPAR**, a 100% native arm64 macOS app (Swift 6.3 / SwiftUI / Xcode 26)
that modernizes MacPAR deLuxe 5.1.1. This covers how to *structure*, *build*, *sign*,
*notarize*, *ship*, and *update* the app, plus the legal constraints from bundling a GPLv2 PAR2
engine and the UnRAR-licensed RAR decoder.

Ground truth this builds on: [`00-source-notes.md`](./00-source-notes.md). The original app is a
document-based Cocoa app bundling `par2SL` (a GCD-parallelized par2cmdline fork, GPLv2 lineage), a
`par` PAR1 helper, and `libUnrar.dylib`. Verified locally (2026-06-09): the installed
`/Applications/MacPAR deLuxe.app` `MacOS` binary is **x86_64 only** (`lipo -archs` → `x86_64`),
which is exactly the Rosetta-dependency problem ModernPAR exists to eliminate.

Local toolchain verified (2026-06-09): **Xcode 26.5 (17F42)**, **Apple Swift 6.3.2**, target
`arm64-apple-macosx26.0`; `xcrun notarytool` and `xcrun stapler` both present under
`/Applications/Xcode.app/Contents/Developer/usr/bin/`.

---

## 0. TL;DR — recommended setup

| Decision | Recommendation |
|---|---|
| Project structure | **Xcode `.xcodeproj` (or `.xcworkspace`) app target + one or more *local* SPM packages** for the engine layer. Not SPM-only. |
| Engine target | C/C++ `par2`/RAR code as a **statically-linked SPM C++ target** wrapped by a Swift module (C++ interop), built *into the app binary* — not as a separate command-line helper, not as a loadable dylib. |
| Architecture | **arm64-only**, deployment target macOS 14 (Sonoma) or 15 (Sequoia). Universal is optional and only worth it if you must support 2019–2020 Intel Macs; the whole motivation is escaping Rosetta, so default to arm64-only. |
| Distribution | **Developer ID + notarized DMG, updated via Sparkle 2 (EdDSA)**. *Not* the Mac App Store. *(Framing refined by `research/08` §2: the GPL engine is the structural blocker — Apple's Usage Rules are GPLv2 §6 "further restrictions"; UnRAR is a softer, chosen blocker — RAR extraction is MAS-shippable, e.g. Keka.)* |
| Signing | Developer ID Application cert, **Hardened Runtime**, sign **bottom-up** (engine code is inside the main binary, so almost nothing extra to sign except Sparkle's XPC services). |
| Sandbox | App Sandbox **ON** with `user-selected.read-write` + security-scoped bookmarks. This is feasible *because the engine is in-process*, not a forked helper. |

---

## 1. Project structure: SPM-only vs `.xcodeproj` vs Xcode + local SPM

### The constraints we actually have
ModernPAR needs, in one shippable bundle:
1. A SwiftUI, document-based app (`.par`, `.par2`, `.rar` document types — see source notes).
2. A **C/C++ engine** (par2cmdline-turbo lineage, plus a PAR1 path and a RAR decoder).
3. **Resources** (localized strings EN/NL, asset catalog, help, default post-processing rules).
4. **Entitlements** + Hardened Runtime + a code-signed, notarized `.app`.
5. Sparkle for updates (which ships its own XPC services that must live inside the bundle).

### Option A — SPM-only (`Package.swift`, `swift build`) — **NOT recommended**
SwiftPM *can* build a macOS executable and *can* mix Swift + C++ targets (C++ interop has been a
first-class SwiftPM feature since Swift 5.9 via `.interoperabilityMode(.Cxx)`
— https://www.swift.org/documentation/cxx-interop/project-build-setup/). But SwiftPM does **not**
produce a proper `.app` bundle with an `Info.plist`, document-type declarations
(`CFBundleDocumentTypes` / `UTExportedTypeDeclarations`), an asset catalog compiled by `actool`,
an entitlements-driven signed bundle, embedded XPC services, or a Sparkle framework copy phase.
You would have to hand-roll all of that with shell scripts. For a document-based, sandboxed,
notarized GUI app this is a large amount of fragile glue. SwiftPM is the wrong top level here.

### Option B — Pure `.xcodeproj` app target with C/C++ files dropped in — workable but worse
You *can* add the engine's `.cpp`/`.h` files directly to the app target and enable
`SWIFT_OBJC_INTEROP` / C++ interoperability mode on the target. This compiles fine (Xcode 15+
supports mixing Swift and C++ in a single app/framework target —
https://www.swift.org/documentation/cxx-interop/project-build-setup/). The downside: the engine
code becomes inseparable from the UI, harder to unit-test in isolation, harder to build/test from
the command line without the full app, and you can't reuse it (e.g. a future CLI). It also makes
build settings (C++ standard, warning flags, SIMD/`-march`-equivalent dispatch) global to the app
target.

### Option C — Xcode app target + **local SPM package(s)** — **RECOMMENDED**
Structure:

```
ModernPAR/                      (git root)
├── ModernPAR.xcodeproj         (the app target: SwiftUI, Info.plist, entitlements, asset catalog)
│   └── ModernPAR/              (app sources, Views, document model, engine wrappers)
├── Packages/
│   └── PARKit/                 (local SwiftPM package — the engine layer)
│       ├── Package.swift
│       └── Sources/
│           ├── CPar2/          (C++ target: par2cmdline-turbo sources, GF16/SIMD backend)
│           │   ├── include/    (umbrella header for the C ABI you expose)
│           │   └── *.cpp
│           ├── CRarDecode/     (C target: UnRAR sources OR libarchive shim)
│           └── PARKit/         (Swift target: typed async API over the C++ engine; .interoperabilityMode(.Cxx))
└── fastlane/ or Scripts/       (build/sign/notarize automation)
```

The app target depends on the local `PARKit` package (drag the package folder into the project,
add `PARKit` library product to "Frameworks, Libraries, and Embedded Content").

Why this wins:
- **Static linking by default.** A SwiftPM *library* product linked into an app target is
  statically linked into the app's main executable. The C++ engine becomes part of `MacOS/ModernPAR`
  — there is **no separate dylib to sign**, no library-validation headaches, and nothing extra to
  embed. (This is the single biggest signing/notarization simplification — see §5.)
- **Clean module boundary + testability.** `swift test` runs engine tests headless in CI without
  launching the GUI. The C++ stays behind a Swift API (`PARKit`), so the UI never imports C++ types
  directly (keeps C++-interop "infection" contained — per the SwiftPM C++-interop note, any target
  importing a `.Cxx` target must itself enable C++ interop:
  https://forums.swift.org/t/updated-plan-for-supporting-c-interoperability-in-swift-package-manager-in-the-swift-5-9-release/65203).
- **Per-target build settings.** The C++ target can set its own C++ standard, `unsafeFlags`,
  and define-guards for NEON/SIMD dispatch independent of the app.
- **Xcode owns the bundle.** Info.plist, document types, asset catalog, entitlements, code-signing,
  Sparkle copy-files phase, and archive/export are all native Xcode build-system features that "just
  work" with notarization tooling.

> Note on `.xcworkspace`: a workspace is only needed if you want multiple top-level projects open
> together. A single `.xcodeproj` that references the local package directory is sufficient and
> simpler. Use a workspace only if you later split a standalone CLI project out.

**Recommendation: Option C** — `ModernPAR.xcodeproj` app target + a local `PARKit` SwiftPM package
that statically links the C++ engine, exposed through a Swift async API.

---

## 2. Universal binary (arm64 + x86_64) vs arm64-only

The original app is x86_64-only (verified above). Apple is winding down Rosetta 2: Apple has
announced Rosetta will be reduced after macOS 27 to a smaller set of frameworks/older games and is
not a long-term solution — which is precisely ModernPAR's reason to exist.

### arm64-only — **RECOMMENDED (default)**
- The mission is "escape Rosetta," and Apple Silicon has been the only Mac architecture sold since
  ~2023. Targeting macOS 14/15+ means effectively all supported machines are arm64.
- Simpler builds, smaller binaries, and the SIMD backend (ParPar/NEON in par2cmdline-turbo) is the
  arm64 path you actually care about for performance.
- Set `ARCHS = arm64`, `ONLY_ACTIVE_ARCH = NO` for Release.

### Universal (arm64 + x86_64) — only if you must keep 2019–2020 Intel Macs
- Worth it *only* if telemetry/users show meaningful Intel-Mac usage and those users can run a
  modern macOS. Intel Macs top out at macOS 26 (Tahoe)/end-of-line; their numbers shrink yearly.
- Cost: the C++ engine must build clean for x86_64 too (SIMD dispatch must cover SSE/AVX *and*
  NEON), CI build time roughly doubles, the DMG is larger, and you re-introduce the very thing you
  set out to kill (an x86_64 slice).
- par2cmdline-turbo *does* support both x86 and ARM SIMD backends
  (https://github.com/animetosho/par2cmdline-turbo), so universal is *technically* feasible.

**Recommendation: ship arm64-only.** Keep the build settings clean enough that flipping to
`ARCHS = "arm64 x86_64"` is a one-line change if a real Intel-user need ever materializes, but do
not pay the universal tax by default. This is consistent with the project's stated motivation in
the source notes ("ModernPAR must be native arm64").

---

## 3. Licensing reality check — this drives distribution choice

> *(Refined by `research/08` §2 (2026-06-09): GPLv2 §6 + the MAS sandbox's bundled-CLI ban are the
> structural Store blockers; the UnRAR license is a softer blocker we choose to treat as one — RAR
> extraction itself is provably MAS-shippable (Keka, The Unarchiver).)*

The GPL engine rules out the Mac App Store; the UnRAR license is a second blocker we choose to
treat as one. Both shape what you must document.

### 3a. GPLv2 (par2cmdline / par2SL / par2cmdline-turbo) vs Mac App Store
- par2cmdline and its forks, including **par2cmdline-turbo, are GPL-2.0**
  (https://github.com/animetosho/par2cmdline-turbo). par2SL (the original's engine) is the same
  lineage.
- The FSF's longstanding position: the Mac App Store's Terms of Service impose usage restrictions
  (Usage Rules, device limits, DRM) that count as "further restrictions" forbidden by **GPLv2
  section 6**. Therefore GPL software cannot be distributed via the App Store without violating the
  GPL. (https://www.fsf.org/news/2010-05-app-store-compliance and
  https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement)
- **Consequence:** if ModernPAR statically links a GPLv2 par2 engine, **the entire ModernPAR app
  binary becomes a derivative work that must be distributed under GPLv2** (static linking creates a
  combined work). That means: ModernPAR's *own source must be released under a GPLv2-compatible
  license*, and you must offer corresponding source. That is fine for a Developer-ID-distributed
  open-source app, but it is **incompatible with the App Store**.

  - Escape hatch if you ever want App Store: run the engine as a **separate-process command-line
    helper** (GPLv2 binary invoked over a pipe/XPC) so the GUI is "mere aggregation" rather than a
    linked derivative — BUT App Store sandbox rules forbid bundling/spawning arbitrary executables
    that aren't themselves App-Store-reviewable, and the GPL ToS conflict still applies to the
    helper. Net: **App Store is not realistic.** Plan around Developer ID.

### 3b. UnRAR license vs everything
- The UnRAR source is freely usable to *read* RAR archives but carries a use-restriction: it
  **may not be used to develop a RAR-compatible (compression) archiver**, and any redistribution
  must reproduce the UnRAR license paragraph verbatim
  (https://fedoraproject.org/wiki/Licensing:Unrar). This restriction makes it **non-free /
  GPL-incompatible** in the FSF/Fedora sense.
- **Two consequences:**
  1. UnRAR's restriction is incompatible with GPLv2, so you cannot *combine* (link) UnRAR code with
     the GPLv2 par2 engine in one binary without a conflict. Keep them in **separate translation
     units / separate process or at minimum document them as separately-licensed components**, and
     consider whether the RAR decoder should be its own out-of-process helper to keep the licensing
     clean. (Decoding into a separate dylib/helper is the conventional way projects like 7-Zip ship
     UnRAR alongside other-licensed code.)
  2. UnRAR's non-OSI field-of-use clause muddies a clean MAS licensing posture — but per
     `research/08` §2 B2 it does **not** trigger the §6 further-restrictions conflict (it is not
     copyleft and restricts no end-user usage), and Apple review accepts it (Keka ships RARLAB
     UnRAR on MAS today).

- **App-Store-friendly alternative for RAR:** **libarchive** added RAR5 read support in 3.4.0
  (https://gitlab.gnome.org/GNOME/evince/-/issues/1190) and is BSD-2-Clause. BUT libarchive's RAR
  support is widely reported as **less reliable** than UnRAR — some archives extract as
  zero-filled/garbage where `unrar`/7-Zip succeed (https://github.com/libarchive/libarchive/issues
  threads; LANraragi #165). Given the source notes require robust RAR 2.x/3.x/5.x extraction
  including SFX and multi-volume, **UnRAR is the pragmatic engine** and reinforces the
  Developer-ID-only decision. (See doc 03/05 for engine-selection detail; this doc only records the
  distribution impact.)

### 3c. What you must ship in the bundle for compliance
- A **GPLv2 license text** for par2 (and your own source offer).
- The **verbatim UnRAR license paragraph** in your licenses screen / `Resources`
  (required by the UnRAR license).
- An acknowledgements / open-source-licenses view (and `THIRD-PARTY-LICENSES` in the repo).

---

## 4. Code signing & entitlements

### 4a. Certificate
- Distribution outside the App Store requires a **Developer ID Application** certificate
  (https://developer.apple.com/developer-id/). (A separate **Developer ID Installer** cert is needed
  only if you ship a `.pkg`; a DMG does not need it.)

### 4b. Hardened Runtime
- **Mandatory for notarization.** Enable `ENABLE_HARDENED_RUNTIME = YES` (Xcode "Hardened Runtime"
  capability), or `codesign --options runtime`. Without it the signature is valid but Apple's notary
  service rejects the app (https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
- The bundle (and every nested binary) must **not** carry `com.apple.security.get-task-allow`
  (the "debuggable" entitlement). Release/archive builds strip it; never copy a development-signed
  binary into the release bundle.

### 4c. App Sandbox + file access (recommended ON)
Because the engine is **in-process** (statically linked, §1), the sandbox is feasible without a
helper-spawn exception. Entitlements file (`ModernPAR.entitlements`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <!-- App Sandbox on -->
    <key>com.apple.security.app-sandbox</key>
    <true/>

    <!-- User-selected files: read AND write (verify reads sets; repair/create/unrar write) -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>

    <!-- Persist access to folders the user opened, across launches (Retry recovery, reopen sets) -->
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>

    <!-- Outgoing network: ONLY for Sparkle update checks/downloads -->
    <key>com.apple.security.network.client</key>
    <true/>

    <!-- Sparkle sandbox XPC mach-lookup exception (see §6) -->
    <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
    <array>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
    </array>
</dict>
</plist>
```

Notes:
- `files.user-selected.read-write` is the core PAR/RAR workflow entitlement: the user picks a
  folder or `.par2`, and via **security-scoped bookmarks** you keep access to the whole folder so
  you can scan, repair-in-place, and write recovered/extracted files (matches the source notes'
  "scans all files in the folder", "files must be in ONE folder", "Retry recovery remembers OK
  files").
- App-scope bookmarks (`files.bookmarks.app-scope`) persist that access across relaunch — important
  for the document-based "keep the window open and retry later" behavior.
- **No `com.apple.security.cs.disable-library-validation` needed.** That entitlement is only for
  apps that load *unsigned third-party plug-ins/dylibs at runtime*
  (https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).
  Because ModernPAR links the engine statically and you sign Sparkle's bundled libraries yourself,
  library validation should stay **enabled** (the secure default; disabling it weakens Gatekeeper
  checks). The one case you'd need it: if you decide to ship the RAR decoder as a *separately-signed
  dylib that you load via `dlopen`* AND it's signed by a different team — not your situation.
- **No JIT entitlement** (`com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory`).
  PAR2 GF16 SIMD is AOT-compiled native code, not JIT. Do not request these — they only widen attack
  surface and trigger extra scrutiny.

### 4d. If you ever bundle a separate command-line helper or out-of-process engine
This matters if you split the GPLv2 engine and/or UnRAR decoder into their own executables (the
license-isolation pattern from §3). For Developer ID + notarization:
- Each helper binary must be **independently code-signed** with your Developer ID, with
  **Hardened Runtime** (`--options runtime`), a `--timestamp`, and a stable signing identifier
  (https://developer.apple.com/forums/thread/129544).
- A sandboxed parent can't freely `exec` an arbitrary bundled tool; you use an **`XPCService`** or a
  privileged/login helper registered properly, OR you keep the engine in-process to avoid this
  entirely (the recommended path). If you do go out-of-process inside the sandbox, that helper is an
  XPC service inside `Contents/XPCServices/`, sandboxed itself, and you grant it the file access via
  the security-scoped URL you pass over the XPC connection.
- App Store: bundling arbitrary helper executables is disallowed; another reason App Store is out.

---

## 5. Notarization + stapling workflow

### 5a. Signing order — bottom-up, never `--deep`
Apple's guidance (echoed widely): **do not use `codesign --deep`**; sign nested code first, then the
app last ("inside-out") with a stable identifier, Hardened Runtime, and a secure timestamp
(https://developer.apple.com/forums/thread/129544;
https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5).

For ModernPAR (engine statically linked → very little nested code), the only nested signable items
are typically **Sparkle.framework** and its two **XPC services** (`Installer.xpc`,
`Downloader.xpc`) and `Autoupdate`/`Updater.app` inside Sparkle. Order:

1. Sign every nested Mach-O **inside Sparkle.framework** (XPC services, helper apps, the framework
   binary), each with `--options runtime --timestamp` and your Developer ID. *In practice the
   Sparkle SPM/binary distribution ships pre-signed; if Xcode's "Sign on Copy" + a Copy Files phase
   handles it, verify with `codesign -dv` rather than re-signing blindly.*
2. Sign the app bundle last, with the entitlements file and Hardened Runtime.

If you use Xcode's **Archive → Distribute App → Developer ID → "Upload"/"Export"**, Xcode signs the
whole tree correctly and (with "Upload") can notarize for you. For a scriptable/CI flow, sign
manually (below). Note: `xcodebuild -exportArchive` with `developer-id` can hang trying to reach
distribution servers for credentials — many people skip exportArchive and sign the `.app` straight
out of the archive (https://www.frr.dev/posts/macos-notarization-guide-linter/).

### 5b. Notarization requirements (what the notary service enforces)
Every Mach-O in the bundle must be:
- Signed with a **Developer ID** cert,
- **Hardened Runtime** enabled,
- **No `com.apple.security.get-task-allow`**,
- Includes a **secure timestamp** (`--timestamp`).
(https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

### 5c. notarytool credentials (one-time)
Create an **app-specific password** at appleid.apple.com, then store a keychain profile so CI/local
scripts never embed the password
(https://keith.github.io/xcode-man-pages/notarytool.1.html;
https://scriptingosx.com/2021/07/notarize-a-command-line-tool-with-notarytool/):

```bash
xcrun notarytool store-credentials "ModernPAR-Notary" \
    --apple-id "you@example.com" \
    --team-id  "ABCDE12345" \
    --password "abcd-efgh-ijkl-mnop"   # app-specific password
```
(For CI, prefer an **App Store Connect API key**: `--key`, `--key-id`, `--issuer`.)

### 5d. End-to-end command outline (DMG distribution)

```bash
set -euo pipefail
APP="build/Build/Products/Release/ModernPAR.app"
DEVID="Developer ID Application: Your Name (ABCDE12345)"
ENT="ModernPAR/ModernPAR.entitlements"
DMG="dist/ModernPAR.dmg"

# 1) Build a Release, arm64 archive (no exportArchive — sign the .app directly)
xcodebuild -project ModernPAR.xcodeproj -scheme ModernPAR \
    -configuration Release -derivedDataPath build \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO clean build

# 2) Strip extended attributes that break signing
xattr -cr "$APP"

# 3) Sign bottom-up: any nested frameworks/XPC first, then the app last.
#    (Sparkle is usually pre-signed; verify, otherwise re-sign each Mach-O.)
find "$APP/Contents/Frameworks" -name "*.framework" -o -name "*.dylib" 2>/dev/null | while read f; do
    codesign --force --options runtime --timestamp -s "$DEVID" "$f"
done
codesign --force --options runtime --timestamp \
    --entitlements "$ENT" -s "$DEVID" "$APP"

# 4) Verify the signature & runtime before submitting
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP"   # confirm "runtime" flag, no get-task-allow

# 5) Build the DMG (e.g. create-dmg or hdiutil), then notarize the DMG
hdiutil create -volname "ModernPAR" -srcfolder "$APP" -ov -format UDZO "$DMG"

# 6) Submit & wait
xcrun notarytool submit "$DMG" --keychain-profile "ModernPAR-Notary" --wait

# 7) Staple the ticket to the DMG (and the .app if shipping the bare app/zip)
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
```

### 5e. Stapling gotchas
- You **can staple a `.dmg`, `.app`, or `.pkg`** but **cannot staple a `.zip`** — for a zip you must
  staple the `.app` *inside*, then re-zip
  (https://www.frr.dev/posts/macos-notarization-guide-linter/).
- For Sparkle updates you ship a notarized+stapled `.app` (zipped) or a notarized+stapled `.dmg`;
  staple the **inner `.app`** so Gatekeeper passes offline after Sparkle extracts it.
- On notary failure, fetch the log: `xcrun notarytool log <submission-id> --keychain-profile ...` —
  it pinpoints which nested binary lacked Hardened Runtime / timestamp / had `get-task-allow`.

---

## 6. Updates: Sparkle 2 vs none vs App Store

### Recommendation: **Sparkle 2 with EdDSA signatures**, sandbox-compatible.
The original app had a custom XML auto-updater (source notes say "replace with Sparkle or none").
Sparkle 2 is the de-facto standard, supports **sandboxed** apps, SwiftUI, and modern installs
(https://sparkle-project.org/ ; https://sparkle-project.org/documentation/sandboxing/).

### Integration
- Add Sparkle via **SwiftPM** (`https://github.com/sparkle-project/Sparkle`,
  product `Sparkle`). For SwiftUI, use the programmatic `SPUStandardUpdaterController` /
  `StandardUpdaterController` and a "Check for Updates…" menu command
  (https://sparkle-project.org/documentation/ ; the Medium SwiftUI integration guide:
  https://medium.com/@matteospada.m/how-to-integrate-the-sparkle-framework-into-a-swiftui-app-for-macos-98ca029f83f7).

### Sandbox specifics (exact keys — from Sparkle docs)
(https://sparkle-project.org/documentation/sandboxing/)
- **Entitlements:** the two `com.apple.security.temporary-exception.mach-lookup.global-name`
  values `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `$(PRODUCT_BUNDLE_IDENTIFIER)-spki` (already in the
  §4c entitlements block). These let the sandboxed app talk to Sparkle's installer/downloader XPC
  services.
- **Info.plist:** set `SUEnableInstallerLauncherService = YES` (required for sandboxed apps — runs
  the **Installer.xpc** that installs the update *outside* the sandbox).
- The **Downloader.xpc** (`SUEnableDownloaderService = YES`) is **only** needed if the app lacks
  `com.apple.security.network.client`. ModernPAR already needs network-client for update checks, so
  **do not enable the downloader service** (avoids extra surface and deprecated WebView release-notes
  path).
- Sparkle's XPC services live inside `Sparkle.framework/XPCServices/` and get embedded
  automatically; they must be signed (handled by the Copy Files phase / pre-signed framework — see
  §5a). They must also be Hardened-Runtime-signed and stapled along with the app.

### Appcast + EdDSA
- Sign every update artifact (zip/dmg/delta) with Sparkle's **EdDSA (ed25519)** key using
  Sparkle's `generate_keys` + `sign_update` tools; publish the public key in `SUPublicEDKey` in
  Info.plist (https://sparkle-project.org/documentation/). The private key never leaves your
  signing machine / CI secret store.
- Host an `appcast.xml` (e.g. GitHub Releases + raw appcast, or any static host). `SUFeedURL` in
  Info.plist points to it.
- Reference real-world friction with Sparkle + Developer ID + notarization (worth reading before
  shipping): https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears.

### Alternatives
- **None / manual DMG download:** simplest, but loses auto-update — bad UX for a utility users keep
  around for years. Not recommended as the primary path; can be the *fallback* (publish DMGs anyway).
- **Mac App Store updates:** would give "free" updates but is blocked by GPLv2 + UnRAR (§3). Out.

---

## 7. CI / local build + test story

### Local / CI build & test (minimal)
```bash
# Engine package unit tests (fast, headless — runs in CI without a GUI session)
swift test --package-path Packages/PARKit

# App build (and UI/integration tests) via xcodebuild
xcodebuild -project ModernPAR.xcodeproj -scheme ModernPAR \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Debug clean build

xcodebuild test -project ModernPAR.xcodeproj -scheme ModernPAR \
    -destination 'platform=macOS,arch=arm64'
```
- For C++ engine tests, you can also keep a SwiftPM test target in `PARKit` that exercises the C ABI
  with golden PAR2/RAR fixtures (small recovery sets) so regressions in the GF16/SIMD path are
  caught without the UI.

### Lint / format
- **swift-format** is now bundled with the Swift toolchain (`swift format`), so prefer it for a
  zero-extra-dependency setup; add a `.swift-format` config and a CI step
  (`swift format lint --recursive Sources`). **SwiftLint** remains a popular richer-rule alternative
  if you want style rules beyond formatting — run it as a build phase or CI step. Pick one to avoid
  conflicting opinions; swift-format is the lighter, first-party choice.

### CI platform
- GitHub Actions **macOS runners** (Apple-Silicon `macos-15`/`macos-26` images) have Xcode preinstalled.
- Store the Developer ID cert (`.p12`) and the notarytool App Store Connect API key as encrypted CI
  secrets; import the cert into a temporary keychain in the job. Sign + notarize only on tagged
  release builds, not on every PR (notarization is slow and uses a real Apple service).
- **Fastlane** (`match`/`gym`/`notarize` actions) is a reasonable higher-level wrapper if you don't
  want to maintain the raw `xcodebuild`/`codesign`/`notarytool` scripts, but the scripts in §5d are
  fully sufficient and dependency-free.

### Build settings summary to bake into the project
- `ARCHS = arm64`, `ONLY_ACTIVE_ARCH = NO` (Release).
- `MACOSX_DEPLOYMENT_TARGET = 14.0` (or 15.0) — drop Intel-era OS support; this also keeps SwiftUI
  document APIs and modern concurrency available.
- `SWIFT_VERSION = 6` (strict concurrency); `ENABLE_HARDENED_RUNTIME = YES`.
- `ENABLE_APP_SANDBOX = YES` + entitlements file from §4c.
- C++ target: `CXX_INTEROP` via `.interoperabilityMode(.Cxx)` in `Package.swift`, C++17/20 std,
  NEON/SIMD enabled for arm64.

---

## 8. Decision log (one-liners for the design agent)

- **Structure:** Xcode app target + local SwiftPM `PARKit` package; engine statically linked → in
  the main binary.
- **Arch:** arm64-only (matches "escape Rosetta"); universal is a one-flag fallback if Intel demand appears.
- **Distribution:** Developer ID, notarized **DMG**, Sparkle 2 auto-update. **No Mac App Store.**
- **Why no App Store:** GPLv2 par2 engine (FSF: GPL §6 vs App Store ToS) *and* UnRAR's non-free
  use-restriction *and* bundled-helper rules — any one of these is disqualifying.
- **Sandbox:** ON. Entitlements: `app-sandbox`, `files.user-selected.read-write`,
  `files.bookmarks.app-scope`, `network.client`, Sparkle's two `mach-lookup` temporary exceptions.
  **No** `disable-library-validation`, **no** JIT, **no** `get-task-allow` in release.
- **Sparkle sandbox:** `SUEnableInstallerLauncherService=YES`; downloader service OFF (we already
  have network-client). EdDSA-sign all artifacts; `SUPublicEDKey` + `SUFeedURL` in Info.plist.
- **Signing:** Developer ID Application, Hardened Runtime, `--timestamp`, bottom-up, never `--deep`.
- **Notarize:** `notarytool submit --wait` with a keychain profile / ASC API key; `stapler staple`
  the DMG and the inner `.app`.
- **Legal artifacts to bundle:** GPLv2 text + source offer; verbatim UnRAR license paragraph;
  acknowledgements view.

---

## Sources
- Source notes (ground truth): [`00-source-notes.md`](./00-source-notes.md)
- Apple, *Customizing the notarization workflow*: https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- Apple, *Signing Mac Software with Developer ID*: https://developer.apple.com/developer-id/
- Apple, *Disable Library Validation Entitlement*: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation
- Apple Developer Forums, *Xcode notarization and hardened runtime* (bottom-up signing, no `--deep`): https://developer.apple.com/forums/thread/129544
- rsms gist, *macOS distribution — code signing, notarization, quarantine*: https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5
- frr.dev, *macOS Notarization guide* (exportArchive hang, stapling zip caveat): https://www.frr.dev/posts/macos-notarization-guide-linter/
- `notarytool` man page (store-credentials, --wait, keychain profile): https://keith.github.io/xcode-man-pages/notarytool.1.html
- Scripting OS X, *Notarize a Command Line Tool with notarytool*: https://scriptingosx.com/2021/07/notarize-a-command-line-tool-with-notarytool/
- Sparkle docs (home): https://sparkle-project.org/
- Sparkle *Sandboxing* (exact entitlements, SUEnableInstallerLauncherService, XPC services): https://sparkle-project.org/documentation/sandboxing/
- Sparkle *Documentation* (EdDSA signing, programmatic/SwiftUI setup): https://sparkle-project.org/documentation/
- Sparkle GitHub: https://github.com/sparkle-project/Sparkle
- Sparkle + SwiftUI integration guide: https://medium.com/@matteospada.m/how-to-integrate-the-sparkle-framework-into-a-swiftui-app-for-macos-98ca029f83f7
- Steipete, *Code Signing and Notarization: Sparkle and Tears* (2025): https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears
- Swift.org, *Setting Up Mixed-Language Swift and C++ Projects*: https://www.swift.org/documentation/cxx-interop/project-build-setup/
- Swift Forums, *C++ interoperability in SwiftPM (5.9)*: https://forums.swift.org/t/updated-plan-for-supporting-c-interoperability-in-swift-package-manager-in-the-swift-5-9-release/65203
- par2cmdline-turbo (GPLv2, arm64/SIMD, library targets): https://github.com/animetosho/par2cmdline-turbo
- FSF, *GPL Enforcement in Apple's App Store*: https://www.fsf.org/news/2010-05-app-store-compliance
- FSF, *More about the App Store GPL Enforcement*: https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement
- Fedora, *Licensing:Unrar* (use-restriction, GPL-incompatible, verbatim-notice requirement): https://fedoraproject.org/wiki/Licensing:Unrar
- libarchive RAR5 support note (evince #1190): https://gitlab.gnome.org/GNOME/evince/-/issues/1190
- libarchive RAR reliability concerns (LANraragi #165): https://github.com/Difegue/LANraragi/issues/165
