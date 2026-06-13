# ModernPAR — Build Roadmap (empty repo → shipping)

> Native arm64 macOS rewrite of MacPAR deLuxe 5.1.1. Swift 6.3 / SwiftUI / Xcode 26 / macOS 14+ target.
> This is the execution plan. The "why" lives in `docs/research/01..08`; this document **decides** and sequences.
> Verified locally 2026-06-09: Swift 6.3.2 (`arm64-apple-macosx26.0`), Xcode 26.5 (17F42), Homebrew `par2` 1.1.1 arm64.

---

## Settled architectural decisions (do not relitigate these mid-build)

These are the load-bearing calls that the phases below assume. Each resolves a real tension in the research.

1. **ModernPAR ships as open source under GPL-2.0-or-later.** *(CONFIRMED by the project owner 2026-06-09; the repo-root `COPYING` is the project license. This closed the last open licensing question — ARCHITECTURE.md §0 and the README, drafted under a permissive-posture assumption, have been reconciled to this decision.)* This is the *enabling* decision for everything else. par2cmdline-turbo is **GPL-2.0-or-later** (not bare GPLv2 — every source header grants "or later"). Statically linking it in-process makes the whole ModernPAR binary a GPL derivative. That is fine *only* because we choose to be GPL. This unblocks the doc-04 embedded-engine architecture and resolves the doc-03 ↔ doc-04 contradiction in favor of embedding. If the project owner ever wants closed-source, the **only** legal path is the subprocess fallback (Phase 2, Engine option B) — closed + linked GPL is a violation.

2. **PAR2 engine = par2cmdline-turbo, embedded as a C++ SwiftPM target behind a C-style shim** (doc-04 option a, primary). The shim is **non-negotiable**: Swift cannot catch C++ exceptions and libpar2 throws, so the shim catches everything and returns error codes, exposing only POD structs / `const char*` / function pointers. A `HelperProcessEngine` (subprocess, doc-03 pattern) is built behind the *same* `PAR2Engine` protocol as a designed-in fallback and GPL firewall.

3. **par2cmdline-turbo is autotools, not CMake.** Integration = vendor `src/*.cpp` + a hand-written `arm64-apple` `config.h` (committed, pinned to release tag **v1.4.0**) into the SwiftPM C++ target. There is no `CMakeLists.txt` to lean on. Requires a **C++14**-capable compiler (configure.ac says C++14, not merely C++11).

4. **RAR = RARLAB UnRAR source (unrarsrc, 7.2.4), built as a static lib, linked extraction-only.** Never spawn the `unrar` CLI (sandbox/codesign friction; the prebuilt binary has a more restrictive EULA than the source). UnRAR's license is GPL-incompatible, so it is kept in its **own translation units / its own component**, documented as a separately-licensed part, and never combined into the GPL par2 engine's link unit. **zip = macOS libarchive (BSD)** via the SDK `libarchive.2.tbd` stub. We **never** create RAR and **never** route RAR through libarchive (it returns `ARCHIVE_FATAL` on encrypted RAR).

5. **App shell = custom `WindowGroup(for: SessionRoute.self)` + `Settings` scene. NOT `DocumentGroup`.** A par2 "document" is a folder-scoped session, not an editable file blob.

6. **Distribution = Developer ID + Hardened Runtime + App Sandbox + notarized/stapled DMG, Sparkle 2 (EdDSA) auto-update. arm64-only. No Mac App Store.** *(Owner decision 2026-06-09: Option A of `docs/research/08`; no MAS edition planned.)* Precise reasons (08 §2): Apple's Usage Rules are GPLv2 §6 "further restrictions" that attach to any GPL binary in the Store package regardless of process/link boundary, and the MAS sandbox forbids spawning bundled CLIs. The UnRAR field-of-use clause is a softer, *chosen* blocker (RAR extraction is provably MAS-shippable — Keka). GPL-or-later code is MAS-shippable when the copyright holder grants a GPLv3 §7 App-Store exception — unobtainable for turbo — so the only MAS route would be a clean-room Swift PAR2 engine (08 §4–§5): researched, not planned.

7. **SwiftUI-first, with three known bridges** (per verified Claim 3): an `NSApplicationDelegateAdaptor` for dock-drop / open-with robustness; security-scoped **bookmark `Data`** round-trips for every dropped/opened URL before any engine I/O; and a budgeted `NSTableView` escape hatch if SwiftUI `Table` can't hold 60fps at 32k rows. "Little/no AppKit" is inaccurate — design these in.

---

## Phase map & MVP boundary

| Phase | Theme | MVP? |
|------:|-------|:----:|
| 0 | Project scaffold + module skeleton | — |
| 1 | Read-only PAR2/PAR1 parser + file-status model | foundation |
| 2 | PAR2 engine integration (embed turbo + shim) | **MVP** |
| 3 | Verify / Repair UX (open → auto-verify → auto-repair) | **MVP** |
| 4 | Unrar (RAR extraction) | **MVP** |
| 5 | Post-processing (built-in unrar + zip after verify) | **MVP** |
| — | **◀ MVP SHIP LINE — the Rosetta-retirement lifeboat ▶** | |
| 6 | Create (PAR2 + PAR1) | v1 |
| 7 | Preferences (all six tabs) + rule editor | v1 |
| 8 | PAR1 verify/repair (native Swift) + polish | v1 |
| 9 | Signing, notarization, Sparkle, DMG | ship |

**MVP = Phases 0–5.** That is the minimum that retires Rosetta for the *consume* path: open a PAR2 set, auto-verify/repair, auto-unrar, extract zip. Create, full preferences, the rule editor, and native PAR1 are v1 (Phases 6–8). Phase 9 (signing/notarize/Sparkle) is run as a thin track *throughout* — see its note — and finalized last.

---

## Phase 0 — Project scaffold & module skeleton

**Goal.** A buildable, testable, signable empty app with the final module topology in place, so no later phase has to restructure.

> **Status: DONE (2026-06-09).** Scaffolded and verified — `swift test` (5 tests) green, `xcodebuild` build green (arm64, ad-hoc signed, sandbox + entitlements applied), app launches. See `docs/SCAFFOLD.md` for the as-built spec.
>
> **Module-name reconciliation (updated 2026-06-09 — license decision confirmed):** the owner's confirmation of Decision 1 (ModernPAR is GPL-2.0-or-later) restores Decision 2 as written: the PAR2 engine is **embedded** (`Par2Cxx` C++ target + `extern "C"` shim, consumed by Swift as a plain C module — primary, spike-gated) with the subprocess `HelperProcessEngine` as the designed-in fallback; **both arrive in Phase 2** and live behind the same protocol. The **as-built** Phase 0 names: `ModernPARCore` (models + the `PAR2Engine` *protocol* + native parser/PAR1, C++-free), `Par2Kit` (Swift engine module — `MockEngine` now; `EmbeddedEngine` + `HelperProcessEngine` in Phase 2), `ModernPARUI` (SwiftUI). The old `RarComponent` name is now `CUnrar`; `ArchiveKit` + `CUnrar` + `CLibArchive` (the C++-interop quarantine) arrive in Phase 4. The Phase 0 scaffold is engine-agnostic (the protocol seam), so this decision required no restructuring. An interim draft of this note had declared subprocess-only under a permissive-license assumption; that draft is superseded. The module-topology bullets in the task list below are the original pre-build sketch, kept as **historical rationale only** — the as-built names above govern, and note the PAR2 path needs no `.Cxx` interop (`Par2Cxx` is consumed as a plain C module via its `extern "C"` umbrella; the only `.Cxx` target is `ArchiveKit`).

