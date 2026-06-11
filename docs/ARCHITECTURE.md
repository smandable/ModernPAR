# ModernPAR — Architecture

> Native arm64 macOS rewrite of MacPAR deLuxe. Swift 6.3 / SwiftUI, Xcode 26, macOS 26.
> This document is the **decided** architecture. Where the research left options open, this
> picks one and says why. Citations point at `docs/research/00..08`; the binding sources are
> `07-verification.md`, which adversarially checked the four highest-risk claims, and
> `08-mas-and-engine-alternatives.md`, which settles the Store/licensing posture.

---

## 0. The one decision that drives everything: ModernPAR is GPL

**Owner decision (2026-06-09): ModernPAR ships as open source under GPL-2.0-or-later.** The
repo-root `COPYING` is the project license. This was the last open licensing question (earlier
drafts of this section assumed a permissive posture), and it settles the engine-integration
tension between docs 03 and 04 in favor of ROADMAP Decision 1/2.

par2cmdline-turbo is **GPL-2.0-or-later** (07 Claim 1: COPYING says v2, but every source header
and `configure.ac` grant "or, at your option, any later version" — so the accurate SPDX id is
`GPL-2.0-or-later`, not bare GPLv2). The FSF is unambiguous that **in-process static or dynamic
linking makes the whole combined binary GPL** (07 Claim 1, gnu.org GPL FAQ). Because ModernPAR is
itself GPL-2.0-or-later, that consequence is *accepted, not avoided*:

> **The PAR2 engine is embedded in-process — turbo vendored as a C++ SwiftPM target behind a
> C-style shim (doc 04 option (a), ROADMAP Decision 2 — primary) — with `HelperProcessEngine`,
> a bundled-CLI subprocess driven over `Foundation.Process`, built behind the same `PAR2Engine`
> protocol as the designed-in fallback.**

Two things keep the fallback real, not theoretical:

- **Engineering risk.** The embed's autotools/mixed-header vendoring of turbo's `src/` into SPM is
  the single most likely build failure point (07 Claim 4). Phase 2 therefore opens with a
  mandatory, time-boxed spike; if it does not land in its box, the helper ships for MVP and
  embedding is revisited post-ship (ROADMAP Phase 2).
