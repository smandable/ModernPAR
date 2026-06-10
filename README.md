# ModernPAR

A modern, **native arm64** macOS app for PAR2/PAR1 verification, repair, and creation, plus RAR/zip
extraction — a free, open successor to **MacPAR deLuxe** (which is Intel-only and will stop working
when Apple retires Rosetta 2).

Built with **Swift 6 + SwiftUI** (Xcode 26, macOS 14+).

> Status: **Phase 0 complete** — buildable, testable, launchable app shell with the final module
> topology and engine seam in place. The real PAR2/PAR1/RAR engines are wired in later phases
> (see [docs/ROADMAP.md](docs/ROADMAP.md)).

## What it will do (parity with MacPAR deLuxe, modernized)

- **Verify & repair** PAR2 and PAR1 sets, with per-file status and "need N more recovery blocks" math.
- **Create** PAR2 (and PAR1) sets with redundancy %, block size, and recovery-file sizing controls.
- **Extract** RAR (2/3/5, multi-volume, self-extracting, password-protected) and zip archives.
- Drag-and-drop, dock-open, notifications, and a tabbed Preferences pane.

See [docs/PRD.md](docs/PRD.md) for the full prioritized feature list and non-goals.

## Architecture at a glance

- **PAR2 engine** = [par2cmdline-turbo](https://github.com/animetosho/par2cmdline-turbo)
  (GPL-2.0-or-later), **embedded in-process** as a C++ SwiftPM target behind an exception-catching
  C shim — legal because ModernPAR is itself GPL-2.0-or-later. A bundled-CLI subprocess engine
  (`HelperProcessEngine`) is built behind the same protocol as the designed-in fallback.
  Distribution is Developer-ID / notarized, **not** the Mac App Store (GPLv2 §6 vs Apple's Store
  terms — see [docs/research/08](docs/research/08-mas-and-engine-alternatives.md)).
- **PAR1** and the **read-only PAR parser** are **pure Swift** (no Intel binary, no GPL).
- **RAR** = RARLAB UnRAR (extraction-only) linked in-process via a C shim; **zip** = system libarchive.
  C++ interop is quarantined to a single `ArchiveKit` target.
- UI = `WindowGroup(for: SessionRoute)` (not `DocumentGroup` — a "document" here is a long-running,
  folder-scoped session). Concurrency = actors + `AsyncStream` + a coalesced `@MainActor` model.

Full detail and the reasoning (with adversarial verification of the risky calls) live in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/research/](docs/research/).

## Layout

```
App/                  Xcode app target (thin SwiftUI shell): @main App, AppDelegate, Info.plist, entitlements
Packages/PARKit/      Local SwiftPM package — the engine + logic layer
  ModernPARCore/        models, status state machine, engine protocols, security-scoped bookmarks (C/C++-free)
  Par2Kit/              PAR2 engines: MockEngine (now); EmbeddedEngine + HelperProcessEngine (Phase 2)
  ModernPARUI/          SwiftUI views, scenes, menu commands
ModernPAR.xcodeproj/  app project (links PARKit statically)
docs/                 PRD, ARCHITECTURE, ROADMAP, SCAFFOLD, and research/ (00–08)
```

## Build & run

```bash
# Unit tests (fast, headless)
swift test --package-path Packages/PARKit

# Build + run the app
xcodebuild -project ModernPAR.xcodeproj -scheme ModernPAR -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/ModernPAR.app

# Lint
swift format lint --strict --recursive App Packages/PARKit/Sources
```

Requires Xcode 26+ (Swift 6.3) on Apple Silicon.

## Licensing

**ModernPAR is free software, licensed under the GNU GPL version 2 or (at your option) any later
version** — see [COPYING](COPYING). This is what permits embedding the GPL par2cmdline-turbo
engine in-process. The bundle also contains the field-of-use-restricted RARLAB UnRAR source,
which is GPL-incompatible and therefore kept in its own separately-licensed component
(extraction-only). See [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md). **A legal review is
required before any public release** — primarily for the GPL + UnRAR coexistence.