**Tasks.**
- Create `ModernPAR.xcodeproj` (app target, SwiftUI lifecycle, `@main App`) + local SwiftPM package `Packages/PARKit` (doc-06 Option C). App target links the `PARKit` library product statically.
- Module topology (the boundary discipline is the whole point):
  - `Par2Cxx` — C++ target, **empty stub** for now (will hold vendored turbo `src/` + `Par2Shim.{h,cpp}`).
  - `RarComponent` — C/Obj-C++ target, empty stub (UnRAR source + shim). License-isolated from `Par2Cxx`.
  - `PAR2Engine` — Swift, `.interoperabilityMode(.Cxx)`, depends on `Par2Cxx`/`RarComponent`; publishes a pure-Swift `Sendable` API. **The only target that touches C++.**
  - `ModernPARCore` — Swift, UI-free, C++-free. Models (`AppModel`, `OperationSession`, `FileEntry`, `Settings`, `SessionRoute`), services. Depends only on `PAR2Engine`'s Swift API.
  - `ModernPARUI` — SwiftUI views. Depends on `ModernPARCore`.
- Define the engine seam now, even though it's all stubs: `protocol PAR2Engine: Sendable { func run(_:) -> AsyncStream<EngineEvent> }`, plus `EngineOperation`, `EngineEvent`, `FileStatus`, `OperationPhase` enums (type sketches in doc-04 §10). A `MockEngine` conformance that emits canned events drives Phase 3 UI before the real engine exists.
- App scene: `WindowGroup(for: SessionRoute.self)` + `Settings { }` placeholder + `NSApplicationDelegateAdaptor`.
- Build settings baked in: `ARCHS=arm64`, `ONLY_ACTIVE_ARCH=NO` (Release), `MACOSX_DEPLOYMENT_TARGET=14.0`, `SWIFT_VERSION=6`, `ENABLE_HARDENED_RUNTIME=YES`, `ENABLE_APP_SANDBOX=YES`. Commit `ModernPAR.entitlements` verbatim from doc-06 §4c (sandbox, user-selected RW, app-scope bookmarks, network.client, Sparkle's two mach-lookup exceptions).
- CI: GitHub Actions `macos-26` runner. `swift test --package-path Packages/PARKit` + `xcodebuild build`. Ad-hoc signing on PRs; Developer-ID signing only on tags.
- Repo hygiene: `THIRD-PARTY-LICENSES`, GPL-2.0-or-later `COPYING`, source-offer note, and a placeholder for the verbatim UnRAR license paragraph.

**Demoable milestone.** The empty app launches, opens a blank session window, shows an empty `Table`, and `Cmd-,` opens an empty Settings window. `swift test` and `xcodebuild build` both green in CI.

**Exit criteria.**
- Clean `xcodebuild build` (arm64, sandbox on, hardened runtime on) and green `swift test`.
- `PAR2Engine` publishes a Swift-only API; `ModernPARCore`/`ModernPARUI` do **not** import any C++ module (verify by attempting an import — it must fail or be unnecessary).
- `MockEngine` drives a fake verify producing per-file `EngineEvent`s end-to-end into the UI.

---

## Phase 1 — Read-only PAR2/PAR1 parser & file-status model

**Goal.** Pure-Swift, read-only parser for `.par2` (and PAR1 `.par`/`.pNN`) that powers the document model with **zero** engine dependency. Reading has no compatibility trap (only writing/repair does), so this is low-risk and unblocks the whole UI.

> **Status: DONE (2026-06-09).** `Par2Parser`/`Par1Parser` in `ModernPARCore`, golden fixtures
> from par2cmdline 1.1.1 and the original Intel `par` tool (run under Rosetta), 46 tests green
> incl. hostile-input regressions (no `Int()`/overflow traps on crafted files, foreign-set
> hijack prevention, corrupt-packet tolerance). `OperationSession.open` + `SetHeader` wire the
> parser into the window (drop a `.par2`/folder, or the Open toolbar button). Notable spec
> subtlety learned from the fixtures: Main-packet File IDs sort as **little-endian 16-byte
> integers**, not memcmp order. Cross-tool read fixtures (turbo/MultiPar/ParPar) join in Phase 2.

**Tasks.**
- PAR2 packet scanner (doc-03 §2): find magic `PAR2\0PKT`, read length, **validate packet MD5 over bytes `[32, length)`** (not magic/length/MD5), dispatch on the 16-byte type tag, silently skip unrecognized/corrupt packets.
- Decode Main (slice size + sorted File-ID lists), File Description (File ID, full MD5, MD5-16k, length, ASCII name), IFSC (per-slice MD5+CRC32), Creator, Unicode-filename. Compute Recovery Set ID = MD5(Main body); confirm File ID = MD5(MD5-16k ‖ len ‖ name).
- Derive display facts: block/slice size, source-block count per file (`ceil(size/slice)`), redundancy, `vol XXX+YY` recovery-file naming, and the **"need N more blocks"** math (missing source blocks vs available recovery blocks).
- PAR1 reader (doc-03 §6): `PAR\0\0\0\0\0` signature, header, per-file entries (UTF-16 names), set/control hashes. Read/inspect only here; recovery comes in Phase 8.
- Map parsed state to the **exact MacPAR status vocabulary**: 11 `FileStatus` states with the recoverable/non-recoverable distinction and the four status icons (OK / error / recoverable / not-in-set), and the 17 `DocStatus` lines with the green/red end-state convention (doc-01 §2.2–2.3).

**Demoable milestone.** Drop a `.par2` on the window → the file list populates with names, sizes, and "pending" status; the document header shows set size, block size, redundancy %, and recovery-block count — all without invoking any engine.

**Exit criteria.**
- Parser round-trips a corpus of real-world `.par2` index files (from par2cmdline, par2cmdline-turbo, MultiPar/par2j, ParPar) and extracts identical metadata. Cross-tool reads are byte-faithful.
- Deliberately corrupted packets are skipped, not fatal.
- `FileStatus`/`DocStatus` enums cover the full doc-01 catalog; unit tests assert the icon + recoverable mapping per state.

---

## Phase 2 — PAR2 engine integration (embed turbo + C shim) · **MVP**

**Goal.** Real verify/repair/create capability through `EmbeddedEngine`, the in-process par2cmdline-turbo wrapper. This is the single highest-risk phase; de-risk it with a spike before committing.

**Tasks.**
- **Spike first (mandatory, time-boxed).** Vendor turbo `src/` for tag **v1.4.0** into `Par2Cxx`; hand-write `config.h` for `arm64-apple` (endianness + intrinsics `#ifdef`s); add a clean umbrella header. Prove a trivial Swift call into one turbo symbol compiles and links. SPM treats headers as C by default and `exclude:` doesn't cover headers — this header/build vendoring is the most likely concrete failure point. **If the spike doesn't land in its box, fall back to Engine option B (below) for MVP and revisit embedding post-ship.**
  > **Spike status: LANDED (2026-06-10).** turbo v1.4.0 vendored unmodified into
  > `Packages/PARKit/Sources/Par2Cxx/vendor/` (src + parpar gf16/hasher; CLI/OpenCL/upstream-test
  > files excluded in Package.swift, not deleted); committed hand-written `config/config.h`;
  > `extern "C"` `par2shim.h` umbrella imported by Swift as a plain C module — **no `.Cxx`
  > interop needed**, exactly as designed. Swift tests verify AND repair the golden fixture
  > through the embedded engine (byte-identical restoration) and exceptions never cross the
  > boundary. Findings: (1) the vendoring risk did not materialize — clean build on first try;
  > (2) SPM's no-per-file-flags limit is handled by ParPar's own platform guards (x86/SVE
  > kernels compile to dispatcher stubs; NEON + SHA3/CRC are compiler-baseline on
  > arm64-apple, so the fast ARM paths are all live); (3) one real trap: `par2repair`'s
  > `memorylimit` must NOT be 0 — the CLI defaults it to half of physical RAM, and the shim
  > now mirrors that (a literal 0 means a zero-byte working buffer and pathological
  > one-slice-at-a-time grinding). Remaining Phase 2 work below proceeds on the embed path.
  >
  > **Engine status (2026-06-11): `EmbeddedEngine` LANDED.** Verify/repair/create through the
  > embedded turbo with live `EngineEvent` streams (`TurboOutputParser` shares the output
  > vocabulary with the future helper engine), cooperative cancellation (cancel token polled in
  > the shim's streambuf; throws unwind the engine), phase-weighted monotonic progress, and the
  > folder's files passed as extra files (renamed/misnamed-data detection, incl. the engine's
  > own `name.1` backups after an interrupted repair). An adversarial review confirmed and we
  > fixed: a **use-after-free crash on cancel-mid-repair** (ParPar's worker pool was never
  > joined — upstream's own "TODO: join threads?"; fixed via vendor patches recorded in
  > `vendor/VENDORED.txt`), engine-run overlap after cancel (all embedded runs now serialize on
  > one queue), Unicode/backslash filenames getting no per-file events (roster keyed by the
  > engine's par2→local name translation), verify-only runs ending stuck on "Repairing", and
  > swallowed engine failures. 68 tests green. **Still open in Phase 2: the
  > `HelperProcessEngine` fallback implementation** (stub today; the shared output parser is
  > ready for it) — both engines must then pass the same protocol-level suite.
- Write `Par2Shim.{h,cpp}` (doc-04 §10): `extern "C"` `par2_verify` / `par2_repair` / `par2_create`, each taking POD args + a `bool (*cb)(void *ctx, int kind, double frac, const char *name, int status)` progress callback. The shim **catches all C++ exceptions** (libpar2 throws) and returns error codes; no `std::string`/`std::function`/templates cross the line.
- `EmbeddedEngine: PAR2Engine` — runs the blocking C++ on `Task.detached`, bridges shim callbacks into `AsyncStream<EngineEvent>`. Cancellation: `continuation.onTermination` sets an atomic flag; the callback returns `false` to stop turbo cooperatively (this is the Cmd-. path, doc-04 §5.2).
- Wire `cpuCoreLimit` to turbo's `-t` thread count (replaces the old GCD parallelism; satisfies "limit CPU cores").
- **Engine option B (fallback, build it anyway):** `HelperProcessEngine: PAR2Engine` driving a bundled turbo CLI via `Foundation.Process`, parsing stdout for progress/per-file status. Same protocol. This is the GPL firewall and de-risks interop friction. Pin the helper version; snapshot-test the stdout parser.
- Memory-coalesce engine events before applying to `@Observable` state (don't invalidate 32k rows per frame).

**Demoable milestone.** From a CLI test harness (no UI needed), `EmbeddedEngine.run(.verify)` on a known-good set streams per-file `OK` events and a `finished(.success)`; on a damaged set it streams `missingRecoverable` then `recovered` after `.repair`.

**Exit criteria.**
- `EmbeddedEngine` verifies, repairs, and creates against golden sets with results **byte-identical to upstream par2cmdline-turbo CLI** (proves the matrix/slice-ordering compat).
- Cancellation mid-verify and mid-repair stops the C++ within ~1s and leaves files in a defined state.
- Both `EmbeddedEngine` and `HelperProcessEngine` pass the same protocol-level test suite (swappable).
- The C-shim leaks no C++ exceptions to Swift (fuzz with malformed inputs).

---

## Phase 3 — Verify / Repair UX · **MVP**

**Goal.** Reproduce the core MacPAR loop: open a `.par2` → auto-verify → auto-repair if needed, with live per-file status and cancellation.

> **Status: DONE (2026-06-11), with Phase 2 closed out in the same push.**
> *Phase 2 completion:* `HelperProcessEngine` implemented over the vendored CLI (built as the
> `Par2HelperCLI` SPM executable via unity-includes; no source forking) and held to the same
> protocol-level scenarios as the embedded engine. Hardening from adversarial review: signal
> deaths are never mapped through the Result table (SIGHUP used to read as "verify success"),
> SIGTERM→SIGKILL escalation prevents a wedged child from holding the shared engine queue
> forever, runs go straight onto the serial queue (no pinned Swift-concurrency pool threads),
> and parent pipe write-ends close after launch (EOF correctness).
> *Phase 3:* open → auto-verify → auto-repair from drop / Open / Cmd-O / Finder double-click /
> dock drop (cold-launch opens claim the pristine window — no stray empty window); restored
> windows re-open parse-only and **never** auto-fire repair (route freshness is consumed once
> per launch); one-time "grant this folder" powerbox flow with persisted app-scoped bookmarks
> (grants validated to actually cover the set; ancestors count); renamed-file detection
> ("is a match for" → "OK after renaming", `.restoredWithRenames`, roster-validated parsing
> against delimiter-hostile names); quit gating via a weak-tracking `OperationRegistry` +
> alert; closing a window cancels its run; Cmd-./Verify Only/Repair Again menu commands via
> focused values; Repair button appears on the awaiting-consent verdict; 32k-row apply-path
> smoke test. 91 tests green. Remaining for later phases: the `NSTableView` escape hatch is
> untriggered (no real-set fps measurement yet), and the helper is not yet bundled into the
> app (Phase 9 fallback-build wiring).

**Tasks.**
- `SessionWindow` resolves `SessionRoute` bookmarks → URLs, builds `OperationSession`, auto-starts verify (then repair if needed). One `OperationSession` per window owns the running `Task`.
- **Folder-scope acquisition.** Opening a single `.par2` grants only that file; verify scans the *whole folder*. Implement the one-time "grant this folder" powerbox flow (`fileImporter`/`NSOpenPanel` pre-pointed at the parent), persist an **app-scoped security-scoped bookmark**, and bracket every engine op with `start/stopAccessingSecurityScopedResource()`.
- File list: `Table` (name / status icon / size), stable `Identifiable` ids, `.equatable()` rows, alternating row backgrounds. Colored document status line (green OK / red not-OK).
- Cancel (Cmd-.) via `CommandGroup` + toolbar item → `session.cancel()`; disabled when not busy. **Quit disabled while any session busy** (`applicationShouldTerminate` → `.terminateCancel`).
- Toolbar (MVP subset): New, Open+Repair (Cmd-O), Repair-again, Cancel. Collapsible "engine log" pane (Show/Hide par Output).
- "Need N more blocks" reporting from Phase 1 math when recovery is insufficient.
- Drop-on-list and drop-on-dock entry points → bookmark immediately on receipt, route to a new `SessionRoute` window.

**Demoable milestone.** Double-click a damaged PAR2 set in Finder → ModernPAR opens, scans the folder, shows per-file icons flipping to recoverable, repairs in place, and the status line turns green: "Files restored successfully." Cmd-. cancels a long verify cleanly.

**Exit criteria.**
- End-to-end open → verify → repair works from Finder double-click, dock-drop, and Cmd-O, all sandbox-correct.
- 32k-row set renders and live-updates at ≥60fps with event coalescing (if not, invoke the `NSTableView` fallback — budgeted, not a surprise).
- Renamed-file detection surfaces "OK after renaming"; insufficient-recovery surfaces "need N more blocks".
- Restored windows on relaunch do **not** auto-fire a destructive repair without consent.

---

## Phase 4 — Unrar (RAR extraction) · **MVP**

**Goal.** Extract RAR sets (the dominant Usenet payload) natively, matching the Keka/Unarchiver UX bar.

> **Status: DONE (2026-06-11).** unrarsrc 7.2.4 vendored into `CUnrar` behind the pure-C
> `unrarshim` umbrella (extraction/listing ONLY; **three documented local patches** fixing
> unrar.dll's sticky-error misreporting — see `CUnrar/vendor/VENDORED.txt` before any bump;
> NO `.Cxx` interop anywhere — Swift consumes CUnrar as a plain C module, beating the planned
> quarantine). `ArchiveKit.RARExtractor` does a list pass + staged extract with
> single-item/wrapper placement, conflict policy (ask/overwrite/keep-both/cancel with a
> source-volume trash guard), prompt-once password caching across both passes, first-volume
> normalization with fail-fast on a missing first volume, and mapped readable errors
> (RAR5-aware wrong-password vs damaged-data diagnosis). UI: Cmd-U panel, auto-extract on
> fresh routes (restored windows never auto-run), modal password prompt with a
> wrong-password re-prompt loop, progress + cancel, "Extraction finished" notification with
> Show in Finder (delegate installed at launch), keep-broken-files preference end-to-end,
> verbatim UnRAR license paragraph in Settings → Unrar + THIRD-PARTY-LICENSES.md. Exit
> criteria verified by 54 extraction tests against a real-archive corpus (RAR 1.5/2.0/3/5,
> both multi-volume styles, passwords, encrypted headers, unicode, solid; rarfile corpus,
> ISC) plus synthesized hostile fixtures — including regressions for every confirmed finding
> of the **20-finding adversarial review** (silent file-loss after mid-archive corruption,
> warning-skips failing whole runs, false success on missing first volumes, UI race killing
> the password re-prompt, notification lies, quit-gate drain). `.001`/SFX first-file forms
> and the "extract to" destination picker remain v1 (Phase 7 binds the remaining prefs).
> 145 tests green; libarchive is NOT in the RAR path; no CLI is ever spawned.

**Tasks.**
- Build RARLAB UnRAR (unrarsrc 7.2.4) as a static lib in `CUnrar` (consumed by `ArchiveKit`); C/Obj-C++ shim exposing `RAROpenArchiveEx` / `RARProcessFileW` / `RARSetPassword` / `RARSetCallback`. `RARExtractor: ArchiveExtractor` Swift API (ARCHITECTURE.md §1.4, §6).
- First-file forms (MVP): `.rar` + `.rNN`, `.partNN.rar`. (`.001/.002` and SFX `.exe` are v1/later.)
- Multi-volume continuation via the `UCM_CHANGEVOLUMEW` callback; **password prompt-once-and-reuse** via `UCM_NEEDPASSWORDW`.
- Output placement: multi-item → new folder named after the archive (extension stripped); single top-level item → no enclosing folder.
- Destination-conflict policy: ask / overwrite / keep-both / cancel (MVP: a working dialog; "overwrite all" is v1).
- Progress window: current-file label, determinate bar, Cancel; stays visible in background. Map the UnRAR error domain (`MPDUnrarErrorDomain11–24` + glue) to readable messages.
- Ship the **verbatim UnRAR license paragraph** in the acknowledgements view (the license's only obligation).

**Demoable milestone.** Cmd-U a multi-volume password-protected `.partNN.rar` set → one password prompt → progress → extracted files land in a correctly-named folder; a notification fires with "Show in Finder."

**Exit criteria.**
- RAR2/RAR3/RAR5 + multi-volume + password all extract correctly via the linked lib (no CLI spawn).
- Wrong/missing password and corrupt archives produce mapped, user-readable errors; "keep broken files" preference honored.
- libarchive is **not** in the RAR path (encrypted RAR must hit UnRAR).

---

## Phase 5 — Post-processing (auto-unrar + zip after verify) · **MVP** · *MVP ship line*

**Goal.** Reproduce the SABnzbd/NZBGet pipeline: a successful verify/repair chains into extraction automatically.

> **Status: DONE (2026-06-11). ★ THE MVP SHIP LINE — a user can now retire Rosetta for the
> entire consume path.** `CLibArchive` header-bridges the SYSTEM libarchive (vendored 3.7.4
> headers + `.linkedLibrary("archive")`, `_Static_assert` version pin, version-skew rule in
> VENDORED.txt — no `.Cxx` interop, like the rest of the project). `ArchiveKit.ZipExtractor`
> drives libarchive's streaming read + secure write-disk loop (ZipCrypto + WinZip AES,
> Zip64, store/deflate/LZMA/ZSTD), sharing the Phase 4 staging/placement/conflict/password
> machinery (refactored into `ExtractPlacement`); two-layer path safety (name sanitization +
> SECURE_SYMLINKS/NODOTDOT with realpath-resolved staging), unsafe-symlink skipping matching
> the RAR engine, prompt-once passwords, keep-broken honored. `PostProcessRules`
> (fnmatch, first-match-wins, one-per-set; built-ins .rar→Unrar, .zip→Unzip) + a verify/repair
> green end-state chains into extracting the matched payload WITHIN the same window
> (`postProcessReady` trigger + `OperationSession.chainIntoArchive`, log preserved); a chained
> extraction's own green end never re-fires the chain. UI: auto post-process toggle (default
> on, `AutoPostProcess`), Operation ▸ Apply Rule for the manual path, .zip routed from
> Cmd-U/Open/drop, notification with Show in Finder. libarchive is NEVER in the RAR path; no
> CLI is ever spawned. The end-to-end milestone (create a set over a .rar AND a .zip payload →
> open → verify → auto-extract) is a real-engine test. 177 tests green; the 21-agent
> adversarial review confirmed 15 findings (2 high: silent zip data loss on damaged-tail
> streaming archives; auto-chain dying under the sandbox on second launch) — all fixed with
> regression tests. The rule editor, "extract to" picker, and non-default rule reordering are
> Phase 7.

**Tasks.**
- `PostProcessRules` data model (filename-pattern match, first-match-wins, one fires per set). Two default rules for MVP: `.rar` → built-in `UnrarEngine`; `.zip` → macOS libarchive (BSD, via `libarchive.2.tbd`). **Drop StuffIt** entirely.
- Pipeline glue: on verify/repair success, the `OperationSession` chains into the matched post-process operation within the same session (the operation *chains into* another operation).
- zip extraction via libarchive streaming C-API shim (supports ZipCrypto + WinZip AES, Zip64, deflate/LZMA/ZSTD). `ditto -x -k` only as a non-sandboxed Developer-ID fallback.
- "Auto post-process after repair" toggle; manual "Apply Rule" command for when it's off.
- Finish notification with "Show in Finder" (`UserNotifications` + `NSWorkspace.activateFileViewerSelecting`).

**Demoable milestone.** Open a PAR2 set whose payload is a `.rar` → verify passes → auto-unrar fires → extracted files appear → notification. Same for a `.zip` payload. End-to-end, hands-off.

**Exit criteria.**
- Auto verify → repair → unrar/unzip chain runs without user clicks (matches the original pipeline).
- Rule matching is deterministic (top-to-bottom, one fires per set).
- zip with both encryption schemes extracts correctly under sandbox.
- **★ This is the MVP. A user can retire Rosetta for the entire consume path.** Cut a notarized internal build here (Phase 9 track) and dogfood.

---

## Phase 6 — Create (PAR2 + PAR1) · v1

**Goal.** Author new recovery sets.

> **Status: PAR2 create DONE (2026-06-11).** The build-a-set window (`CreateSetView`) over the
> already-tested `par2shim_create` path: add files / drop a folder (one-folder enforced, symlink-
> resolved, nested-subfolder content surfaced not silently dropped), redundancy % stepper, block
> size Automatic/Manual-KB, recovery-file scheme (limit-to-largest / uniform), a live source +
> recovery block-count preview, validation mirroring the originals (redundancy 1–100, block size
> 1–419430 KB, 32768 source-block ceiling checked against the EFFECTIVE size in every mode), and
> Create (⇧⌘S). `EmbeddedEngine: Par2Creator` streams the same `EngineEvent`s as verify (a
> `CreateBridge` parses "Processing: X%" → progress); folder read-write is acquired via the
> existing grant flow and the output always lands in the SOURCE folder; on success it reveals the
> set in Finder; a cancelled/failed create cleans up its partial `.par2`/volumes. **Created sets
> verify clean through both the embedded turbo engine and cross-tool `par2cmdline` 1.1.1** (the
> headline exit criterion), across automatic/manual block sizes, both schemes, and 1–100%
> redundancy. The 19-agent adversarial review confirmed 11 findings (1 high: recovery files
> landing in a granted ANCESTOR folder instead of the source folder; mediums: many-small-file
> sets passing validation then failing in-engine, a validation/preview contradiction) — all fixed
> with regression tests. 205 tests green. **PAR1 create is deferred to Phase 8** (it rides on the
> native Reed-Solomon code written there); the resumable-after-cancel nicety is deferred.

**Tasks.**
- Build-a-set UI: drag from Finder / Add Files (Cmd-F), **all files must be in one folder** (enforced), Remove, set-size limits (PAR2 ≤ 32768 blocks, PAR1 ≤ 255 files).
- Create PAR2 (Shift-Cmd-S) → `EmbeddedEngine.run(.create(opts))`. Surface only the user-facing knobs (per doc-02 rec): **redundancy %** (`-r`), **block size KB / Automatic** (`-s`), **limit file size to largest data file** (`-l`) vs **uniform** (`-u`). Keep `-c/-f/-n/-m` internal.
- Create PAR1 (native, deferred to Phase 8's RS code, or via a small create path): Pnn count "by file count" vs "fixed number."
- Validation messages mirroring the originals (redundancy 1–100, block size 1–419430).
- Resumable-after-cancel create nicety.

**Demoable milestone.** Drag a folder of files in, pick 10% redundancy + automatic block size, Create → `data.par2` + `data.volNNN+YY.par2` files appear and **verify clean in MultiPar/par2cmdline** (cross-tool).

**Exit criteria.**
- Created sets verify/repair correctly in par2cmdline, par2cmdline-turbo, and MultiPar/par2j (proves matrix + naming + sizing compat).
- "One folder" and size-limit enforcement match the original; validation errors reproduced.

---

## Phase 7 — Preferences (six tabs) + rule editor · v1

**Goal.** Full preference surface and the extensible rule engine.

> **Status: DONE (2026-06-12).** All six Settings tabs (Basic / Par 1 / Par 2 / Unrar /
> Post-processing / Other), every knob UserDefaults-backed under the ORIGINAL defaults key
> (doc-01 §5; `unrar.keepBrokenFiles` migrated to `KeepBrokenFiles`), defaults matching the
> original where carried over (segments default to move-to-Trash). The rule editor
> (New/Modify/Delete/Up/Down/Standard) with "Open in Finder" and "Open with application"
> actions; the built-in Unrar rule is now ALWAYS-LAST and non-editable/non-deletable
> (structural — it is never stored), reconciling Phase 5's deliberate rar-first divergence:
> a set carrying both `.zip` and `.rar` now consumes the zip, as the original did. User rules
> may also target the built-in extractors (e.g. `*.cbr` → Unrar). Implemented behaviors:
> AutoDeletePnn (restore-only, Trash-only, never on a plain all-OK verify), AutoCloseDocument
> (after the automatic chain ends green; cancel disarms), UnattendedOperation (every prompt —
> password, conflict, destination, encoding, and the folder-grant panel — declines to a safe
> default and failures arrive as notifications), unrar destination (beside / ask / fixed
> folder, with a STALE-bookmark fallback because security-scoped bookmarks follow a moved or
> trashed folder by file ID), conflict-default auto-answer, segment disposal (trash / leave /
> delete-permanently behind a real confirmation; only FULLY delivered runs dispose — skipped
> entries keep the volumes), the one-by-one multi-open queue (`MultiOpenQueue` + the
> session's `runEnded` settlement signal; the claimant's first file queues too), Edit ▸ Copy
> file names (`.copyable`) and Select All Non-OK, window-size + Table column persistence, and
> the `DefaultPar` launch route (create windows host the open-files handler so Finder opens
> are never swallowed). **RAR filename encoding:** vendored UnRAR's UTF-8 `CharToWide`
> TRUNCATES legacy codepage names at the first invalid byte — such archives previously failed
> extraction entirely; the shim now captures raw header name bytes (vendor LOCAL PATCH #4)
> and redirects affected entries to properly decoded paths via the DLL's per-entry DestName
> (curated 13-charset candidate sheet, `PrefFilenameEncoding`, lossy-UTF-8 fallback; tested
> end-to-end over synthesized RAR 1.5 archives). The 25-agent adversarial review confirmed 11
> distinct findings (2 high: a directory entry silently REPLACING an extracted file under the
> forced-overwrite DLL — data loss with a success verdict; the multi-open queue poisoned
> forever by a cancelled destination panel) — all fixed with regression tests, 1 finding
> refuted by a runtime probe, 3 nits fixed. 277 tests green. Deferred: the Terminal/
> AppleScript rule action (dropped for v1 by design), CPU-core limit [later], live rule-list
> sync while the Settings window and a running chain race (none observed).

**Tasks.**
- `Settings` scene `TabView`: Basic / Par1 / Par2 / Unrar / Post-processing / Other. Back with `@AppStorage` + `@Observable Settings`. Map to the original defaults keys (doc-01 §5): `AutoDeletePnn`, `AutoCloseDocument`, `DefaultPar`, `UnattendedOperation`, `Par2Redundancy`/`Par2BlockSize`/`Par2BlockSizeChoice`/`Par2LimitFileSize`, `KeepBrokenFiles`, `chooseUnrarDestinationFolder`, `existingUnrarDestinationAction`, `AutoDeleteSeg`/`DeleteSegOption`, `AutoPostProcess`, `SimultaneousProcessing`.
- Rule editor (`EditPPRuleController` equivalent): New/Modify/Delete/Up/Down/Standard; action types "Open in Finder" and "Open with app." **Drop** the Terminal/AppleScript action for v1; if added later, use `Process`/`NSUserUnixTask` with inline output (keep `%1`/`A` macro compat), never AppleScript-driven Terminal.
- Auto-delete par/segments → **move to Trash** (with the permanent-delete warning); design around sandbox.
- One-by-one vs simultaneous multi-open queue (`SimultaneousProcessing`).
- Edit-menu extras: Copy selected file names, Select All Non-OK. Window size + column-width persistence.
- RAR filename-encoding picker (`PrefFilenameEncoding`) for legacy non-UTF-8 RAR; default UTF-8 with fallback sheet.

**Demoable milestone.** Every preference round-trips and visibly changes behavior; a user-authored "open with app" rule fires after a successful verify.

**Exit criteria.**
- All six tabs functional and persisted; defaults match the original where carried over.
- Rule editor add/edit/reorder/revert works; built-in Unrar rule is always-last and non-deletable.
- **Drop** confirmed: no donation nags, no Crashlytics, no custom XML updater, no StuffIt, no Debug menu.

---

## Phase 8 — Native PAR1 verify/repair + polish · v1

**Goal.** Remove the last Intel-only dependency by implementing PAR1 recovery natively; final UX polish.

> **Status: DONE (2026-06-12).** PAR1 is fully native — verify, repair, AND create — with the
> math pinned EMPIRICALLY against the original Intel `par` binary: `GF256`/`Par1RS`
> (polynomial 0x11D, volume `v`'s coefficient for 1-based in-set file `j` = `j^(v-1)`,
> zero-padding to the largest ROSTER file, index sorted lexicographically — every constant
> proven by byte-comparing computed parity against a new golden corpus of 8 oracle-generated
> sets, 19 volumes, including unicode rosters, an empty file, non-contributing `+i` entries,
> and the volume-sizing quirk). `Par1Engine` streams the same `EngineEvent`s as the PAR2
> engines (an `EngineRouter` dispatches on the anchor's form, so call sites still inject ONE
> engine): MD5 verify with renamed-file detection, set-level recoverability (4/4A "need N
> more files", 4B "Cannot restore." for the spec's singular-submatrix flaw), chunked RS
> repair with `.1` backups and MD5-verified, atomically-placed output, fix-faulty-filenames,
> Pnn introspection log lines, and retry that skips this session's already-OK files (size
> revalidated). `Par1CreateEngine` authors `.par` + lowercase `.pNN` byte-identical in parity
> to the Intel binary, which verifies our sets clean (`par c`, exit 0 — exercised for real in
> a local-only test); the build window gained a PAR1 mode (File ▸ New PAR 1 Set) honoring the
> Par1 Settings tab. Polish: "Canceled." (DocStatus3) survives on screen, DocStatus 6/8,
> 10, 13/14 complete, Finder-style numeric filename sort (hand-rolled comparator —
> `localizedStandardCompare` broke the 32k-row scale budget), RAR `.001` splits and SFX
> `.exe` first-file forms (signature-sniffed routing), "Overwrite All" conflict answer
> (per-run, broker-cached), in-app Help window (⌘?), `defaultLocalization` scaffolding, and
> a CI gate asserting every Mach-O in the bundle is arm64-only (verified locally too: `lipo
> -archs` = arm64 everywhere, no Intel helper was ever bundled). The 15-agent adversarial
> review confirmed 6 distinct findings (mediums: a crafted volumeNumber trapping the app, a
> directory squatting on a roster name recursively DELETED by repair — now moved aside as a
> backup, create-failure cleanup deleting files it never created — now exclusive-create +
> created-list, render-path file I/O for sniffed anchors — now cached on the session; lows:
> a comparator strict-weak-ordering cycle on fullwidth digits, an unfiltered rename scan,
> whole-file volume discovery — now a streaming probe) — all fixed with regression tests;
> 2 findings refuted (one by a runtime probe of Foundation's fd-limit behavior). 331 tests
> green. Deferred: PAR1 verify-anchor whole-file read at open (low; repair already streams),
> resumable-after-cancel create, localization beyond English scaffolding.

**Tasks.**
- Pure-Swift PAR1 verify/recover: GF(2^8) RS over ≤255 files (gopar's BSD PAR1 code is a clean reference). Whole-file byte-parallel RS; parity volumes sized to the largest input. Wire into the existing session/status UI.
- PAR1 Pnn introspection states (`PxxFileStatus1–7`), "did not contribute to parity" file class, fix-faulty-filenames.
- Polish: full `DocStatus` line set (4/4A/4B, 6/8, 9/10, 13/14, 15), Finder-style filename sort (`.sit.2` before `.sit.10`), `.001/.002` and SFX `.exe` RAR forms, "overwrite all" conflict option, retry-recovery "remembers OK files, skip on rerun."
- Help (inline or Help book), localization scaffolding via String Catalogs (English first).

**Demoable milestone.** Verify and repair a damaged PAR1 `.par` set entirely natively (no Rosetta, no Intel binary anywhere in the bundle).

**Exit criteria.**
- PAR1 recovery cross-checks against a reference PAR1 implementation on golden sets.
- No x86_64 slice and no bundled Intel helper anywhere (`lipo -archs` on every Mach-O = `arm64`).
- Retry-recovery skips already-OK files on rerun.

---

## Phase 9 — Signing, notarization, Sparkle, DMG · ship track

> **Run this as a thin track from Phase 0, not just at the end.** Hardened Runtime + sandbox are on from day one; the first notarized DMG should be cut at the MVP ship line (end of Phase 5) and re-cut each milestone. The list below is the *finalization*.

> **Status: HEADLESS SCAFFOLD DONE (2026-06-12) — blocked on owner credentials for the first
> notarized cut.** Everything that runs without secrets is in place and exercised:
> - **Sparkle 2.9.3 via SwiftPM** (exact-version pin, `Package.resolved` committed). Sparkle ships
>   universal binaries, so a build phase (`Scripts/thin-frameworks.sh`) thins everything under
>   `Contents/Frameworks` to arm64 and re-signs bottom-up — the strict CI arm64-only gate holds.
> - **Gated updater**: `SPUStandardUpdaterController` + "Check for Updates…" (app menu) stay
>   inert until `SUFeedURL` *and* a real `SUPublicEDKey` are configured
>   (`UpdaterConfiguration` in Core, unit-tested). Installer-launcher service ON, downloader
>   service OFF (we hold `network.client`), both mach-lookup exceptions in the entitlements.
> - **Entitlements audit** (`Scripts/entitlements-audit.sh`): deny-by-default allowlist (no
>   library-validation bypass / JIT / get-task-allow / stray exceptions), static mode wired into
>   every CI run, `--app` mode (effective entitlements + hardened-runtime flag on every Mach-O)
>   wired into the release pipeline.
> - **Acknowledgements**: Help ▸ Acknowledgements window — GPL-2.0 text + corresponding-source
>   offer, verbatim UnRAR paragraph + full license, libarchive BSD, Sparkle MIT. License copies
>   are test-gated byte-for-byte against their canonical files (`ModernPARUITests`).
> - **Release pipeline** (`Scripts/release.sh`): build → bottom-up sign (never `--deep`;
>   entitlements expanded — codesign doesn't substitute `$(PRODUCT_BUNDLE_IDENTIFIER)`) →
>   notarize + staple the **.app** → DMG (with /Applications symlink) → notarize + staple the
>   **DMG** → `stapler validate` + `spctl` both. `--adhoc` smoke mode verified end-to-end.
> - **Tag-gated release CI** (`.github/workflows/release.yml`): on `v*` tags only — tests →
>   temp-keychain cert import → release.sh with ASC API key → `generate_appcast`
>   (EdDSA-signed) → GitHub Release with DMG + appcast. Required secrets documented in the
>   workflow header. Regular CI is unchanged.
>
> The 48-agent adversarial review (5 lenses, 2-refuter verification + tiebreakers) confirmed
> 13 distinct findings — 1 high (the UnRAR attribution paragraph was NOT yet in source
> comments, which the license and THIRD-PARTY-LICENSES.md both require), plus release-gate
> holes (mach-lookup names audited by suffix only; unsigned DMG flunking the offline spctl
> verdict; no ship-gate on a placeholder SUPublicEDKey; no appcast-signature check; no
> build-number monotonicity guard; prerelease tags hijacking the live feed) and tooling bugs
> (sign-update.sh dropping generate_keys args; temp-file leaks) — all fixed with the audit/
> test gates extended to cover them. One more "confirmed" finding (ad-hoc + hardened runtime
> supposedly failing library validation on the embedded Sparkle) was refuted by direct
> launch test. 342 tests green.
>
> **Local credentials COMPLETE (2026-06-12): the first notarized, stapled DMG exists.**
> Developer ID Application cert created (Xcode ▸ Manage Certificates; note: Saddle never
> needed one locally — it ships via Xcode Organizer's cloud-managed Developer ID signing,
> whose key never enters the keychain). notarytool keychain profile "ModernPAR-Notary"
> stored + validated; Sparkle EdDSA keypair generated (private key in Sean's login
> keychain; public key committed in Info.plist — the updater gate is now LIVE). Full
> `Scripts/release.sh` run: app notarization Accepted, DMG notarization Accepted, both
> stapled, `spctl` says "accepted — source=Notarized Developer ID" for both.
>
> **v0.1.0 SHIPPED (2026-06-12).** All six CI secrets set (validated against Apple before
> storing); tag pushed; the release workflow ran green end-to-end on the first try: tests →
> temp-keychain cert import → sign → notarize (app + DMG, both Accepted) → staple both →
> EdDSA-signed appcast → GitHub Release. The published DMG re-downloaded and re-verified:
> stapler validate OK and `spctl` "accepted — source=Notarized Developer ID" for the DMG
> *and* the inner app; the live feed at `releases/latest/download/appcast.xml` serves a
> signed enclosure (sparkle:version 19 / 0.1.0, min macOS 14.0, arm64).
>
> **PHASE 9 COMPLETE (2026-06-13).** v0.1.1 cut (build 21; a CHANGELOG-only smoke change)
> and the Sparkle end-to-end update test PASSED: the shipped, notarized v0.1.0 (build 19),
> installed from the GitHub Release, auto-detected 0.1.1 on the live feed
> (`releases/latest/download/appcast.xml`), downloaded the EdDSA-signed DMG, verified the
> signature, and installed + relaunched in place — `/Applications/ModernPAR.app` flipped
> 0.1.0/19 → 0.1.1/21, still `stapler validate` OK and spctl "Notarized Developer ID". The
> final exit criterion (Sparkle update applies end-to-end on a sandboxed build) is met, so
> all Phase 9 exit criteria now pass. Optional leftover: a literal clean-Mac offline
> Gatekeeper check (already verified locally on the published artifact). Dev note: Debug
> builds carry
> CURRENT_PROJECT_VERSION=1, so a dev build will see the feed's build 19 as an update —
> consider gating the updater start behind `#if !DEBUG` if the nag bothers development.
> Deferred niceties: bundling `par2helper` as a fallback-build variant; legal review before
> the first public release (top item: GPL app + UnRAR-licensed component coexistence).

**Goal.** A notarized, stapled, auto-updating DMG users can install and keep for years.

**Tasks.**
- Signing: Developer ID Application cert, Hardened Runtime, `--timestamp`, **bottom-up, never `--deep`**. Engine is statically linked, so the only nested signables are Sparkle.framework + its XPC services — plus `Contents/Helpers/par2` in fallback-engine builds (sign it bottom-up before the app). Verify with `codesign -dv`, re-sign only if needed.
- Entitlements final check: sandbox on; user-selected RW; app-scope bookmarks; network.client; Sparkle's two `mach-lookup` temporary exceptions. **No** `disable-library-validation`, **no** JIT, **no** `get-task-allow` in release.
- notarytool: keychain profile (local) / App Store Connect API key (CI); `submit --wait`; `stapler staple` the DMG **and** the inner `.app`; on failure read `notarytool log`.
- Sparkle 2 via SwiftPM, EdDSA-signed appcast, `SUEnableInstallerLauncherService=YES`, downloader service **OFF** (we have network.client), `SUPublicEDKey` + `SUFeedURL` in Info.plist, programmatic `SPUStandardUpdaterController` + "Check for Updates…" menu command.
- Compliance artifacts in the bundle: GPL-2.0-or-later text + corresponding-source offer (turbo sources + build scripts), **verbatim UnRAR license paragraph**, acknowledgements view.
- Release CI: sign + notarize only on tagged builds.

**Demoable milestone.** Download the DMG on a clean Mac, drag to Applications, launch (Gatekeeper passes offline), and Sparkle offers a newer test version.

**Exit criteria.**
- `xcrun stapler validate` passes on DMG and `.app`; `codesign --verify --deep --strict` clean; runtime flag present, no `get-task-allow`.
- Sparkle update applies end-to-end on a sandboxed build.
- arm64-only; all compliance texts present; corresponding source published (we are GPL).

---

## Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|:----------:|:------:|------------|
| **C++ interop / autotools vendoring** — turbo is autotools (no CMake); SPM treats headers as C; `.Cxx` mode propagates; STL/exceptions cross the boundary | High | High | **Time-boxed spike in Phase 2 before committing.** Hand-write + commit `arm64-apple` `config.h`, pin tag v1.4.0, clean umbrella header. C-style shim catches all exceptions, exposes only PODs/`const char*`/function pointers. `Par2Cxx` hides its C++ behind an `extern "C"` umbrella consumed as a plain C module, so `Par2Kit` needs no `.Cxx` interop — the only `.Cxx` surface is `ArchiveKit` (Phase 4; ARCHITECTURE.md §2). **Hard fallback: `HelperProcessEngine` subprocess** behind the same protocol if the spike fails. |
| **RAR licensing entanglement** — UnRAR is GPL-incompatible + non-OSI field-of-use restriction; static-linking GPL turbo + UnRAR in one binary is legally ambiguous | Medium | High | Keep UnRAR in its **own component/translation units**, never combined into the par2 link unit; document as a separately-licensed part. Build from **source (unrarsrc 7.2.4)**, not the binary EULA. Ship the verbatim license paragraph. **Get legal review before release.** If strict OSI-only is ever required, demote UnRAR to an optional dynamic component or fall back to LGPL XADMaster (loses RAR5/password fidelity). |
| **Sandbox vs. file access** — opening a `.par2` grants only that file, but verify/repair writes the whole folder; in-place repair + multi-volume extract need broad write scope | Medium | High | One-time "grant this folder" powerbox flow; **app-scoped security-scoped bookmarks** persisted in recents/`SessionRoute`; bracket every op with `start/stop` access. Engine is **in-process** (static link), so no helper-spawn sandbox exception needed — this is *why* embedding beats a forked helper for sandboxing. Convert all dropped/dock URLs to bookmark `Data` immediately. |
| **RS correctness / cross-tool compat (MultiPar/par2cmdline)** — wrong slice ordering or matrix → silently incompatible recovery data | Low (we wrap turbo) | Critical | **Do not reimplement the matrix.** Wrapping turbo inherits byte-for-byte interop for free; the legacy Vandermonde matrix must be preserved (fixing it = par3, incompatible). Golden-set cross-tool tests in CI (create here → verify/repair in par2cmdline + turbo + MultiPar, and vice-versa) gate every engine change. |
| **Performance at 32k files** — SwiftUI `List`/`Table` lazy-loading still imperfect at PAR2's max scale; over-threaded verify degrades on slow/network disks | Medium | Medium | `Table` + stable ids + `.equatable()` rows + **event coalescing** (batch per runloop tick). Prototype at full 32k scale **early** (Phase 3). **Budgeted `NSTableView`/`NSViewRepresentable` escape hatch** if 60fps can't hold. Tie concurrency to op type (verify = low parallelism, create/repair = scale to cores) with a user core cap via turbo `-t`. |
| **Engine crash takes down the GUI** (embedded in-process) | Low | Medium | Shim returns error codes, never lets C++ exceptions escape. If crashes prove common in the field, the `HelperProcessEngine` fallback gives process isolation; XPC (doc-04 option c) is the documented next step — deliberately deferred past v1. |
| **GPL forces open-source** — static-linking turbo makes ModernPAR a GPL derivative | Certain (accepted) | — | **Decided:** ModernPAR ships open source under a GPL-2.0-or-later-compatible license with a corresponding-source offer. This is the price of in-process turbo and is accepted up front (Decision 1). No Mac App Store. |

---

## Testing strategy

Four layers, all runnable in CI on `macos-26` (`swift test` headless + `xcodebuild test`):

1. **Golden PAR2 sets (cross-tool compatibility) — the most important suite.**
   - Maintain a fixture corpus of small recovery sets generated by **par2cmdline, par2cmdline-turbo, MultiPar/par2j, and ParPar**.
   - **Read test:** ModernPAR's Phase-1 parser extracts identical metadata (set id, file ids, block size, redundancy, vol naming) from each.
   - **Verify/repair test:** `EmbeddedEngine` verifies and repairs each foreign set.
   - **Create-interop test (Phase 6):** sets ModernPAR creates must verify/repair clean in all the foreign tools. This is the only real guard against silent matrix/ordering incompatibility.

2. **Corrupted-file fixtures.**
   - Per golden set, generate variants: single-block flip, missing data file, **renamed** data file (tests the sliding-CRC matcher), truncated file, garbage prepended (unaligned blocks), a corrupt par2 packet (must be skipped), and an *insufficient-recovery* case (asserts the "need N more blocks" math).
   - RAR fixtures: single + multi-volume, RAR3 + RAR5, password-protected, deliberately-corrupt; zip fixtures: ZipCrypto + WinZip-AES + Zip64.
   - Assert the resulting `FileStatus`/`DocStatus` matches the expected MacPAR vocabulary per case.

3. **Engine-boundary unit tests (the C shim).**
   - In the `PARKit` SwiftPM test target, exercise the C ABI directly with golden + malformed inputs; assert **no C++ exception ever escapes** (every libpar2 throw becomes an error code).
   - Test cancellation: the progress callback returning `false` stops the C++ within bounded time.
   - Run `EmbeddedEngine` and `HelperProcessEngine` against the **same** protocol-level suite to prove swappability and catch CLI-parser drift in the fallback.

4. **UI smoke tests (`xcodebuild test`, XCUITest).**
   - Open-and-repair from Finder double-click, dock-drop, and Cmd-O; assert status line goes green and per-file icons update.
   - Cmd-. cancels a long op and leaves a defined state; Quit is blocked while busy.
   - Sandbox round-trip: grant a folder, relaunch, reopen from recents resolves the app-scoped bookmark without re-prompting.
   - **Scale test:** synthesize a 32k-row set and assert the file list stays responsive (the trigger for the `NSTableView` fallback decision).

**CI gating.** Layers 1–3 run on every PR (fast, headless). Layer 4 + sign/notarize run on tags. The cross-tool golden suite (layer 1) is a **required** check on any change touching `Par2Cxx`, the shim, or `EmbeddedEngine`.