- **License firewall on standby.** If the project ever needs a permissive or closed-source build,
  the subprocess boundary is the only legal shape ("pipes, sockets and command-line arguments …
  normally are separate programs" — GPL FAQ). The protocol seam makes that a build-configuration
  change, not a rewrite.

The RAR engine is also linked **in-process** — see §1.2 — but UnRAR's license is GPL-incompatible,
so it is kept in its own component/translation units as a separately-licensed part, never combined
into the GPL engine's link unit (§1.4; ROADMAP risk table).

**Distribution is Developer-ID / notarized, outside the Mac App Store** — for reasons now recorded
precisely in doc 08 §2: Apple's EULA/Usage Rules are GPLv2 §6 "further restrictions" that attach to
**any** GPL binary in the Store package *regardless of process or link boundary* (FSF — GNU Go and
VLC precedents), and a sandboxed MAS app cannot spawn a bundled CLI at all (Guideline 2.4.5).
GPL-or-later code *is* MAS-shippable when the copyright holder grants a GPLv3 §7 App-Store
exception — but we are not turbo's copyright holder, so we cannot obtain one. The UnRAR
field-of-use clause is a softer, *chosen* blocker (RAR extraction is provably MAS-shippable — Keka
ships RARLAB UnRAR on MAS today). The only road to MAS is a clean-room Swift PAR2 engine; that is
researched (08 §4–§5) and **not currently planned** (owner decision 2026-06-09: Option A,
Developer-ID only). No engineering effort is spent on MAS packaging.

> Action item carried from 07: obtain a real legal review before release. This document records
> engineering decisions, not legal advice.

---

## 1. Engine strategy (DECIDED)

### 1.1 PAR2 — embedded turbo behind a C shim (primary), bundled helper (fallback)

| Decision | Value |
|---|---|
| Engine | **par2cmdline-turbo** (animetosho), pinned to **v1.4.0** |
| License | GPL-2.0-or-later (07 Claim 1) — same license family as ModernPAR itself (§0) |
| Integration (primary) | **Embedded in-process**: vendored turbo `src/` in a C++ SwiftPM target (`Par2Cxx`) + a hand-written, committed `arm64-apple` `config.h`, behind `Par2Shim.{h,cpp}` — an `extern "C"` umbrella that catches **every** C++ exception (libpar2 throws) and exposes only POD structs, `const char*`, and function-pointer progress callbacks. Swift consumes the shim as a plain **C** module, so no `.Cxx` interop mode propagates (§2). |
| Integration (fallback) | **Bundled CLI helper** at `Contents/Helpers/par2`, invoked via `Foundation.Process`, stdout/stderr parsed into events by a version-pinned, snapshot-tested parser. Built and protocol-tested anyway; ships for MVP if the Phase-2 embed spike fails, and is the license firewall for any future permissive/closed build (§0). |
| Build | turbo is **autotools, not CMake** (07 Claim 1 refutes the CMake assumption). Embed = vendored source + committed `config.h` (no configure step at build time). Fallback helper = build from source in CI (`./automake.sh && ./configure && make`, **C++14** compiler required) so we control the signable, notarizable artifact; prebuilt `macos-arm64` release zips acceptable as a stopgap. |
| CLI contract (fallback) | `par2 c|v|r [options] <par2file> [files]` with `-b -s -r -c -f -u -l -n -m -t` — the exact contract MacPAR deLuxe's par2SL already used (01 §"par2SL"; 03), so option mapping is a near-direct port. |
| Threads | turbo's `-t<n>` / the shim's thread parameter implements the "limit CPU cores" preference (replaces par2SL's GCD parallelism). |

When the fallback helper is bundled it lives at `ModernPAR.app/Contents/Helpers/par2`, code-signed,
hardened-runtime, and stapled as part of the app's notarization. ModernPAR's GPL compliance is
straightforward because the app itself is GPL-2.0-or-later: the corresponding source for the whole
work (app + vendored turbo + build scripts) is published, turbo's notice ships verbatim in the
About panel, and `COPYING` ships in the bundle (§0; doc 06 §3c).

**Why embed now (doc 04 option a restored):** the §0 license decision removes the only legal
objection; embedding buys native progress/cancellation callbacks instead of fragile stdout
parsing, one signed binary, and a simpler sandbox story. The helper remains the engineering-risk
hedge — see §0. **Why not XPC (option c):** unjustified complexity for a single-user utility
(04; 07 Claim 4 — keep skipping XPC for v1).

### 1.2 PAR1 — native Swift, no binary

MacPAR deLuxe's `par` helper is Intel-only and cannot be reused natively. PAR1 is GF(2⁸)
Reed-Solomon over ≤255 files — small and fully specified (03). We **reimplement PAR1
verify/recover in pure Swift**, using gopar's BSD-licensed PAR1 code as a clean reference. This
removes the last Intel-only binary, carries no GPL, and is simpler than porting `par`. PAR1
verify/repair is **v1** (parity), not MVP (01); PAR1 *create* is v1 if at all (the format is
obsolete: 255-file cap, Usenet-era).

### 1.3 Native read-only PAR2/PAR1 parser (always Swift, in-process)

The **document model and file-status UI are powered by a pure-Swift, read-only parser**, not by
shelling out. Reading PAR2/PAR1 has no compatibility trap — only *writing/repair* does (03). The
parser does a packet scan, validates each packet's MD5 header, decodes Main / FileDescription /
IFSC, derives Recovery-Set ID and File IDs, reads slice size + redundancy, interprets
`vol###+NN.par2` naming, and computes "need N more blocks" math. This lets us paint the
status grid the instant a set is opened, before any verify operation runs, and gives us the
QuickCheck-then-full-verify progression (02).

> The Swift parser is **the model**; the turbo engine (embedded or helper) is **the actuator**.
> The parser never depends on the engine, and engine output is reconciled against the parser's model.

### 1.4 Archive extraction — RARLAB UnRAR (linked) + libarchive (zip)

| Format | Engine | License | Integration |
|---|---|---|---|
| **RAR** 2/3/5, multi-vol, SFX, password | **RARLAB UnRAR** from source tarball **`unrarsrc` 7.2.4** | Source license: free for extraction, forbids only *creating* a RAR-compatible archiver (07 Claim 2 — confirmed) | **Linked in-process** as a static lib via a C/Obj-C++ shim (`RAROpenArchiveEx`/`RARProcessFileW`/`RARSetPassword`/`RARSetCallback`). Do **not** spawn a CLI. |
| **zip** (+ optional 7z read) | macOS **libarchive** 3.7.x | BSD-2-Clause | Linked via the SDK `libarchive.2.tbd` stub + vendored headers; streaming C-API shim. |

UnRAR's licensing care point: the UnRAR **source** license has no copyleft — it explicitly permits
use "in any software … free of charge" and is satisfied by reproducing the license text in About +
keeping source comments (07 Claim 2) — but it is **GPL-incompatible** (non-OSI field-of-use
restriction). Since ModernPAR itself is GPL (§0), UnRAR must be kept in its **own
component/translation units**, documented as a separately-licensed part, and never combined into
the GPL par2 engine's link unit. This coexistence is the top item for the pre-release legal review
(§10 item 10; ROADMAP risk table).

Hard limits the research nails down (07 Claim 2):
- **Never route RAR through libarchive/XADMaster/p7zip** for the password or RAR5 path —
  libarchive provably returns `ARCHIVE_FATAL` "Encryption is not supported" on encrypted RAR and
  ignores Reed-Solomon recovery records. Reserve libarchive for **zip/7z only**.
- **Drop creating .rar** (legally forbidden; never a MacPAR feature) and **drop Stuffit/.sit**.
- Build UnRAR from the **source tarball** (permissive), not the prebuilt `unrar` binary (more
  restrictive EULA). And it is **7.2.4**, not the 7.13 typo in doc 05 §1.
- Note `unrar` source is **non-OSI** (field-of-use restricted). If ModernPAR is ever required to
  be strictly OSI-open with zero non-free deps, UnRAR becomes a conflict and must be split out as
  an optional dynamically-replaceable component (or fall back to LGPL XADMaster at the cost of
  RAR5/password fidelity).

### 1.5 The single engine seam

The embedded PAR2 engine (primary), the helper-process fallback, and PAR1 native all conform to
one protocol (`PAR2Engine`, §6). This is the swappability point: it is what makes the
embed-vs-helper choice a Phase-2 spike outcome rather than an architectural fork, and a future
PAR3 (BLAKE3, still alpha — 03) backend — or a clean-room Swift PAR2 engine (08 §7) — slots in
behind it without touching the UI.

---

## 2. Module / target graph

We use the **Option C** layout from doc 06: an Xcode `.xcodeproj` app target plus a **local SwiftPM
package (`PARKit`)** for the engine wrappers and core logic. SPM-only cannot produce a proper `.app`
(Info.plist, document types, entitlements, asset catalog, Sparkle); dropping C/C++ into the app
target directly hurts testability.

```
                         ModernPAR.xcodeproj  (the .app target)
                         ├─ AppDelegateAdaptor (AppKit bridge: dock-drop / open-with)
                         ├─ Sparkle 2 (EdDSA appcast, mach-lookup entitlements)
                         ├─ Bundled helper:  Contents/Helpers/par2  (fallback-engine builds only)
                         └─ depends on ▶ Packages/PARKit — links ModernPARUI and injects the
                                         engine concretes behind ModernPARCore's protocols

   Packages/PARKit  (local SwiftPM package, Swift 6 language mode) — arrows point at dependencies

     ModernPARUI (SwiftUI views, scenes, commands)
       └─ depends on ▶ ModernPARCore

     ModernPARCore (pure-Swift, UI-free, C/C++-free — the hub; depends on no other target)
       ├─ Domain models: ParSet, FileEntry, FileStatus, OperationSession
       ├─ Native Swift PAR2/PAR1 READ-ONLY parser  (§1.3)
       ├─ Native Swift PAR1 verify/recover engine  (§1.2)
       ├─ Engine protocols: PAR2Engine, ArchiveExtractor   ◀── the concretes below conform;
       ├─ Security-scoped bookmark service                     the app target injects them, so
       └─ Settings / Recents store                             Core/UI never import an engine module

     Par2Kit (Swift) — depends on ▶ ModernPARCore
       ├─ EmbeddedEngine : PAR2Engine       (primary, Phase 2)
       │    bridges Par2Shim callbacks → AsyncStream<EngineEvent>
       ├─ HelperProcessEngine : PAR2Engine  (fallback)
       │    drives Contents/Helpers/par2 via Foundation.Process
       │    + a snapshot-tested stdout/stderr parser (§4.3)
       └─ depends on ▶ Par2Cxx (C++ target, Phase 2)
            vendors turbo v1.4.0 src/ + committed config.h; Par2Shim.{h,cpp} is an
            extern "C" umbrella — catches all C++ exceptions, imported by Swift as
            a plain C module (so Par2Kit needs no .Cxx interop)

     ArchiveKit (Swift, NO C++ interop — as built in Phase 4) — depends on ▶ ModernPARCore
       ├─ RARExtractor : ArchiveExtractor  → CUnrar
       ├─ ZipExtractor : ArchiveExtractor  → libarchive (Phase 5)
       ├─ depends on ▶ CUnrar (C++ target behind an extern "C" umbrella, like Par2Cxx)
       │    vendors unrarsrc 7.2.4 (3 local patches — vendor/VENDORED.txt);
       │    unrarshim.{h,cpp} catches all C++ exceptions, exposes
       │    POD + const char* + callback fn-ptrs only; EXTRACTION/LISTING ONLY
       └─ depends on ▶ CLibArchive (system target → libarchive.2.tbd + headers; Phase 5)
```

### Target responsibilities

| Target | Language | Responsibility | C++ interop? |
|---|---|---|---|
| **ModernPARApp** (xcodeproj) | Swift/SwiftUI | `.app` shell: scenes, Info.plist, entitlements, asset catalog, Sparkle, `AppDelegateAdaptor`; bundles the `par2` helper in fallback-engine builds. | No (depends only on pure-Swift `ModernPARUI`) |
| **ModernPARUI** | Swift/SwiftUI | All views, scene graph, menu commands, Settings. | **No** |
| **ModernPARCore** | Swift | Models, state machine, native parser, native PAR1, protocols, bookmark + settings services. | **No** |
| **Par2Kit** | Swift | `EmbeddedEngine` (primary — drives `Par2Cxx` via the C shim) + `HelperProcessEngine` (fallback — runs the bundled `par2`, parses output) → `EngineEvent`. Consumes `Par2Cxx` as a plain C module. | **No** (`Par2Cxx`'s umbrella header is `extern "C"`) |
| **Par2Cxx** *(Phase 2)* | C++ | Vendors par2cmdline-turbo v1.4.0 `src/` + committed `arm64-apple` `config.h`; `Par2Shim.{h,cpp}` catches **all** C++ exceptions, exposes POD/`const char*`/fn-ptr C ABI only. | (C++ contained here) |
| **ArchiveKit** *(Phase 4)* | Swift | `RARExtractor` (`ZipExtractor` in Phase 5); password/volume/destination/placement logic in Swift around the shims. | **No** (`CUnrar`'s umbrella header is `extern "C"`) |
| **CUnrar** *(Phase 4)* | C++ | Vendors `unrarsrc` 7.2.4 (3 local patches, `vendor/VENDORED.txt`); `unrarshim.{h,cpp}` catches all C++ exceptions, exposes a C-only extraction/listing API (no creation — UnRAR license). | (C++ contained here) |
| **CLibArchive** | C (systemLibrary) | Module map over `libarchive.2.tbd` + vendored headers. | n/a |

**Quarantine rule (07 Claim 4) — superseded by a stricter as-built outcome (Phase 4):** the
planned mitigation assumed ArchiveKit would need `.interoperabilityMode(.Cxx)` (whose propagation
to dependents cannot be hidden — Swift issue #66156). As built, **no target in the project uses
C++ interop at all**: `CUnrar` (like `Par2Cxx`) hides its C++ behind an `extern "C"` umbrella
header (`unrarshim.h`), so Swift imports it as a plain C module and ArchiveKit carries no interop
flag to propagate. The **injection seam stays load-bearing for module hygiene**: `ModernPARCore`
and `ModernPARUI` never import an engine module — `ArchiveKit` is consumed only through the
`ArchiveExtractor` protocol whose concretes are injected from the app target, keeping engine and
license boundaries (GPL turbo vs. UnRAR-licensed CUnrar) visible in the dependency graph.

---

## 3. Domain model

A "document" in ModernPAR is **not an editable file**. It is a long-running, **folder-scoped
session** (04 §1; 07 Claim 3). We model three things: the immutable *parsed* description of a set,
the *live* per-file status, and the *operation* in flight.

### 3.1 The set / working folder

```swift
/// Identifies a window/session. Codable+Hashable so WindowGroup(for:) restores it. (07 Claim 3)
public struct SessionRoute: Codable, Hashable, Sendable {
    public enum Mode: Codable, Hashable, Sendable {
        case verifyRepair          // open an existing PAR set, verify → repair
        case createSet             // author a new set in a folder
        case extractArchive        // unrar / unzip
    }
    public var mode: Mode
    /// Security-scoped bookmark for the working FOLDER (the set lives alongside its data files).
    public var folderBookmark: Data
    /// Bookmark for the specific .par2 / .par / .rar the user opened, if any.
    public var anchorBookmark: Data?
}
```

```swift
/// Immutable, parser-derived description of a PAR set. Produced by the native read-only parser.
public struct ParSet: Identifiable, Sendable {
    public let id: SetID                 // PAR2 Recovery-Set ID (MD5 of Main packet body), or synthetic for PAR1
    public let kind: ParKind             // .par1 / .par2
    public let sliceSizeBytes: UInt64    // PAR2 slice size (multiple of 4), 0 for PAR1
    public let sourceBlockCount: Int     // ≤ 32768 for PAR2 (GF(2^16) limit, 03)
    public let recoveryBlocksAvailable: Int
    public let files: [FileEntry]
    public let recoveryVolumes: [RecoveryVolume]   // vol###+NN.par2 inventory
}

public struct RecoveryVolume: Sendable {
    public let url: URL
    public let firstExponent: Int        // ### in vol###+NN
    public let blockCount: Int           // NN
}
```

### 3.2 File-status state machine (maps the original's icons)

The original's `FileStatus0..10` (01 §2.2) collapse to a Swift enum that preserves the
**recoverable / non-recoverable distinction** and the four status icons. The crucial invariant —
*"remember files already OK and skip them on retry"* (01 §"Repair again"; 02) — is encoded as the
`.ok` and `.recovered` terminal states being sticky across a re-run.

```swift
public enum FileStatus: Sendable, Equatable {
    case pending                 // FileStatus0/16  – queued, not yet checked
    case checking                //                 – being hashed/matched now
    case ok                      // FileStatus1     – verified OK            → no icon / checkmark
    case recoverableMissing      // FileStatus5     – missing, recoverable   → FileRecoverableIcon
    case recoverableCorrupt      // FileStatus7     – bad checksum, recoverable → FileRecoverableIcon
    case unrecoverableMissing    // FileStatus6     – missing, cannot recover → FileErrorIcon
    case unrecoverableCorrupt    // FileStatus8     – bad checksum, cannot recover → FileErrorIcon
    case recovered               // FileStatus9     – repaired this run       → OK
    case renamed(from: String)   // contributes to DocStatus8/14 "one or more files were renamed"
    case notInSet                // FileStatus10    – present but not part of parity → FileNotInVolumeSetIcon
    case possibleError           // FilePossibleErrorIcon – "might be recoverable"

    var icon: StatusIcon {
        switch self {
        case .ok, .recovered:                               return .ok
        case .recoverableMissing, .recoverableCorrupt,
             .possibleError:                                return .recoverable     // FileRecoverableIcon.icns
        case .unrecoverableMissing, .unrecoverableCorrupt:  return .error           // FileErrorIcon.icns
        case .notInSet:                                     return .notInVolumeSet  // FileNotInVolumeSetIcon.icns
        case .pending, .checking, .renamed:                 return .neutral
        }
    }
    var isRecoverable: Bool { /* true for the .recoverable* + .possibleError cases */ }
    var isTerminalOK: Bool { self == .ok || self == .recovered }   // → skip on retry
}
```

```swift
/// One row in the file table. Equatable + stable id so the Table can diff cheaply at 32k rows.
public struct FileEntry: Identifiable, Equatable, Sendable {
    public let id: FileID            // PAR2 File ID = MD5(MD5-16k ‖ length ‖ name); depends on NAME (03)
    public var name: String
    public var sizeBytes: UInt64
    public var status: FileStatus
    public var blocksNeeded: Int     // for the "need N more blocks" report
}
```

```swift
/// Document-level status line, colored green on OK end-states / red otherwise (01 §2.3, §7.3).
public enum DocStatus: Sendable {
    case waitingToStart                 // DocStatus16
    case checking                       // DocStatus1/2
    case allFilesOK                     // DocStatus3   (green)
    case repairing                      // DocStatus5
    case restoredSuccessfully           // DocStatus7   (green)
    case restoredWithRenames            // DocStatus8   (green)
    case needMoreRecovery(blocks: Int)  // DocStatus11/12 + "need N more blocks" (red, retryable)
    case onlyNonRecoverableMissing      // DocStatus13/14 (red)
    case notValid                       // DocStatus9   (red)
    case internalError                  // DocStatus15  (red)

    var isGreenEndState: Bool { /* allFilesOK, restoredSuccessfully, restoredWithRenames */ }
}
```

MVP reproduces file statuses 1,2,4,5,6 and doc statuses 1,2,3,5,7,11,12,16; the rest are v1 (01).

### 3.3 Create-set configuration

The create surface is **v1**, not MVP (01 §"MVP/v1"). It exposes only the knobs MultiPar/MacPAR
surface, mapping straight to turbo flags (01 §5.3, 03):

```swift
public struct CreateConfig: Sendable {
    public enum Redundancy: Sendable {
        case percent(Int)            // -r<n>, 1...100  (validate: WrongPAR2RedundancyErr)
        case blockCount(Int)         // -c<n>, mutually exclusive with -r
    }
    public enum BlockSize: Sendable {
        case automatic               // computed from combined set size
        case kilobytes(Int)          // -s<bytes>, 1...419430 KB (WrongPAR2BlockSizeErr)
    }
    public var redundancy: Redundancy = .percent(10)
    public var blockSize: BlockSize = .automatic
    public var limitToLargestFile: Bool = false   // -l / -u uniform vs limited vol sizing
    public var threadCap: Int? = nil              // -t
    // Enforced: PAR2 ≤ 32768 files (TooManyFilesForPar2Err); PAR1 ≤ 255.
}
```

---

## 4. Concurrency model

Built on **Swift Concurrency (async/await, actors)**, not GCD (02 rec). Tie parallelism to op type:
verify is IO-bound (low parallelism, respect a core cap because over-threading verify degrades on
slow/network disks); create/repair is CPU-bound (scale to cores via `-t`).

```
┌─────────────────────┐    EngineEvent stream    ┌────────────────────────┐
│  PAR2EngineActor     │ ───── AsyncStream ─────▶ │  OperationSession      │
│  (actor)             │                          │  @MainActor @Observable│
│  - launches Process  │                          │  - per window (@State) │
│  - reads stdout/err  │                          │  - applies COALESCED   │
│  - parses → events   │                          │    batches to model    │
│  - holds cancel hook │ ◀──── cancel() ───────── │  - drives the UI        │
└─────────────────────┘                          └────────────────────────┘
```

### 4.1 Streaming events

The engine emits a `Sendable` event enum; the embedded PAR2 engine, the helper-process fallback,
and the native PAR1 engine all produce the same stream, so the UI is engine-agnostic.

```swift
public enum EngineEvent: Sendable {
    case scanningStarted(totalFiles: Int)
    case fileStatusChanged(id: FileID, status: FileStatus)
    case overallProgress(fraction: Double)            // 0...1
    case logLine(String)                              // raw helper output → "Show par Output" pane
    case docStatusChanged(DocStatus)
    case finished(Result<OperationSummary, EngineError>)
}
```

### 4.2 Actors, detached work, cancellation

- An engine actor owns the in-flight work and bridges it into an `AsyncStream<EngineEvent>`. For the
  **embedded engine**, the blocking turbo call runs on a detached task and Par2Shim's C progress
  callbacks are yielded into the stream. For the **helper fallback**, the actor owns the in-flight
  `Process`; blocking reads run on a detached task and parsed lines are yielded.
- **Cancellation (Cmd-. / "Cancel Operation," 01 §2.4):** the `AsyncStream`'s `onTermination` and the
  session's `Task.cancel()` both stop the engine — embedded: an atomic flag makes the progress
  callback return `false` and turbo stops cooperatively; helper: the child `Process` is terminated
  (SIGTERM → SIGKILL escalation). For the native PAR1 engine, cancellation is checked cooperatively
  in the hashing loop. The original's "Cancel (Cmd-.)" affordance is preserved.
- `OperationSession` is `@MainActor @Observable`. It consumes the stream and applies updates. To avoid
  invalidating 32k rows per frame, events are **coalesced into ~60 ms / N-event batches** before being
  written to the model (04 §6; 07 Claim 3 — large-list perf is a real risk).

```swift
@MainActor @Observable
public final class OperationSession {
    public private(set) var set: ParSet?
    public private(set) var rows: [FileEntry] = []          // diffable, equatable rows
    public private(set) var docStatus: DocStatus = .waitingToStart
    public private(set) var progress: Double = 0
    public private(set) var log: [String] = []              // "Show par Output"

    private var task: Task<Void, Never>?

    public func start(_ route: SessionRoute, engine: any PAR2Engine) {
        task = Task { await consume(engine.run(route)) }     // AsyncStream<EngineEvent>
    }
    public func cancel() { task?.cancel() }                  // → onTermination kills the Process

    private func consume(_ stream: AsyncStream<EngineEvent>) async {
        var batch: [EngineEvent] = []
        for await event in stream {
            batch.append(event)
            if batch.count >= 256 { apply(batch); batch.removeAll(keepingCapacity: true) }
        }
        if !batch.isEmpty { apply(batch) }
    }
    private func apply(_ batch: [EngineEvent]) { /* fold into rows/progress/docStatus once */ }
}
```

### 4.3 Output parsing → status (the brittle part, designed for it)

The helper engine's `EngineEvent`s come from parsing turbo's stdout/stderr (04; 07 Claim 4 — CLI
parsing is "brittle … pin the helper version and snapshot-test the parser"). Mitigations baked in:

1. **Pin the helper to v1.4.0**; the parser is version-gated.
2. **Snapshot tests** of real turbo output (scan progress lines, "Repairing", per-file
   "damaged/missing/found at offset", "You need N more recovery blocks") drive the parser.
3. The **native read-only parser is the source of truth for the file list**; turbo output only
   *transitions* known rows' statuses. A line that doesn't parse degrades to a `.logLine` rather than
   corrupting the model.

---

## 5. File access & sandbox

App Sandbox is on (06). The engine writes recovered/extracted files **alongside the source files** in
the user's chosen folder, and auto-delete moves par files to Trash — so folder-scoped write access is
designed in from day one (01, 06).

### 5.1 Entitlements (06 §4c, verbatim)

```xml
<key>com.apple.security.app-sandbox</key>                          <true/>
<key>com.apple.security.files.user-selected.read-write</key>       <true/>
<key>com.apple.security.files.bookmarks.app-scope</key>            <true/>  <!-- persist folder access for Retry -->
<key>com.apple.security.network.client</key>                       <true/>  <!-- Sparkle -->
<!-- Sparkle's two mach-lookup temporary exceptions: -spks and -spki -->
```

No `disable-library-validation`, no JIT, no `get-task-allow`. Hardened Runtime on.

> Sandbox tension: the bundled **par2 helper** runs in the app's sandbox and inherits the
> security-scoped folder grant via the bookmark we resolve before launch. We pass it explicit file
> paths inside the granted folder. Post-processing rules that run **arbitrary scripts** (the
> original's Terminal-script action) are **[later]** and incompatible with the sandbox — replace
> with `NSUserUnixTask` or constrained built-in actions only (01, 02 risk).

### 5.2 Security-scoped bookmarks — the round-trip is mandatory

07 Claim 3 corrects doc 04 hard here:

- **fileImporter / folder picks** ARE security-scoped — use them and call
  `startAccessingSecurityScopedResource()`.
- **Dropped and dock-dropped URLs are NOT auto-scoped** (`startAccessing…` returns `false`).
  Therefore, for every URL arriving via `dropDestination` or dock-open, we **immediately convert to
  `bookmarkData(options: [.withSecurityScope])` and resolve it back** before any engine I/O. This
  round-trip (Quinn/DTS-endorsed) is exactly what the helper and RAR engine need anyway.

```swift
public enum ScopedAccess {
    /// Round-trips a possibly-unscoped URL (drop/dock) into a usable security-scoped bookmark.
    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    /// Resolve + begin access; caller balances with stopAccessing in a defer.
    public static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool, didStart: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale, url.startAccessingSecurityScopedResource())
    }
}
```

`SessionRoute.folderBookmark` persists this so **"Repair Again" (Cmd-R)** works across relaunches
(needs `files.bookmarks.app-scope`, 06).

### 5.3 Drag-drop & dock-open

- **Drop into the file list / window:** SwiftUI `dropDestination(for: URL.self)` → round-trip to
  bookmark (§5.2). If reliability bites (07 Claim 3 flags `NSItemProvider` friction), fall back to a
  `DropDelegate`.
- **Dock-drop / open-with (`.par2`/`.par`/`.rar`):** `onOpenURL` is the primary path, but the first
  dock drop is known-flaky (07 Claim 3), so an **`NSApplicationDelegateAdaptor`** implements
  `application(_:open:)` for robustness. **This must be tested in the built `.app` outside Xcode.**
  Any URL-scheme entry uses **custom schemes**, not universal links (07 Claim 3).

---

## 6. Engine boundary — concrete Swift

```swift
// ─── PAR2/PAR1 engine seam (ModernPARCore) ──────────────────────────────────────────
public protocol PAR2Engine: Sendable {
    /// Returns a cold AsyncStream; iterating it starts the operation. Cancel via the consuming Task.
    func run(_ route: SessionRoute) -> AsyncStream<EngineEvent>
}

/// PAR2 embedded in-process (primary, Phase 2): runs the blocking turbo call on Task.detached and
/// bridges Par2Shim's C progress callbacks into the stream. Cancellation: onTermination sets an
/// atomic flag; the callback returns false and turbo stops cooperatively (Par2Kit → Par2Cxx).
public actor EmbeddedEngine: PAR2Engine { /* par2_verify / par2_repair / par2_create via Par2Shim */ }

/// PAR2 via bundled CLI helper — pure Swift over a process boundary (Par2Kit).
/// The designed-in fallback, and the GPL license firewall for any future permissive/closed build.
public actor HelperProcessEngine: PAR2Engine {
    private let helperURL: URL                  // Contents/Helpers/par2
    private let parser: TurboOutputParser        // version-pinned, snapshot-tested (§4.3)

    public func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let proc = Process()
            proc.executableURL = helperURL
            proc.arguments = ArgumentBuilder.build(for: route)   // c|v|r + -b -s -r -c -t … (01, 03)
            let out = Pipe(); proc.standardOutput = out; proc.standardError = out
            continuation.onTermination = { _ in if proc.isRunning { proc.terminate() } }
            out.fileHandleForReading.readabilityHandler = { fh in
                for line in fh.lines() { parser.consume(line) { continuation.yield($0) } }
            }
            do { try proc.run() } catch { continuation.yield(.finished(.failure(.launch(error)))) }
            // … on terminationHandler: yield .finished(.success(summary)); continuation.finish()
        }
    }
}

/// PAR1 via native Swift RS over GF(2^8) — no binary, no GPL (ModernPARCore).
public actor NativePAR1Engine: PAR2Engine { /* parse .par + .Pnn, verify, Gaussian recover */ }

// ─── Archive extraction seam (ModernPARCore protocol; concretes in ArchiveKit) ──────
public protocol ArchiveExtractor: Sendable {
    func extract(_ archive: SessionRoute,
                 to destination: ExtractDestination,
                 password: PasswordProvider) -> AsyncStream<ExtractEvent>
}

/// "Prompt once, reuse" — the UI supplies cached/typed passwords on demand (02, 05).
public protocol PasswordProvider: Sendable {
    func password(forVolume name: String) async -> String?   // ← UCM_NEEDPASSWORDW callback
}

public enum ExtractDestination: Sendable {
    case besideArchive                       // default (chooseUnrarDestinationFolder)
    case ask                                 // prompt
    case fixed(bookmark: Data)
}
public enum ConflictPolicy: Sendable { case ask, overwrite, keepBoth, cancel }  // existingUnrarDestinationAction
```

`RARExtractor` (ArchiveKit → CUnrar) implements password prompt-once-and-reuse and multi-volume
continuation inside the `UCM_NEEDPASSWORDW` / `UCM_CHANGEVOLUMEW` callbacks (05; 07 Claim 2).
`ZipExtractor` wraps libarchive's streaming C API.

---

## 7. UI architecture

### 7.1 Scene graph — WindowGroup, NOT DocumentGroup (DECIDED)

07 Claim 3 confirms doc 04: a par2 "document" is a long-running folder session, and
`DocumentGroup`/`NSDocument`'s open/save/autosave/versioning fights it on every axis. We use a
custom `WindowGroup(for: SessionRoute.self)` + `Settings` scene, which gives one-window-per-set,
window reuse for equal routes, dock-drop, and **built-in Codable state restoration** — without
`NSDocument`. The cost (acknowledged): **"Open Recent" is hand-rolled** (a `RecentsStore` in
`ModernPARCore`), since we don't inherit `NSDocumentController`.

```swift
@main
struct ModernPARApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate   // dock-drop robustness
    @State private var model = AppModel()                                     // @Observable: settings, recents, engines

    var body: some Scene {
        WindowGroup(for: SessionRoute.self) { $route in
            SetWindow(route: route).environment(model)
        }
        .handlesExternalEvents(matching: ["modernpar"])      // custom URL scheme, not universal links

        Settings { SettingsView().environment(model) }       // Cmd-, auto-wired

        .commands {
            CommandGroup(after: .newItem) {
                Button("Open and Repair…")   { /* openWindow(.verifyRepair) */ }.keyboardShortcut("o")
                Button("Create PAR Set…")    { }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Unrar Archive…")     { }.keyboardShortcut("u")
            }
            CommandMenu("Operation") {
                Button("Repair Again")       { }.keyboardShortcut("r")
                Button("Cancel Operation")  { }.keyboardShortcut(".")     // Cmd-.
                Button("Select All Non-OK")  { }
            }
            CommandGroup(replacing: .appInfo) { CheckForUpdatesView(updater: model.updater) }  // Sparkle
        }
    }
}
```

### 7.2 Key views

| View | Role | Notes |
|---|---|---|
| `SetWindow` | One window per `SessionRoute`; owns the `@State OperationSession`. | |
| `FileTable` | `Table` of `FileEntry` rows: status icon, name, size, blocks-needed. | **Table at 32k-row scale is the top UI risk** (07 Claim 3, FB15645433). Use stable ids + `.equatable()` rows + event coalescing (§4.2). **Prototype at full scale early; budget an `NSViewRepresentable(NSTableView)` fallback** if it can't hold 60 fps. |
| `StatusBar` | Bottom status line, **green on OK end-state / red otherwise** (01 §7.3), + Cancel button. | |
| `ParOutputPane` | Collapsible "Show/Hide par Output" log of raw helper lines. | |
| `ExtractProgressView` | Unrar/unzip progress + password sheet (prompt once) + conflict-policy sheet. | |
| `EncodingSheet` | "Some file names contain special characters…" for non-UTF-8 legacy RAR (`PrefFilenameEncoding`). | **[v1]**, RAR5 is UTF-8 so default to UTF-8. |
| `SettingsView` | Six tabs (Basic/Par1/Par2/Unrar/Post-processing/Other) bound to defaults keys. | MVP: most-used toggles; full tabs are v1 (01). |

### 7.3 Menu commands (01 §menu map)

Open and Repair (Cmd-O), Create PAR Set (Shift-Cmd-S), Add Files (Cmd-F), Repair Again (Cmd-R),
Cancel Operation (Cmd-.), Unrar Archive (Cmd-U), Show/Hide par Output, Close All, Select All Non-OK
— all native SwiftUI `commands`/`CommandGroup`/`.keyboardShortcut`. No AppKit needed for menus.

---

## 8. Where AppKit bridging is unavoidable

Doc 04's "little/no AppKit bridging" framing is **inaccurate** (07 Claim 3). The architecture is
SwiftUI-first, but these are real, designed-in bridges:

1. **`NSApplicationDelegateAdaptor`** — for robust dock-drop / open-with handling (`application(_:open:)`),
   because the first dock drop is known-flaky with `onOpenURL` alone (§5.3; 07 Claim 3).
2. **Security-scoped bookmark round-trip** — Foundation `URL.bookmarkData`/`URL(resolvingBookmarkData:)`,
   mandatory for drop/dock URLs (§5.2; 07 Claim 3). (Foundation, not strictly AppKit, but it is the
   non-SwiftUI file-access plumbing the doc glossed over.)
3. **`NSTableView` via `NSViewRepresentable`** — the **escape hatch** if SwiftUI `Table` can't hold
   60 fps at 32k rows (§7.2; 07 Claim 3, FB15645433). Build the SwiftUI version first; keep this in
   reserve.
4. **`DropDelegate` + `NSItemProvider`** — fallback if `dropDestination(for: URL.self)` proves
   unreliable (§5.3; 07 Claim 3).
5. **C / Obj-C++ shims** for UnRAR (CUnrar) and the libarchive header bridge — required to cross into
   the C/C++ engines (§2).

**Explicitly NOT bridged** (07 Claim 3 corrections): folder selection uses
`fileImporter(allowedContentTypes: [.folder])`, **not** `NSOpenPanel` with `canChooseDirectories`;
recents/settings are hand-rolled, **not** `NSDocumentController`; menus/Settings/Table/toolbar/
UserNotifications are pure SwiftUI.

---

## 9. Scope (carried from 01 §"MVP/v1")

- **MVP (the Rosetta-retirement urgency):** open + auto-verify/repair a PAR2 set with the full status
  vocabulary; unrar `.rar`/`.rNN`/`.partNN.rar`; built-in zip post-process; Preferences shell with
  the most-used toggles; Cancel (Cmd-.) + progress.
- **v1 (parity):** native PAR1 verify/repair; Create (par2 + par1); full six-tab Preferences;
  password + encoding dialogs; Retry-recovery memory; Notification Center; rule editor (constrained,
  non-script actions).
- **later / dropped:** Terminal-script rule action (sandbox-incompatible); self-extracting `.exe`;
  Stuffit/.sit; PAR1 *create* (likely drop); creating `.rar` (legally forbidden); MAS distribution.

---

## 10. Decision log (one-liners)

1. **ModernPAR = GPL-2.0-or-later open source** (owner decision 2026-06-09; repo-root `COPYING` is
   the project license) → **PAR2 engine = turbo embedded in-process behind the C shim (primary),
   bundled CLI over `Foundation.Process` (designed-in fallback + standby license firewall)**, both
   behind the same protocol; embed is spike-gated per ROADMAP Phase 2. Restores doc 04 option (a);
   supersedes the permissive-posture subprocess-only decision in earlier drafts of §0.
2. **PAR1 = native Swift.** Removes last Intel binary, no GPL (03; 07 implied).
3. **Document model = native Swift read-only parser**, independent of the helper (03).
4. **RAR = RARLAB UnRAR 7.2.4 from source, linked in-process** via C shim; password/multi-vol in
   callbacks (07 Claim 2). **zip = libarchive (BSD).** Never RAR-through-libarchive for password/RAR5.
5. **C++ interop quarantined in ArchiveKit only**; injected behind the `ArchiveExtractor` protocol so
   Core/UI stay C++-free despite #66156 propagation (07 Claim 4).
6. **Scenes = WindowGroup(for: SessionRoute) + Settings**, not DocumentGroup (07 Claim 3).
7. **Concurrency = actors + AsyncStream + coalesced @MainActor model**; Cmd-. cancels cooperatively
   (embed: progress callback returns `false`; helper: terminate the child process) (04; 07 Claim 4).
8. **Dropped/dock URLs always round-tripped through security-scoped bookmarks** before engine I/O
   (07 Claim 3).
9. **Distribution = Developer-ID / notarized DMG + Sparkle 2, never the Mac App Store** (06; 08 §2 —
   Apple's Usage Rules are GPLv2 §6 "further restrictions" attaching to any GPL binary in the Store
   package regardless of process boundary, and the MAS sandbox forbids spawning bundled CLIs; owner
   decision 2026-06-09 adopts Option A, no MAS edition planned).
10. **Legal review required before release.** The #1 question: the GPL app now *links* the
    GPL-incompatible UnRAR source in one binary — mitigated by keeping UnRAR in its own
    component/translation units as a documented separately-licensed part, extraction-only
    (§1.4; ROADMAP risk table); confirm with counsel (07 Claim 1 & 2; 08).
