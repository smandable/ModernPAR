# ModernPAR

A modern, **native arm64** macOS app for PAR2/PAR1 verification, repair, and creation, plus RAR/zip
extraction — a free, open successor to **MacPAR deLuxe** (which is Intel-only and will stop working
when Apple retires Rosetta 2).

Built with **Swift 6 + SwiftUI** (Xcode 26, macOS 14+).

> Status: **Phases 0–8 complete — fully native, no Rosetta anywhere.** Verify/repair/create for
> both PAR2 (embedded par2cmdline-turbo) and PAR1 (pure-Swift GF(2⁸) Reed-Solomon, byte-identical
> to the original's Intel helper and cross-verified by it), RAR/zip extraction including `.001`
> splits and SFX, the full six-tab preference surface, the post-process rule editor, and in-app
> help. Every Mach-O in the bundle is arm64-only (CI-gated). 331 tests, including byte-for-byte
> oracle checks against the original tools. Remaining work: notarized distribution + Sparkle
> (Phase 9). See [docs/ROADMAP.md](docs/ROADMAP.md).

## What it does

- **Verify & repair** PAR2 and PAR1 sets — drop a `.par2` (or its folder) and it auto-verifies,
  then auto-repairs damage, with per-file status and "need N more recovery blocks" math.
- **Extract** RAR (2/3/5, multi-volume, password-protected, encrypted-header) and zip
  (ZipCrypto + WinZip AES) archives — `Cmd-U`, drag-drop, or open-with.
- **Auto post-process**: a successful verify/repair chains straight into extracting the set's
  `.rar`/`.zip` payload — the hands-off SABnzbd/NZBGet pipeline, in one window.
- **Create** PAR2 recovery sets: add files (all in one folder), pick redundancy %, block size
  (automatic or manual), and recovery-file sizing, then `⇧⌘S` — the index and recovery volumes
  land in the folder and verify clean in `par2cmdline`/MultiPar.
- Drag-and-drop, dock-open, completion notifications with "Show in Finder", and a one-time
  per-folder access grant that the sandbox needs (remembered across launches).

See [docs/PRD.md](docs/PRD.md) for the full prioritized feature list and non-goals.

## Architecture at a glance

- **PAR2 engine** = [par2cmdline-turbo](https://github.com/animetosho/par2cmdline-turbo)
  (GPL-2.0-or-later), **embedded in-process** as a C++ SwiftPM target behind an exception-catching
  `extern "C"` shim (Swift consumes it as a plain C module — no C++ interop leaks out). Legal
  because ModernPAR is itself GPL-2.0-or-later. A bundled-CLI subprocess engine
  (`HelperProcessEngine`) sits behind the same protocol as the designed-in fallback. Distribution
  is Developer-ID / notarized, **not** the Mac App Store (GPLv2 §6 vs Apple's Store terms — see
  [docs/research/08](docs/research/08-mas-and-engine-alternatives.md)).
- **PAR1** and the **read-only PAR parser** are **pure Swift** (no Intel binary, no GPL).
- **RAR** = RARLAB UnRAR 7.2.4 (extraction-only) in `CUnrar`, behind an `extern "C"` shim; **zip**
  = the system **libarchive** via `CLibArchive` (vendored headers + the SDK link stub). Both are
  consumed as plain C modules, so — unusually — **no target in the project uses C++ interop**.
  UnRAR is GPL-incompatible (field-of-use restricted) and kept in its own separately-licensed
  component, never merged into the GPL engine's link unit.
- UI = `WindowGroup(for: SessionRoute)` (not `DocumentGroup` — a "document" here is a long-running,
  folder-scoped session). Concurrency = per-engine serial queues + `AsyncStream<EngineEvent>` +
  a coalesced `@MainActor` model; every engine (verify/repair, RAR, zip, create) streams the same
  event type, so one window renders them all.

Full detail and the reasoning (with multi-agent adversarial verification of the risky calls) live
in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/research/](docs/research/).

## Layout

```
App/                  Xcode app target (thin SwiftUI shell): @main App, AppDelegate, Info.plist, entitlements
Packages/PARKit/      Local SwiftPM package — the engine + logic layer
  ModernPARCore/        models, status state machine, engine protocols, post-process rules, bookmarks (C/C++-free)
  Par2Kit/              PAR2 engines: EmbeddedEngine (verify/repair/create) + HelperProcessEngine fallback
  Par2Cxx/              vendored par2cmdline-turbo + the extern-C par2 shim
  ArchiveKit/           RARExtractor (CUnrar) + ZipExtractor (CLibArchive) + shared placement
  CUnrar/               vendored RARLAB UnRAR 7.2.4 + the extern-C unrar shim
  CLibArchive/          vendored libarchive headers + system-library link
  ModernPARUI/          SwiftUI views, scenes, menu commands
ModernPAR.xcodeproj/  app project (links PARKit statically)
docs/                 PRD, ARCHITECTURE, ROADMAP, SCAFFOLD, and research/ (00–08)
```

## Build & run

```bash
# Unit tests (fast, headless — ~20s, 205 tests)
swift test --package-path Packages/PARKit

# Build + run the app
xcodebuild -project ModernPAR.xcodeproj -scheme ModernPAR -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/ModernPAR.app

# Lint
swift format lint --strict --recursive App Packages/PARKit/Sources
```

Requires Xcode 26+ (Swift 6) on Apple Silicon.

## Licensing

**ModernPAR is free software, licensed under the GNU GPL version 2 or (at your option) any later
version** — see [COPYING](COPYING). This is what permits embedding the GPL par2cmdline-turbo
engine in-process. The bundle also contains the field-of-use-restricted RARLAB UnRAR source,
which is GPL-incompatible and therefore kept in its own separately-licensed component
(extraction-only); zip extraction links the system libarchive (BSD). See
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md). **A legal review is required before any public
release** — primarily for the GPL + UnRAR coexistence.
