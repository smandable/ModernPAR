# ModernPAR — Product Requirements Document

> **Status:** Approved direction for v1 planning. Authored by the lead architect.
> **Date:** 2026-06-09.
> **Audience:** The engineer(s) building ModernPAR.
>
> This PRD is a *decision* document, not a survey. The research in
> [`docs/research/01..08`](./research/) already explored the option space; here we
> commit. Where the research left a fork open, this document picks a branch and
> states why in one or two lines. Engineering detail (module layout, concurrency,
> sandbox plumbing) lives in the decided [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md)
> (with [`04-swift-architecture.md`](./research/04-swift-architecture.md) as background research);
> this PRD says *what* we are building and *in what order*, not *how* to wire it.

---

## 1. Vision & positioning

**ModernPAR is the native, Apple-Silicon, free/open successor to MacPAR deLuxe** — a
modern macOS app that verifies and repairs PAR2 recovery sets and extracts the RAR/zip
archives those sets protect.

MacPAR deLuxe 5.1.1 (2018, Gerard Putter) is an Intel-only binary that survives today
only under Rosetta 2. Apple has signalled Rosetta 2's removal (broadly expected around
macOS 28 / 2028), at which point the app — still the *only* PAR2 GUI on the Mac — stops
launching. **That deadline is ModernPAR's reason to exist.** There is no maintained
native-macOS / SwiftUI / Apple-Silicon PAR2 GUI in the market today; this is an open gap.

Positioning, in one sentence each:

- **vs. MacPAR deLuxe:** the same proven workflow (auto verify → repair → unrar →
  post-process), rebuilt native arm64 in SwiftUI with a modern SIMD engine, dark mode,
  and no shareware nags.
- **vs. CLI `par2`/`par2cmdline-turbo`:** a real GUI with per-file status, one-click
  repair, drag-and-drop, and integrated extraction — the things a terminal can't give.
- **vs. MultiPar (Windows):** the same feature *bar* (verification levels, recursive
  scan, rename/relocate detection), finally on the Mac.
- **vs. Keka / The Unarchiver:** those extract; ModernPAR *recovers first, then
  extracts* — the par2 + unrar coupling is the differentiator.

**Licensing & distribution stance (load-bearing, decided up front).** ModernPAR ships
**open source** and is **distributed outside the Mac App Store** as a Developer-ID-signed,
hardened-runtime, notarized, sandboxed DMG with Sparkle 2 auto-updates. *(Confirmed by the
project owner 2026-06-09: ModernPAR's own license is **GPL-2.0-or-later** and distribution is
Option A of [`research/08`](./research/08-mas-and-engine-alternatives.md) — no MAS edition
planned.)* This is not a preference — it is forced by the engines:

- The PAR2 engine (`par2cmdline-turbo`) is **GPL-2.0-or-later**. Apple's EULA/Usage Rules
  are GPLv2 §6 "further restrictions" that attach to **any** GPL binary in the Store package
  regardless of process or link boundary (FSF: GNU Go, VLC precedent); GPL-or-later code is
  MAS-shippable only with a copyright-holder GPLv3 §7 App-Store exception, which we cannot
  obtain for turbo — so MAS is out (see `research/08` §2). And because we embed/link the
  engine in-process (see §6), the combined ModernPAR binary is a GPL derivative work;
  **ModernPAR's own source must therefore be released under a GPL-2.0-compatible license**
  with a corresponding-source offer.
- The RAR engine (RARLAB UnRAR) carries a non-OSI field-of-use restriction and is
  **GPL-incompatible**. ModernPAR (itself open source, GPL-2.0-or-later) does not require
  every bundled component to be OSI-approved, so UnRAR is acceptable as an isolated,
  separately-licensed, extraction-only component — kept in its own translation units, never
  combined into the GPL engine's link unit, with its `license.txt` notice shipped verbatim.
  This coexistence is the top pre-release legal-review item.

> **Action item for the developer (not engineering):** obtain a real legal review before
> public release. The two engine licenses (GPLv2 and UnRAR's field-of-use clause) are
> mutually incompatible to *combine into one statically-linked binary*; §6 keeps UnRAR
> at arm's length to mitigate, but counsel should confirm. The "this is not legal advice"
> caveat from the research stands.

---

## 2. Target users & primary workflows

**Primary persona — the Usenet / NZB consumer.** Downloads multi-part RAR sets with PAR2
recovery files, often via SABnzbd/NZBGet-style tooling or manually. Needs to verify the
download is intact, repair it from recovery blocks if not, then extract the archive. This
is the dominant real-world workflow and the urgency driver (Rosetta retirement). The
gold-standard pattern they already know: **QuickCheck → full verify (only if needed) →
selective repair → unrar → done.**

**Secondary persona — the file-set distributor.** Has a folder of files (a release, a
backup, media) and wants to *create* a PAR2 set so recipients can recover from corruption
or missing parts. Cares about redundancy %, block size (matched to Usenet article size),
and recovery-file layout.

**Tertiary persona — the archive extractor.** Just wants to open a `.rar`/`.partNN.rar`/
`.zip`, including password-protected and multi-volume sets, with sane destination
handling. Overlaps heavily with persona 1.

### Primary workflows

1. **Recover an existing set (MVP core).** Open/drop a `.par2` → ModernPAR scans the
   containing folder, shows per-file status, auto-repairs if needed and possible, then
   auto-extracts any RAR inside. One window per set; cancel with ⌘. at any time.
2. **Extract an archive (MVP).** Open/drop the first volume of a RAR (or a zip) →
   destination-conflict-aware extraction with prompt-once password reuse.
3. **Create a set (v1).** Drag files (all in one folder) → choose PAR2 redundancy/block
   size → generate `Filename.volXXX+YY.par2` recovery files.
4. **Re-recover after acquiring more data (v1).** Keep the window open, fetch more
   recovery blocks/files, "Repair Again" (⌘R) — already-OK files are remembered and
   skipped.

---

## 3. Feature catalog (prioritized)

Priorities: **MVP** = first usable build (the Rosetta lifeboat: consume an existing set).
**v1** = feature parity / credible 1.0. **v2** = post-1.0. Pulled from
[`01-macpardeluxe-features.md`](./research/01-macpardeluxe-features.md); priorities here
are the authoritative roll-up (a few items are re-tiered from the source notes' "later",
noted inline).

### 3.1 Verify & repair (PAR2) — the core

| Feature | Description | Priority | Notes |
|---|---|---|---|
| Open & auto-verify PAR2 | Open/drop `.par2` → scan folder, verify all files; no extra click | **MVP** | Engine: `par2cmdline-turbo` (§6) |
| Auto-repair after verify | If files are damaged/missing and recoverable, repair in place automatically | **MVP** | Window can't be closed while busy |
| Per-file status list | Table with status icon + text per file (OK / bad checksum / missing / recoverable / recovered / not-in-set) | **MVP** | 11 file states; mirror original icon semantics (§3.6) |
| Document status line | Colored bottom-of-window status: **green** on OK end-state, **red** on not-OK | **MVP** | Reproduce the 17 `DocStatus` strings (MVP subset: verifying/repairing/canceled/all-ok/restored/generating/generated/waiting) |
| Cancel operation (⌘.) | Cancel any running op; status shows "Canceled." | **MVP** | Cooperative cancel via engine flag |
| Live progress | Determinate progress bar + phase text during verify/repair | **MVP** | Streamed engine events |
| "Need N more blocks" report | When recovery is insufficient, report exactly how many more recovery blocks/files are required | **v1** | Powered by native PAR2 parser (§6) |
| Full-folder scan for renamed/shifted data | Sliding-window match across all files in the folder to find renamed/moved/concatenated data | **v1** | Slow with many unrelated files → pair with the exclusion control below |
| Renamed-file detection & handling | Recognize "OK after renaming file 'X'"; report in status line | **v1** | |
| Retry / "Repair Again" (⌘R) | Keep window open between runs; remember already-OK files and skip them next run | **v1** | Session outlives one engine invocation |
| Folder-writability precheck | Verify the folder is writable before starting; refuse if the `.par` is in Trash | **v1** | `FolderReadOnlyErr`, `PARIsInTrashErr` equivalents |
| Verification levels | Quick (QuickCheck-style first-16k + size) → full → "additional" (hunt misnamed/relocated via SFV/MD5 sidecars) | **v1** | Matches MultiPar; QuickCheck-then-full is the gold-standard UX |
| Recursive scan + subfolder exclusion | User-tunable control over how much of the tree to scan | **v2** | Directly addresses the original's "many unrelated files is slow" warning |
| SFV/MD5 sidecar cross-check | Use `.sfv`/`.md5` to detect relocated/misnamed files | **v2** | MultiPar parity; nice-to-have |
| Show/Hide engine output | Collapsible raw engine-log pane ("Show par Output") | **v1** | Fed by engine `log` events |

### 3.2 Verify & repair (PAR1) — legacy

| Feature | Description | Priority | Notes |
|---|---|---|---|
| PAR1 verify/repair | Open `.par`/`.pNN` → verify, repair from Pnn volumes | **v1** | Native Swift GF(2^8) RS impl (gopar's BSD code is a clean reference); **do not** reuse the Intel `par` helper |
| PAR1 Pnn introspection | Per-Pnn status ("contains N recovery blocks", "N blocks from file X") | **v1** | The 7 `PxxFileStatus` strings |
| Non-contributing file handling | PAR1 sets can verify files (e.g. `.nfo`/`.sfv`) that don't contribute to parity | **v1** | Status "did not contribute to parity data" |

> **PAR1 stance:** legacy, deprioritized but *kept* for read/verify/repair. PAR1 is
> Usenet-era and obsolete (255-file ceiling, large volumes), but a clean native Swift
> implementation is small and fully specified, and it removes the last Intel-only binary.
> Default document type is **PAR2**. PAR1 *create* is v1 but lower within v1.

### 3.3 Create (PAR2 + PAR1)

| Feature | Description | Priority | Notes |
|---|---|---|---|
| Create PAR2 set (⇧⌘S) | Drag/add files (all one folder) → generate `.par2` recovery set | **v1** | Engine `c` verb via turbo |
| Redundancy % | `-r` 1–100; parity as % of set size | **v1** | Surface with a **live preview** of resulting file count/sizes (improvement over original) |
| Block size (KB) / Automatic | `-s` block size or auto from combined set size; helper text re: Usenet article size | **v1** | `Par2BlockSize` / `Par2BlockSizeChoice` |
| Limit recovery file size | `-l`: cap largest vol to repair the largest data file (else uniform `-u`) | **v1** | |
| Add / Remove files | Add Files (⌘F), Remove; enforce all-in-one-folder | **v1** | |
| Set-size limits | Enforce PAR2 ≤ 32768 files, PAR1 ≤ 255 files at add/save | **v1** | Surface "room for N more files" |
| Create PAR1 set | Generate `.pNN` volumes; count-based or fixed-number method | **v1** | Lower priority within v1 |
| Suggest base name | When all files share a base name, suggest it as the set filename | **v1** | |
| Resume-after-cancel on create | Restart an interrupted create without recreating the whole set | **v2** | Original v3.6 nicety |
| Advanced create knobs | `-c` recovery-block count, `-f` first block, `-n` file count, `-m` memory | **v2** | Not surfaced in original GUI; advanced/internal |

> **Create stance:** **v1, not MVP.** The urgent story is *consuming* sets you
> downloaded. Creation matters for parity but lands after the consume path works.

### 3.4 Unrar (RAR extraction)

| Feature | Description | Priority | Notes |
|---|---|---|---|
| Unrar archive (⌘U) | Pick first volume → extract | **MVP** | Engine: RARLAB UnRAR library (§6) |
| `.rar` + `.rNN` and `.partNN.rar` | RAR 2.x and 3.x+ multi-volume | **MVP** | |
| `.001/.002…` split archives | Split-volume form | **v1** | |
| Self-extracting `.exe`/`.partNN.exe` | SFX forms (rare; UnRAR handles transparently) | **v2** | |
| Single-vs-multi output folder | Multi-item → new folder named after archive; single top item → no wrapper folder | **MVP** | Matches Keka/Unarchiver |
| Destination conflict policy | Ask / Overwrite / Overwrite-all / Keep-both (rename) / Cancel | **v1** | `existingUnrarDestinationAction`; "keep both" renames existing first |
| Destination location pref | Beside archive (default) / always ask / fixed folder | **v1** | `chooseUnrarDestinationFolder` |
| Password (prompt once, reuse) | Prompt once, reuse for the whole archive | **v1** | Via `UCM_NEEDPASSWORDW` callback |
| Filename-encoding selection | When entries aren't UTF-8, offer a candidate-encoding picker; default UTF-8 | **v1** | Legacy RAR only (RAR5 = UTF-8); strong encoding detection is a UX bar (Unarchiver) |
| After-unrar segment policy | Move segments to Trash (default) / leave / delete permanently (with warning) | **v1** | `AutoDeleteSeg`, `DeleteSegOption` |
| Keep broken files on failure | Keep partially-extracted output even if unrar fails | **v1** | `KeepBrokenFiles` |
| Drop first file on dock icon | Dock-drop a `.rar` to start an unrar | **v1** | Via app delegate / `onOpenURL` |
| Auto-unrar after successful verify | Built-in unrar fires as a post-process rule after a clean set | **MVP** | The par2 + unrar coupling — the core differentiator |
| Progress window + Cancel | Current-file label, determinate bar, status, Cancel; stays visible in background | **MVP** | |
| Error mapping | Map the UnRAR error domain (bad data, wrong password, missing volume, etc.) to readable messages | **MVP** | `MPDUnrarErrorDomain11–24` equivalents |
| Finish notification → Show in Finder | UserNotification on success/fail with click-to-reveal | **v1** | |

### 3.5 Post-processing rules & extraction (non-RAR)

| Feature | Description | Priority | Notes |
|---|---|---|---|
| Built-in Unrar rule | `.rar` set → built-in unrar engine; not editable/deletable | **MVP** | The always-present default |
| zip extraction | `.zip` (incl. encrypted zip) → macOS libarchive | **MVP** | Replaces the original's OS `unzip`; libarchive is BSD, sandbox-friendly |
| Rule data model | Filename-pattern triggers → action; first-match-wins; one fires per set | **MVP** (model) / **v1** (editor) | |
| Auto post-process toggle | Run rules automatically after repair, or manually via "Apply Rule" | **v1** | `AutoPostProcess` |
| Rule editor | New/Modify/Delete/Up/Down/Revert-to-default | **v1** | |
| "Open in Finder" action | Reveal/open result as if double-clicked | **v1** | |
| "Open with app" action | Open result with a chosen application | **v1** | |
| "Run command-line script" action | Run a script with `%1` command / `"A"` macro | **v2** | **Modernize:** run via `Process`/`NSUserUnixTask` with inline output — *not* Terminal.app AppleScript |

### 3.6 Status vocabulary (reproduce faithfully)

Reproducing the original's exact state vocabulary is a hard requirement — it's the
recovery-app trust signal users rely on.

- **File states (11):** none / OK / invalid checksum / OK-after-rename / missing /
  missing-but-recoverable / missing-not-recoverable / bad-checksum-but-recoverable /
  bad-checksum-not-recoverable / recovered / not-in-set. Each maps to one of four status
  icons (OK, error, recoverable, not-in-set). **MVP** covers OK/bad/missing/recoverable/
  recovered/not-in-set + the recoverable-vs-not distinction; **v1** the full set.
- **Document states (17):** verifying / restoring / canceled / need-N-more / all-OK
  (± renamed) / restored (± renamed) / invalid-PAR / generating / generated /
  only-non-recoverable-missing / internal-error / waiting. **MVP** subset per §3.1; **v1**
  the rest. Keep the **green/red colored end-state** convention.
- **PAR1 Pnn states (7):** valid / no-recovery-blocks / duplicate-blocks / N-blocks /
  N-blocks-from-file-X. **v1.**

### 3.7 Preferences

Tabbed Settings window: **Basic / Par1 / Par2 / Unrar / Post-processing / Other**. Backed
by `@AppStorage` + an `@Observable Settings`.

| Setting | Tab | Priority | Notes |
|---|---|---|---|
| Auto-delete par files after restore (→ Trash) | Basic | **v1** | `AutoDeletePnn` |
| Close window after auto post-process | Basic | **v1** | `AutoCloseDocument` |
| Default document type (PAR1/PAR2) | Basic | **v1** | Default **PAR2** |
| Run unattended (no dialogs, safe defaults) | Basic | **v1** | Report via `os.Logger` + activity log + notification (not Console.app) |
| PAR1 Pnn-count method (count-based / fixed) | Par1 | **v1** | |
| PAR2 redundancy % | Par2 | **v1** | |
| PAR2 limit recovery file size | Par2 | **v1** | |
| PAR2 block size / Automatic | Par2 | **v1** | |
| Unrar: keep broken files | Unrar | **v1** | |
| Unrar: destination location | Unrar | **v1** | |
| Unrar: destination-conflict action | Unrar | **v1** | |
| Unrar: after-success segment policy | Unrar | **v1** | |
| Unrar: filename encoding | Unrar | **v1** | |
| Auto post-process toggle + rules list | Post-processing | **v1** | |
| Multiple-files: queue vs simultaneous | Other | **v1** | `SimultaneousProcessing` |
| Limit CPU cores | Other | **v1** | Maps to engine `-t`; default sensibly (verify ≈ I/O-bound → low; repair/create ≈ CPU-bound → scale). **Re-tiered to v1** from the source notes' "later" because over-threading verify on slow/network disks measurably hurts |
| Preferences shell + most-used toggles | — | **MVP** | A minimal Settings window with the highest-traffic toggles ships in MVP |

### 3.8 App-level UX, menus, notifications, drag-drop

| Feature | Description | Priority | Notes |
|---|---|---|---|
| One window per set | Custom `WindowGroup(for: SessionRoute)` — **not** `DocumentGroup` | **MVP** | A "document" is a folder-scoped session, not an editable file |
| Document/UTI registration | `.par2`, `.rar` (`.par` v1); double-click to open | **MVP** | Catch-all `*` type → drop target, not a registered doc type (**v2**) |
| Menu bar + shortcuts | Open+Repair ⌘O, Unrar ⌘U, Cancel ⌘., Create ⇧⌘S, Add ⌘F, Repair Again ⌘R, Close All ⌥W, Preferences ⌘, | **MVP** core verbs / **v1** rest | Via `commands`/`CommandGroup` |
| Drag files into list | Add files to a create set / open a set | **MVP** | Convert dropped URLs to security-scoped bookmarks immediately |
| Drop on dock icon / open-with | Route URL → new session window | **v1** | `NSApplicationDelegateAdaptor` + `onOpenURL` |
| Quit disabled while busy | Block Quit during a running op | **v1** | `applicationShouldTerminate` gating |
| Copy selected file names | ⌘C in the file list | **v1** | |
| Select All Non-OK | Select all erroneous files | **v1** | |
| Finder-style filename sort | `.sit.2` before `.sit.10` | **v1** | |
| Window/column persistence | Remember window size + column widths; alternating row colors | **v1** | |
| UserNotifications | Finish notification + "Show in Finder" action | **v1** | Replaces deprecated `NSUserNotification` |
| In-app Help | Help book / inline help | **v1** | |
| Sparkle auto-update | EdDSA-signed appcast | **v1** | Replaces the original's custom `versionlist.xml` poller |
| Localization (Dutch, others) | Ship English first; structure strings (String Catalogs) | **v2** | |

---

## 4. Non-goals & explicitly dropped features

| Dropped / non-goal | Rationale |
|---|---|
| **Mac App Store distribution** | Apple's Usage Rules are GPLv2 §6 "further restrictions" attaching to any GPL binary in the Store package, regardless of process/link boundary (FSF; VLC/GNU Go precedent); a copyright-holder GPLv3 §7 App-Store exception is the only escape and is unobtainable for turbo (`research/08` §2). Distribute Developer-ID/notarized DMG only. |
| **Creating RAR archives** | Legally forbidden by the UnRAR license (no RAR-compatible archiver) and never a MacPAR feature. ModernPAR creates PAR1/PAR2 only. |
| **StuffIt / `.sit` / `.sitx` post-process rules** | Dead format, discontinued tooling. Ship default rules for `.rar` and `.zip` only; power users can add a custom command rule. |
| **GPU offload for par2** | Every implementation (MultiPar, ParPar OpenCL) warns it's unstable and driver-dependent. Not worth the support burden; SIMD on Apple Silicon is already fast. |
| **PAR3** | Spec is an unratified ALPHA DRAFT (2022-01-28) with no stable Mac engine. Architect the engine behind a protocol so PAR3 can slot in later, but **do not** gate v1 on it. |
| **Custom XML auto-updater** | The original's `versionlist.xml` polling is dated/brittle. Replaced by Sparkle 2. |
| **Terminal.app AppleScript post-process** | Sandbox-hostile and fragile. If a command-action is built (v2), use `Process`/`NSUserUnixTask` with inline output, preserving `%1`/`"A"` macro compatibility. |
| **Console.app unattended reporting** | A 2018 idiom. Use `os.Logger` + a visible activity log + UserNotifications. |
| **Donation/shareware nags** | `Reminder.nib`, PayPal/Kagi UI, "I'll pay later" strings — ModernPAR is free/open; remove entirely. |
| **Crashlytics / Fabric** | Third-party crash SDK; privacy + maintenance burden. Use Apple crash reporting / MetricKit if anything. |
| **Resource-fork rejection on add** | Effectively extinct on modern macOS; keep at most a soft guard, no UI. |
| **PPC / 32-bit / GCD-era workarounds** | Irrelevant on arm64. Swift Concurrency replaces GCD. |
| **`libarchive`/XADMaster/p7zip for the RAR password/RAR5 path** | libarchive provably returns "encryption not supported" on encrypted RAR and has fragile multi-volume support; XADMaster's LGPL relink obligation and reimplementation-fidelity lag make it unattractive. UnRAR is the only reliable RAR backend. |
| **Recents in dock menu** | The original deliberately omits this (v4.2.6); ModernPAR keeps an in-app recents list instead. |
| **Hidden Debug menu** | Internal-only; drop. |

---

## 5. MVP success criteria

The MVP is the **Rosetta-retirement lifeboat**: it must let a user consume a set they
downloaded, end to end, natively on Apple Silicon. MVP is done when all of the following
pass on an arm64 Mac with **zero Rosetta dependency**:

1. **Verify + repair a real damaged set.** Take a PAR2 set produced by **MultiPar** (the
   reference creator), corrupt/delete some data blocks, open the `.par2` in ModernPAR,
   and confirm it auto-verifies, shows correct per-file status (bad/missing/recoverable),
   auto-repairs, and ends green with "Files restored successfully."
2. **Cross-tool create compatibility (deferred to v1 but smoke-tested in MVP if create
   lands early).** A PAR2 set created by ModernPAR verifies cleanly under stock
   `par2cmdline` *and* MultiPar. *(Create itself is v1; this criterion gates v1, listed
   here for traceability.)*
3. **Extract a multi-volume RAR.** Open the first volume of a `.partNN.rar` (and a
   classic `.rar`+`.rNN`) set and extract it correctly, with the single-vs-multi-item
   output-folder rule applied.
4. **Extract a password-protected RAR.** Prompt for the password once and reuse it for
   the whole archive.
5. **End-to-end pipeline.** Open a `.par2` whose set contains a RAR → verify → (repair if
   needed) → auto-unrar → result revealed; the whole chain runs without manual steps.
6. **Extract a zip,** including a password-protected zip, via libarchive.
7. **Cancellation works.** ⌘. cleanly aborts a verify, a repair, and an unrar, leaving the
   status as "Canceled." with no corrupt partial state the user can't recover from.
8. **Correct status & progress UX.** Per-file status icons, the green/red colored
   document status line, and a live determinate progress bar all behave per §3.6.
9. **Sandbox + bookmarks hold.** Granting a folder once lets ModernPAR read *and write*
   (in-place repair) across that folder and persist access across relaunch via
   security-scoped bookmarks.
10. **Distributable.** The app builds as an arm64-only, hardened-runtime, sandboxed,
    Developer-ID-signed, **notarized & stapled** DMG that launches on a clean machine
    without Gatekeeper warnings, with the GPL/UnRAR notices bundled in About.

**Performance bar:** verify/repair throughput should be clearly faster than MacPAR deLuxe
under Rosetta on the same hardware (par2cmdline-turbo's Apple-Silicon CLMul GF16 kernel
makes this near-automatic). The file-list Table must hold 60 fps at PAR2's max scale
(up to 32,768 files) with event coalescing; an `NSTableView` escape hatch is the budgeted
fallback if SwiftUI `Table` can't.

---

## 6. Engine & platform decisions (committed)

These are the load-bearing technical commitments the feature work depends on. Detail and
sources are in [`03`](./research/03-par2-format-and-algorithm.md),
[`04`](./research/04-swift-architecture.md),
[`05`](./research/05-archive-extraction-licensing.md), and
[`06`](./research/06-build-distribution.md); summarized here as decisions.

- **PAR2 engine: `par2cmdline-turbo` (animetosho), GPL-2.0-*or-later*.** Actively
  maintained (v1.4.0, 2026-02-09), SIMD GF16/MD5/CRC32 with an Apple-Silicon CLMul
  kernel. **Build from source** (it is **autotools**, *not* CMake — any plan assuming a
  `CMakeLists.txt` is wrong; needs a **C++14**-capable compiler) and vendor `src/` into a
  SwiftPM C++ target with a hand-written arm64 `config.h`, pinned to a release tag.
  - **Linking decision:** because ModernPAR is **open source**, we **embed** the engine
    via a C++ SwiftPM target behind a **mandatory C-style shim** (the shim catches all
    C++ exceptions — Swift cannot — and exposes only PODs / `const char*` / function
    pointers; no `std::string`/`std::function`/templates cross the boundary). The shim is
    imported by Swift as a plain **C** module, so the PAR2 path needs no
    `.interoperabilityMode(.Cxx)` at all; the only C++-interop target in the project is
    `ArchiveKit` (RAR/zip — see `ARCHITECTURE.md` §2). `ModernPARCore`/UI depend only on
    Par2Kit's pure-Swift `Sendable` API. *(If ModernPAR were closed-source we
    would be forced to the subprocess pattern to keep GPL at arm's length — but it is
    not, so in-process embedding is permitted.)*
  - **De-risk first:** before committing to embedding, build a spike that vendors
    turbo's `src/` with the arm64 `config.h` and a clean umbrella header — the
    mixed-C/C++ header vendoring is the most likely concrete failure point.
  - **Fallback (designed-in):** a `HelperProcessEngine` driving a bundled CLI via
    `Foundation.Process`, behind the same `PAR2Engine` protocol. This is the GPL license
    firewall and the interop-friction escape hatch; keep it real, not theoretical.
- **Native read-only PAR2/PAR1 parser in Swift.** A pure-Swift packet parser powers the
  file-status UI, "need N more blocks" math, set/file IDs, block-size/redundancy display,
  and vol-naming — reading has no compatibility trap, so it's low-risk and avoids
  shelling out for display.
- **PAR1 engine: native Swift GF(2^8) Reed-Solomon.** Small, fully specified; gopar's
  BSD-licensed code is a clean reference. Removes the last Intel-only binary.
- **RAR engine: RARLAB UnRAR, extraction-only, built from `unrarsrc` (current 7.2.4).**
  Linked as a static lib / XCFramework via a C/Obj-C++ shim (`RAROpenArchiveEx` /
  `RARProcessFileW` / `RARSetPassword` / `RARSetCallback`). **Do not** spawn the CLI
  (sandbox/codesign friction — Keka #1389). Keep it isolated from the GPL par2 engine.
  Ship `license.txt` verbatim in About; this is the only obligation.
- **zip engine: macOS `libarchive` (BSD-2-Clause),** linked via the SDK
  `libarchive.2.tbd` stub with vendored headers. Covers encrypted zip; sandbox-friendly.
- **App shell: custom `WindowGroup(for: SessionRoute)` + `Settings` scene** —
  **not** `DocumentGroup`. `@Observable` `AppModel` / per-window `OperationSession` /
  per-row `FileEntry`. Swift Concurrency (actors + `AsyncStream<EngineEvent>`), not GCD;
  cooperative cancel for ⌘..
- **SwiftUI-first with a small, well-defined set of AppKit bridges** (not "no
  bridging"): file-access plumbing (security-scoped bookmarks — convert *all*
  dropped/dock-dropped URLs to bookmark `Data` and resolve before any engine I/O),
  the dock-drop/open-with `NSApplicationDelegateAdaptor`, and the large-list
  `NSViewRepresentable(NSTableView)` escape hatch are the three planned bridge points.
  `fileImporter(allowedContentTypes:[.folder])` selects folders without `NSOpenPanel`.
- **Distribution: arm64-only** (deployment target macOS 14/15; universal is a one-line
  `ARCHS` change kept available), hardened runtime, App Sandbox, Developer-ID-signed,
  notarized & stapled DMG, Sparkle 2 updates. Entitlements: `app-sandbox`,
  `files.user-selected.read-write`, `files.bookmarks.app-scope`, `network.client`
  (Sparkle), plus Sparkle's two mach-lookup temporary exceptions. No MAS.

---

## 7. Differentiators vs. the original

What makes ModernPAR worth building beyond "the old one, but arm64":

1. **Native Apple Silicon + a modern SIMD engine.** par2cmdline-turbo's NEON/CLMul GF16
   path makes verify/repair markedly faster than par2SL-under-Rosetta — and it runs at
   all after Rosetta is gone.
2. **SwiftUI, dark-mode-first, drag-drop everywhere.** Table-stakes 2026 polish the 2018
   Cocoa app lacks.
3. **QuickCheck → full → additional verification levels.** Fast feedback first
   (MultiPar/SABnzbd-grade), full scan only when needed.
4. **Live create previews.** Show the resulting recovery-file count/sizes as the user
   tunes redundancy % and block size — the original exposed the knobs but never the
   consequences.
5. **Stronger filename-encoding handling** for legacy/Usenet RAR sets (Unarchiver-grade
   detection with a clear picker).
6. **Modern, sandbox-correct automation.** Post-process scripts run via
   `Process`/`NSUserUnixTask` with inline output instead of fragile Terminal.app
   AppleScript; unattended results surface as `os.Logger` + activity log + notifications
   instead of "open Console.app."
7. **Free, open, no nags, Sparkle-updated, notarized.** No shareware reminder windows, no
   Crashlytics, a real signed/notarized update channel.
8. **Recovery-first extraction.** The par2 → auto-unrar coupling — verify and repair the
   download *before* extracting — is the thing pure archivers (Keka, Unarchiver) don't do
   and the reason this is a recovery tool, not just an unarchiver.

---

## 8. Build order summary

- **MVP (consume path):** WindowGroup app + `.par2`/`.rar` types; open & auto-verify/
  repair PAR2 (turbo engine + native parser); per-file status icons + colored status
  line; Cancel (⌘.) + progress; Unrar (⌘U, multi-volume, password, single-vs-multi
  folder, error mapping, progress, finish-reveal); built-in unrar + zip post-process
  after verify; minimal Preferences shell; sandbox + bookmarks; notarized DMG.
- **v1 (parity):** PAR1 verify/repair/create (native Swift); PAR2/PAR1 create with
  redundancy/block-size/Pnn-count + live previews; full six-tab Preferences; rule editor
  (Finder/app actions); password reuse + encoding picker; Retry-recovery memory;
  verification levels; UserNotifications; queue-vs-simultaneous; copy-names /
  select-all-non-OK; window/column persistence; CPU-core limit; Sparkle; dock-drop;
  Help.
- **v2 (post-1.0):** command-line post-process action (modernized), recursive scan +
  subfolder exclusion, SFV/MD5 sidecar cross-check, SFX `.exe` RAR, resume-after-cancel
  create, advanced create knobs, `*` catch-all doc type, localization. PAR3 slot remains
  open behind the engine protocol but unscheduled.
