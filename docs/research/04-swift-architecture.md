# 04 — Swift 6 / SwiftUI Architecture & Native Engine Integration

**Scope:** App architecture for **ModernPAR**, a native arm64 macOS app reproducing **MacPAR deLuxe 5.1.1** (see ground truth: [`00-source-notes.md`](./00-source-notes.md)). Target: **macOS 26, Xcode 26 (26.5 verified), Swift 6.3 (6.3.2 verified), SwiftUI-first**.

This doc is a durable engineering reference. It is opinionated: each section ends with a **Recommendation**. The companion engine research is in `00-source-notes.md`; do not contradict the feature inventory there.

> **Local environment verified 2026-06-09:** `swift --version` → Apple Swift 6.3.2, target `arm64-apple-macosx26.0`; `xcodebuild -version` → Xcode 26.5 (17F42); `/opt/homebrew/bin/par2` → `par2cmdline version 1.1.1`, Mach-O arm64. So a native arm64 par2 already runs on the target machine — no Rosetta needed.

---

## 0. Executive summary (read this, then skim the rest)

1. **App shell:** Use a **custom `WindowGroup` + `@Observable` app model**, *not* `DocumentGroup`. A par2 "document" in MacPAR deLuxe is not a file you edit and save — it is a **working session over a folder** (verify/repair an existing set, author a new set, or extract an archive). `DocumentGroup`'s open/save/autosave/versioning lifecycle actively fights this model. Reproduce the document *feel* (one window per set, recent items, drag-to-dock) with a hand-rolled scene + `NSDocumentController`-free recents. **(§2)**
2. **Engine wrapping:** Compile **par2cmdline-turbo** (animetosho) as a **C++ SwiftPM target via Swift/C++ interop**, called through a **thin C++ shim** that exposes a C-ish progress-callback API. Fall back to a **bundled CLI helper driven by `Foundation.Process`** only if interop friction is too high. **Do not ship on the Mac App Store** — par2cmdline-turbo is **GPL-2.0-or-later**, which is incompatible with App Store terms. Distribute Developer ID + notarized, sandboxed, outside the store. **(§3, §4)**
3. **Concurrency:** Model each operation as a structured `Task` owned by an `@Observable` session model. Stream `EngineEvent`s (progress, per-file status, log lines) from an **engine `actor`** to the UI via **`AsyncStream`**. Reproduce **Cancel (Cmd-.)** with `Task.cancel()` + cooperative `Task.isCancelled` checks inside the C++ progress callback. **(§5)**
4. **State:** `@Observable` (Observation framework) models. One `AppModel` (settings, recents, the open-session list), one `OperationSession` per window, an `Array<FileEntry>` of `@Observable` rows. Read-where-you-render so Observation only invalidates affected rows. **(§6)**
5. **Files:** Sandbox with `com.apple.security.files.user-selected.read-write`. Acquire **folder** access via `fileImporter`/`NSOpenPanel`, persist with **security-scoped bookmarks**, wrap all engine I/O in `startAccessingSecurityScopedResource()` / `stop…`. Drag-and-drop into the list and onto the dock icon both resolve to security-scoped URLs. **(§7)**
6. **Platform glue:** `Settings` scene for Preferences, `CommandGroup`/`CommandMenu` for the menu bar + shortcuts, SwiftUI `.toolbar`, `UserNotifications` for finish notifications with a "Show in Finder" action. **(§8)**
7. **Modules:** `PAR2Engine` (C++ target + Swift wrapper), `ModernPARCore` (models, services, no UI), `ModernPARUI` (SwiftUI), thin `ModernPARApp` executable. **(§9, §10)**

---

## 1. The shape of the problem

MacPAR deLuxe is described in `Info.plist` as document-based (`PAR1Document`, `PAR2Document`, `UnrarDocument`, `MyDocument`), but functionally a "document" is one of **three long-running, folder-scoped jobs**:

| Mode | What the user picks | What the app operates on | Output |
|------|--------------------|--------------------------|--------|
| **Verify/Repair** | a `.par2` / `.par` / `.pNN` recovery file | **the whole folder** that file lives in (scans all files for renamed/missing blocks) | repaired data files in place |
| **Create** | a set of files **all in one folder** | the chosen files + create options | new `.par2`/`.pNN` recovery files |
| **Unrar** | the first volume (`.rar`, `.partNN.rar`, `.001`, sfx `.exe`) | the archive's whole volume set | extracted files (maybe in a new folder) |

Cross-cutting traits that drive every architectural choice:

- **Folder-scoped, not file-scoped.** Verify/repair reads/writes *many* files in a directory; create reads a sibling set; unrar reads volumes + writes outputs. This is the single most important fact for both the document model (§2) and sandbox access (§7).
- **Long-running and cancellable.** Operations take seconds to many minutes. There is a global **Cancel (Cmd-.)**; Quit is disabled while busy.
- **Streaming progress + per-file status.** The UI shows a live file list with per-row status icons and a document-level status line, fed continuously by the engine.
- **Stateful re-runs.** "Repair again" / "Retry recovery" keeps the window open, remembers which files are already OK, and skips them — i.e. the session model outlives a single engine invocation.
- **Post-processing automation.** After a successful verify/repair, rules can fire (unrar built-in, unzip, open-with, run a shell command). So an operation can *chain into* another operation within the same session.

A clean way to think about it: **each window owns one `OperationSession`, bound to one folder, that can run a sequence of engine operations and accumulates per-file state.**

---

## 2. SwiftUI app structure: DocumentGroup vs custom WindowGroup

### 2.1 Why `DocumentGroup` is the wrong fit

`DocumentGroup` is built around the "open/edit/save a file" lifecycle: it expects a `FileDocument`/`ReferenceFileDocument` (or `FileWrapper`) whose contents are loaded into memory, mutated, and serialized back, with autosave, versions, and "Edited" / revert semantics layered on by the framework. (Apple, *Build document-based apps in SwiftUI*, WWDC20 — https://developer.apple.com/videos/play/wwdc2020/10039/ ; *Bring multiple windows to your SwiftUI app*, WWDC22 — https://developer.apple.com/videos/play/wwdc2022/10061/.)

That model breaks on every ModernPAR trait:

- **No single editable document blob.** The "document" is a *folder + a recovery set*. The bytes ModernPAR cares about are dozens of data files plus recovery files on disk; there is nothing to read into a `FileDocument` and write back. Forcing a `FileDocument` would mean either (a) reading the whole folder into memory (absurd for multi-GB sets) or (b) a `ReferenceFileDocument`/`FileWrapper` that's really just a pointer to a directory — at which point `DocumentGroup` is pure overhead.
- **Autosave/versions are actively harmful.** The framework wants to autosave and snapshot the document. ModernPAR's writes are destructive, deliberate engine operations (repair overwrites data files, create emits new files). You do not want SwiftUI's document machinery touching the folder.
- **The lifecycle hook is in the wrong place.** With `DocumentGroup` your code starts *after* the system has presented an open/new panel and constructed a document; there's no clean seam to say "the user picked a `.par2` — now scan its *containing folder* and kick off a verify." (Community write-up of exactly this gap: Rhonabwy, *SwiftUI Field Notes: DocumentGroup* — https://rhonabwy.com/2022/07/19/swiftui-field-notes-documentgroup/.)
- **Three different "document types" with three different verbs.** `DocumentGroup` keys off `UTType`s for read/write. We'd need three groups (verify/create/unrar) but they overlap on file types (a `.par2` can be opened to verify *or* be the output of create) and the verb (verify vs create) is a *mode*, not a file type.

### 2.2 What we keep from the document paradigm

We still want the document *UX*: one window per set, "Open Recent", new-window-per-open, drag a file onto the dock to open it, window restoration. None of that requires `DocumentGroup`; it's all reproducible:

- `WindowGroup(for: SessionRoute.self)` gives **value-driven multiple windows** — open a new window by pushing a `SessionRoute` (folder URL bookmark + mode) and let SwiftUI restore them. (WWDC22 "Bring multiple windows", `openWindow(value:)`.)
- "Open Recent" → maintain our own recents list (array of security-scoped bookmarks) in the `AppModel`, surfaced via `CommandGroup(.newItem)`/a custom menu. (We deliberately avoid `NSDocumentController`'s recents because we're not using `NSDocument`.)
- Dock-icon drop and `open`-with → handle via `onOpenURL` / `NSApplicationDelegate application(_:open:)` adaptor and route to a new session window.

### 2.3 Recommendation

> **Use a custom `WindowGroup` driven by a `SessionRoute` value, plus a `Settings` scene. Do not use `DocumentGroup`.** Reproduce document UX (recents, one-window-per-set, dock drop, restoration) with `openWindow(value:)` + an `@Observable AppModel`. The window's content view owns an `@State OperationSession`.

Scene sketch:

```swift
@main
struct ModernPARApp: App {
    @State private var app = AppModel()           // @Observable: settings, recents, engine
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate  // dock drops, NSUserNotification

    var body: some Scene {
        // One window per session. SessionRoute is Codable+Hashable so SwiftUI
        // can persist/restore open windows.
        WindowGroup(for: SessionRoute.self) { $route in
            SessionWindow(route: route)
                .environment(app)
        } defaultValue: {
            SessionRoute(mode: app.settings.defaultDocumentType, folder: nil)
        }
        .commands { ModernPARCommands(app: app) }   // §8

        Settings { PreferencesView().environment(app) }   // §8
    }
}

/// Identifies a window's job. Stored as a bookmark, not a live URL, so it survives relaunch.
struct SessionRoute: Codable, Hashable, Identifiable {
    enum Mode: String, Codable { case verifyRepair, createPar2, createPar1, unrar }
    var id = UUID()
    var mode: Mode
    var folderBookmark: Data?   // security-scoped, app-scoped
    var primaryFileBookmark: Data?   // the .par2 / first .rar the user opened
}
```

`SessionWindow` resolves the bookmarks to URLs, builds an `OperationSession`, and (for verify/unrar) auto-starts the first operation — exactly reproducing "open a `.par2` → auto verify, then auto repair if needed."

---

## 3. Wrapping the par2 engine — three options

The engine of record is **par2cmdline-turbo** (animetosho) — a speed-focused fork of the official `par2cmdline`/`libpar2` that replaces the GF16/MD5/CRC32 core with ParPar's SIMD backend and swaps OpenMP for **C++11 `std::thread`** (so it builds fully static and threads regardless of compile flags). It targets x86 *and ARM/RISC-V* SIMD. License: **GPL-2.0-or-later**. Source: https://github.com/animetosho/par2cmdline-turbo. (Confirmed via repo + Alpine/FreeBSD/Debian packaging notes.)

**Critical, verified fact for architecture:** par2cmdline-turbo's `src/` contains the **full `libpar2` API** — `libpar2.h`/`libpar2.cpp`, `par2creator.{h,cpp}`, `par2repairer.{h,cpp}`, the packet classes, GF/Reed-Solomon/MD5/CRC cores, and a `par2cmdline.cpp` entry point. So it is usable **both** as an embeddable C++ library **and** as a CLI binary. (Repo `src/` listing.) This is what makes options (a) and (b) below both viable.

> Note: the original MacPAR deLuxe shipped `par2SL` (Peter Brian Clements' par2cmdline forked + GCD-parallelized by Gerard Putter). par2cmdline-turbo is the modern, actively-maintained, SIMD-accelerated successor and the right base for ModernPAR. The CLI option set (`-b/-s/-r/-c/-f/-u/-l/-n/-m`) in `00-source-notes.md` is the standard par2cmdline set and is preserved by turbo.

### Option (a) — Compile C++ sources into an SPM target via Swift/C++ interop

Swift 6 has first-class C++ interoperability. In SwiftPM you add a C++ target and enable interop on the consuming Swift target with `.interoperabilityMode(.Cxx)` in `swiftSettings`. SwiftPM auto-generates a module map from an umbrella header in `include/`. (Swift.org, *Setting Up Mixed-Language Swift and C++ Projects* — https://www.swift.org/documentation/cxx-interop/project-build-setup/ ; *Mixing Swift and C++* — https://www.swift.org/documentation/cxx-interop/.)

```swift
// Package.swift (excerpt)
.target(
    name: "Par2Cxx",                       // par2cmdline-turbo sources + our shim
    path: "Sources/Par2Cxx",
    cxxSettings: [
        .unsafeFlags(["-std=c++17"]),      // turbo needs >= C++11; use 17 for the shim
        .define("NDEBUG", .when(configuration: .release)),
    ]
),
.target(
    name: "PAR2Engine",                    // Swift wrapper
    dependencies: ["Par2Cxx"],
    swiftSettings: [.interoperabilityMode(.Cxx)]
),
```

**Pros**
- Single process, no IPC, no helper signing/embedding dance. Lowest latency, simplest deployment.
- Native arm64 (and trivially universal) automatically; SIMD ARM NEON path compiled by clang for the target.
- Direct in-memory progress callbacks (no line-parsing of CLI text) → richest, most reliable per-file status stream.
- One build product; `xcodebuild`/SwiftPM build it for you.

**Cons / risks**
- **Interop propagates.** Enabling `.interoperabilityMode(.Cxx)` forces *every dependent target to also enable it* (Swift.org project-build-setup; Swift Forums issue [66156]). Mitigate by keeping C++ behind a **thin C/Obj-C++ or C++-with-trivial-types shim** and putting the `.Cxx` mode only on a small wrapper target whose *Swift* surface is plain `Sendable` Swift types. Higher targets depend on the wrapper's Swift API, not the C++ module.
- par2cmdline-turbo uses C++ exceptions, threads, and `std::string`/STL containers across the boundary — not all C++ constructs import cleanly into Swift (Swift.org, *Supported Features and Constraints* — https://www.swift.org/documentation/cxx-interop/status/). **The shim should expose only C-friendly types** (POD structs, `const char *`, function pointers / a callback object) and catch C++ exceptions internally, translating to error codes.
- The turbo upstream is built with autotools (`autoreconf`/`./configure`/`make`); we'd vendor `src/*.cpp` into the SPM target and supply our own build settings + a small config header instead of running `configure`. Some `config.h`-gated `#ifdef`s (endianness, intrinsics availability) need a hand-written `config.h` for arm64-apple.
- **GPL:** compiling GPL C++ into the app makes the whole binary GPL-2.0+ → fine for Developer-ID distribution with source offer, **but App-Store-incompatible** (§4).

### Option (b) — Bundle a CLI helper driven by `Foundation.Process`

Ship the `par2cmdline-turbo` (or stock `par2cmdline`) binary inside `Contents/Helpers/`, run it with `Foundation.Process`, parse stdout for progress and per-file status. This is exactly what MacPAR deLuxe did with `par2SL` and `par` and what we proved works on this machine (`/opt/homebrew/bin/par2`, arm64, v1.1.1).

```swift
let proc = Process()
proc.executableURL = Bundle.main.url(forResource: "par2", withExtension: nil,
                                     subdirectory: "Helpers")
proc.arguments = ["v", "-q", par2Path] + dataFiles
let out = Pipe(); proc.standardOutput = out
proc.launch()
for try await line in out.fileHandleForReading.bytes.lines {   // async, cancellable
    parse(line)   // "Repairing: 42.3%", "Target: \"x.rar\" - found." etc.
}
```

**Pros**
- **License firewall:** the GPL engine is a *separate executable* invoked over a process boundary, not linked into our binary. The GPL "mere aggregation" / separate-program argument is far stronger than option (a). Our Swift app can stay non-GPL. (This is the standard pattern for shipping GPL CLIs next to proprietary GUIs.)
- Crash isolation: an engine segfault kills the child, not the GUI.
- Trivial to update the engine binary independently.
- We already know the CLI contract (`00-source-notes.md`) and have a working arm64 binary.

**Cons / risks**
- **Progress fidelity is text-parsing.** par2cmdline's stdout is human-oriented and version-sensitive; per-file status must be reverse-engineered from log lines. Brittle vs. the structured callbacks of option (a). (Verbose `-v` helps but the grammar still isn't a stable API.)
- **Sandbox + child process.** A sandboxed app *can* spawn a bundled helper, but the child inherits the sandbox and the parent must hand it file access. Passing a *folder* of user-selected files to a child is the awkward part: the child needs to read/write the same folder. Workable because security-scoped access is process-wide for the folder the parent opened, **but** you must ensure the helper is launched such that it inherits access (launching a bundled tool inside the app's container is allowed; arbitrary paths are not). Plan to start/stop security scope around the `Process` run and pass absolute paths inside the granted folder. (Apple Dev Forums threads on sandbox + auxiliary/helper executables: https://developer.apple.com/forums/thread/677877.)
- Cancellation = `proc.terminate()` (SIGTERM) + reaping; fine, but coarser than cooperative cancel.
- Cmd-line can't express everything libpar2 can (e.g. fine-grained "skip already-OK files" for Retry needs us to recompute which files to pass).

### Option (c) — XPC service / privileged-or-sandbox-friendly helper

Put the engine in an **XPC service** bundled in the app (`Contents/XPCServices/…`). The GUI talks to it over `NSXPCConnection`; the service runs the C++ (option a) *or* the CLI (option b) in its own process with its own sandbox profile.

**Pros**
- Best **fault isolation** and the cleanest concurrency story: the GUI never blocks, the service can be its own sandbox with exactly the file entitlements it needs.
- Can still embed libpar2 (GPL) *inside the XPC service* and expose a non-GPL XPC protocol — though "separate process" GPL arguments are weaker here than for a standalone CLI because the service is part of our bundle and tightly coupled.
- Future-proof for App-Sandbox tightening.

**Cons / risks**
- **Most complex.** You design an `@objc` / Swift `NSXPCConnection` protocol, handle connection invalidation, stream progress *across* XPC (callbacks/`AsyncStream` over XPC, or a reply-handler protocol), and pass security-scoped **bookmark data** (not live URLs) to the service so it can re-acquire access. Security-scoped URLs do not cross process boundaries as live handles; you transfer bookmark `Data` and the service resolves + `startAccessingSecurityScopedResource()`.
- More signing/entitlement surface (the service is a separate signed bundle).
- Overkill for a single-user desktop utility where the engine is reasonably robust. The crash-isolation benefit is real but modest.

### 3.x Recommendation

> **Primary: option (a) — embed par2cmdline-turbo as a C++ SwiftPM target behind a thin C-style shim** — because it gives the richest, most reliable progress/per-file callbacks (matching the original's per-file status icons) in one simple process, native arm64, no IPC. **Keep the C++ interop confined to one `PAR2Engine` wrapper target** that publishes a clean `Sendable` Swift API.
>
> **Keep option (b) — the bundled CLI helper — as a designed-in fallback** behind the same `PAR2Engine` protocol, for two reasons: (1) it is the **GPL license firewall** if we ever reconsider distribution, and (2) it de-risks interop friction with turbo's STL/exception-heavy code. Architect `PAR2Engine` as a *protocol* with an `EmbeddedEngine` (a) and `HelperProcessEngine` (b) conformance so the choice is swappable.
>
> **Skip option (c) (XPC)** for v1 — the complexity isn't justified for a single-user utility, and embedding (a) already meets the goals. Revisit only if engine crashes prove common or App-Sandbox rules tighten.

The same applies to **PAR1** (small, ancient `parchive` code — embed or bundle similarly) and **unrar** (§4 — license-sensitive, lean toward bundling/`libarchive`).

---

## 4. Sandbox, GPLv2, and App Store implications (cross-cutting)

This decides distribution, so call it early.

### 4.1 GPL-2.0 vs the Mac App Store — incompatible

par2cmdline-turbo and the original par2cmdline lineage are **GPL-2.0(-or-later)**. The FSF and multiple high-profile cases (GNU Go pulled; VLC blocked) established that **the Mac App Store's Terms of Service impose additional usage/DRM restrictions that GPLv2 §6 forbids** ("You may not impose any further restrictions on the recipients' exercise of the rights granted herein"). Sources: FSF, *GPL Enforcement in Apple's App Store* — https://www.fsf.org/news/2010-05-app-store-compliance ; FSF, *More about the App Store GPL Enforcement* — https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement ; Computerworld, *GPLv2 blocks VLC from Apple's App Store* — https://www.computerworld.com/article/1347653/.

**Consequence:** if ModernPAR links/embeds the GPL engine (option a) **or** even bundles the GPL CLI inside the app, **it cannot ship on the Mac App Store.** Either path makes the distributed work a GPL combined/aggregate work that the MAS terms can't satisfy.

### 4.2 Recommended distribution

> **Distribute outside the Mac App Store: Developer ID-signed, hardened-runtime, notarized, with App Sandbox enabled, and an updater (Sparkle).** Provide complete corresponding source for the GPL components (engine sources + build scripts) to satisfy GPL-2.0 §3 — trivial since they're upstream forks. The *Swift app code* can be whatever license we like under option (b) (separate-program), or must be GPL-compatible under option (a) (linked).

A Developer-ID sandboxed app gets the same file-access entitlements as a MAS app, so we lose nothing functionally by skipping the store; we only lose store listing/IAP, which this utility doesn't need (drop the donation nags per ground truth).

### 4.3 unrar license (separate from par2)

The **RARLAB UnRAR** source is *not* GPL: it permits extracting RAR in any software free of charge but **forbids using it to recreate the RAR compressor / reverse-engineer the compression algorithm** (RARLAB license — https://www.rarlab.com/license.htm; Wikipedia *unrar*). It is *not* OSI-approved and conflicts with GPL (hence Fedora/Debian/7-Zip wrangling), but for a non-GPL or GPL-with-exception bundling it's usable for *extraction only*.

Options for RAR in ModernPAR:
- **Bundle the RARLAB `unrar` source/lib** (what MacPAR deLuxe did with `libUnrar.dylib`) — full RAR2/3/5 + password + multivolume support, but adds the UnRAR license and complicates a GPL-linked build (the UnRAR license restrictions are *further restrictions* → don't statically combine UnRAR *into* the GPL engine; keep RAR as its own component/process).
- **Use macOS `libarchive`** — read-only RAR support including RAR5 since libarchive 3.4.0, **but it deliberately skips RAR's proprietary filters** (to avoid the UnRAR license), so some real-world RAR5 archives fail to extract. (libarchive RAR5 notes: https://github.com/libarchive/libarchive/issues/1035 ; evince issue confirming 3.4.0 RAR5 — https://gitlab.gnome.org/GNOME/evince/-/issues/1190.)

> **Recommendation for RAR:** bundle RARLAB `unrar` as a **separate CLI helper / dylib component** (its own license firewall, kept apart from the GPL par2 engine) to retain full RAR5 + password + multivolume fidelity that `00-source-notes.md` requires. Treat it as its own `UnrarEngine` behind a protocol, same pattern as §3. `libarchive` is a thin fallback but not sufficient on its own.

### 4.4 Sandbox entitlement set (target)

- `com.apple.security.app-sandbox` = true
- `com.apple.security.files.user-selected.read-write` = true (NSOpenPanel / fileImporter grants)
- `com.apple.security.files.bookmarks.app-scope` = true (persist folder access across launches; **app-scoped**, since access isn't tied to a saved document)
- Hardened runtime; if option (a) embeds C++ with JIT-free code, no extra exceptions needed. If we spawn helpers (option b / unrar), we do **not** need `com.apple.security.inherit` for *bundled* tools we launch ourselves, but we must pass them paths inside already-granted scope.

---

## 5. Concurrency: structured tasks, actors, streaming, cancellation

Swift 6.3 with Xcode 26 defaults new projects to **Approachable Concurrency** + **`MainActor` default isolation** — i.e. all your code is on the main actor unless you opt a type into being an `actor` / `nonisolated`. (Donny Wals, *Setting default actor isolation in Xcode 26* — https://www.donnywals.com/setting-default-actor-isolation-in-xcode-26/ ; *What is Approachable Concurrency in Xcode 26?* — https://www.donnywals.com/what-is-approachable-concurrency-in-xcode-26/ ; SwiftLee, *Default Actor Isolation in Swift 6.2* — https://www.avanderlee.com/concurrency/default-actor-isolation-in-swift-6-2/.) We lean into this: **UI + models on `MainActor`, the engine on its own `actor`, the C++ work on a `Task.detached`/dedicated thread**.

### 5.1 The streaming model

The engine produces a stream of typed events; the session consumes them on the main actor and mutates `@Observable` state.

```swift
enum EngineEvent: Sendable {
    case scanning(file: String)
    case fileStatus(id: FileEntry.ID, status: FileStatus)   // OK / missing / badChecksum / recovered ...
    case progress(Double)                                   // 0...1 for the current phase
    case phase(OperationPhase)                              // verifying / repairing / done
    case log(String)                                        // raw engine line for "Show par Output"
    case finished(OperationResult)
}
```

`AsyncStream` is the right primitive: it bridges a *callback-based* producer (the C++ progress callback, or the `Process` stdout reader) into an `AsyncSequence` the UI can `for await` over. Two cancellation subtleties to handle (Swift Forums, *Why AsyncStream breaks structured concurrency* — https://forums.swift.org/t/why-asyncstream-breaks-structured-concurrency/71477 ; tanaschita, *task cancellation and AsyncStream* — https://tanaschita.com/swift-async-tasks-cancellation-asyncstream/):

1. Cancelling the **consumer** Task does **not** auto-cancel the **producer**. Wire `continuation.onTermination` to signal the C++ engine to stop (set a flag the callback checks) or `proc.terminate()`.
2. `Task.cancel()` only sets a flag; the C++ loop must *check it*. Our shim's progress callback returns a "should-continue" bool that the engine honors → cooperative cancellation.

### 5.2 The engine actor + Cancel (Cmd-.)

```swift
actor PAR2EngineActor {
    func run(_ op: EngineOperation) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            // Detached so the blocking C++ runs off the actor/main thread.
            let work = Task.detached(priority: .userInitiated) {
                let cancelled = ManagedAtomic<Bool>(false)
                continuation.onTermination = { _ in cancelled.store(true, ordering: .relaxed) }
                do {
                    try EmbeddedEngine.execute(op) { ev in       // C++ shim callback (per file / per %)
                        continuation.yield(ev)
                        return !cancelled.load(ordering: .relaxed) && !Task.isCancelled  // keep going?
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.finished(.failure(error)))
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in work.cancel() }
        }
    }
}
```

In the session model, the running operation is one stored `Task`:

```swift
@Observable @MainActor
final class OperationSession {
    private(set) var phase: OperationPhase = .idle
    var files: [FileEntry] = []
    private var runningTask: Task<Void, Never>?

    func start(_ op: EngineOperation) {
        runningTask = Task {
            for await ev in await engine.run(op) { apply(ev) }   // mutate @Observable state on MainActor
        }
    }
    func cancel() { runningTask?.cancel() }   // bound to Cmd-. (§8)
    var isBusy: Bool { runningTask != nil && phase != .idle }
}
```

> **Cmd-. mapping:** add a `CommandGroup`/toolbar "Cancel" item with `.keyboardShortcut(".", modifiers: .command)` that calls `session.cancel()`; disable it when `!isBusy`. Disable **Quit** while any session `isBusy` (NSApplicationDelegate `applicationShouldTerminate` returns `.terminateLater` / `.terminateCancel`). This reproduces the original's "Cancel (Cmd-.)" and "Quit disabled while busy".

### 5.3 Recommendation

> Each operation = one structured `Task` owned by the `@MainActor @Observable OperationSession`. The engine is an `actor` that returns an `AsyncStream<EngineEvent>`; the blocking C++/CLI runs in a `Task.detached`. Cancellation flows consumer→producer via `onTermination` + a cooperative flag the C++ callback checks. Multi-file open (the "queue vs simultaneous" preference) is just whether the `AppModel` runs sessions serially (an `AsyncChannel`/serial queue of routes) or opens N windows at once.

*(If you adopt swift-async-algorithms, `AsyncChannel` is a nice fit for the serial "process one set at a time" queue; otherwise a simple actor with an array works.)*

---

## 6. State & observation (`@Observable`)

Use the **Observation framework** (`@Observable`), not `ObservableObject`. `@Observable` only invalidates views that *read* the specific properties that changed — crucial for a live-updating file list where one row's status flips mid-scan. (Apple, *Managing model data in your app* — https://developer.apple.com/documentation/SwiftUI/Managing-model-data-in-your-app.)

### 6.1 Type sketch

```swift
@Observable @MainActor
final class AppModel {                 // app-wide singleton in .environment
    var settings = Settings()          // mirrors Preferences (§8)
    var recents: [RecentItem] = []     // security-scoped bookmarks + display name
    var openMode: SessionRoute.Mode = .verifyRepair
    let engine = PAR2EngineActor()
    let unrar  = UnrarEngineActor()
    let notifier = NotificationService()
}

@Observable @MainActor
final class FileEntry: Identifiable {  // one per row in the list
    let id = UUID()
    let url: URL                       // resolved within granted scope
    let name: String
    var status: FileStatus = .pending  // drives the row icon
    var sizeBytes: Int64 = 0
    var contributesToParity = true     // PAR1 "did not contribute" case
}

enum FileStatus: Sendable {            // maps 1:1 to the ground-truth status icons
    case pending, scanning
    case ok, okAfterRename
    case missing, missingRecoverable, missingNotRecoverable
    case badChecksum, badChecksumRecoverable, badChecksumNotRecoverable
    case recovered
    case notInSet
}

enum OperationPhase: Sendable { case idle, scanning, verifying, repairing, creating, extracting, done, failed }
```

### 6.2 List performance

macOS SwiftUI `List` historically didn't lazily load rows the way iOS does, though Sequoia (15)/Tahoe improved it. For PAR2's **up to 32,768 files** this matters. (Apple Dev Forums, *List performance on macOS* — https://developer.apple.com/forums/thread/767585 ; fatbobman, *Demystifying SwiftUI List Responsiveness* — https://fatbobman.com/en/posts/optimize_the_response_efficiency_of_list/.) Tactics:

- Use a `List`/`Table` with **stable `Identifiable` ids** (the `UUID`), never index-based `ForEach`.
- Make `FileEntry` rows render cheaply; consider `.equatable()` on the row view so unaffected rows skip re-render when only one row's `status` changes. (Community-verified release-build win — see fatbobman / iifx links above.)
- For verify/repair on huge sets, **batch event application** (coalesce many `fileStatus` events per runloop tick) so we don't invalidate 32k rows per frame. A small debounce/coalescing actor in front of `apply(ev)` keeps the UI at 60fps.
- Prefer **`Table`** (multi-column: name, status icon, size) for the native macOS look matching the original's columnar file list with alternating row colors (`.alternatingRowBackgrounds()` via `Table` or an `NSTableView` style).

### 6.3 Recommendation

> `@Observable` everywhere; `AppModel` in `.environment`, `OperationSession` per window as `@State`, `FileEntry` as `@Observable` per-row objects in a `Table`. Coalesce engine events before applying to state. Read properties *in `body`* (Observation only tracks reads in view bodies). Avoid `ObservableObject`.

---

## 7. File access (sandbox-correct)

### 7.1 Acquiring access

- **Open**: SwiftUI `.fileImporter(isPresented:allowedContentTypes:onCompletion:)` for the `.par2`/`.rar`/folder pick, or drop to `NSOpenPanel` via an AppKit bridge when we need `canChooseDirectories = true` (verify/repair really wants the *folder*). Picking through the panel is what grants sandbox access. (Apple, *Accessing files from the macOS App Sandbox* — https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox ; entitlement reference — https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html.)
- **The folder is the unit of access.** When the user opens a `.par2`, we get scope to that file; to scan/repair the **whole folder** (ground truth: it scans *all* files in the directory) we must get the user to grant the **enclosing folder** once. UX: open the `.par2`, then if folder access isn't held, present a one-time "Grant access to this folder" `NSOpenPanel` pre-pointed at the parent directory (the standard sandbox "powerbox" pattern). Granting a directory grants its descendants.

### 7.2 Persisting access (security-scoped bookmarks)

```swift
// Create (app-scoped) after the user grants the folder:
let bookmark = try folderURL.bookmarkData(
    options: [.withSecurityScope],
    includingResourceValuesForKeys: nil, relativeTo: nil)
// store `bookmark` in RecentItem / SessionRoute.

// Resolve at launch / when opening a recent:
var stale = false
let url = try URL(resolvingBookmarkData: bookmark,
                  options: [.withSecurityScope],
                  relativeTo: nil, bookmarkDataIsStale: &stale)
guard url.startAccessingSecurityScopedResource() else { /* re-prompt */ }
defer { url.stopAccessingSecurityScopedResource() }
// ... all engine reads/writes happen inside this scope ...
```

Rules: always **balance** `start`/`stop`; hold scope for the *duration of an operation* (a long verify/repair). If `stale == true`, recreate the bookmark. For the **CLI helper / XPC** (options b/c), pass **bookmark `Data`**, not the live URL, and let the child resolve + `startAccessing…` itself (live security-scoped URLs don't survive process boundaries). (AppCoda, *Remember User Intent for Folders* — https://www.appcoda.com/mac-apps-user-intent/ ; sample repo — https://github.com/sidmhatre/GetFolderAccessMacOS.)

### 7.3 Drag-and-drop (list + dock)

- **Into the file list / create set**: SwiftUI `.dropDestination(for: URL.self)` (or `.onDrop` with `UTType.fileURL`). Validate "all files in one folder" and "no resource forks" per ground truth; grant/extend folder scope as in §7.1.
- **Onto the dock icon / open-with**: handle via `NSApplicationDelegate application(_:open:)` (and `onOpenURL`); each URL → spin up a `SessionRoute` window (verify for `.par2`/`.par`/`.pNN`, unrar for archive types). Dock-drop URLs arrive with implicit access; bookmark them immediately.

### 7.4 Recommendation

> Sandbox on. Grant **folders** (not just files) via `NSOpenPanel`/`fileImporter`, persist **app-scoped** security-scoped bookmarks in recents + `SessionRoute`, and bracket every engine operation with `start/stopAccessingSecurityScopedResource()`. For drag/dock entry points, bookmark immediately on receipt. Pass bookmark `Data` (not URLs) to any out-of-process engine.

---

## 8. Platform glue: notifications, preferences, menus, toolbar

### 8.1 Preferences → `Settings` scene

Use the SwiftUI `Settings { }` scene (gets the standard ⌘, "Settings…" item and the tabbed-preferences window). Build a `TabView` matching the ground-truth panes: **Basic / Par1 / Par2 / Unrar / Post-processing / Other**. Back it with `@AppStorage` for scalars and the `@Observable Settings` for structured prefs (the post-processing rules list, which needs add/edit/reorder/delete). (Nil Coalescing, *Scene types in a SwiftUI Mac app* — https://nilcoalescing.com/blog/ScenesTypesInASwiftUIMacApp/.)

### 8.2 Menus & shortcuts → `commands`/`CommandGroup`

`CommandGroup`/`CommandMenu` to reproduce the menu bar; `.keyboardShortcut` for the accelerators. (Swift with Majid, *Commands in SwiftUI* — https://swiftwithmajid.com/2020/11/24/commands-in-swiftui/ ; Apple, *CommandGroup* — https://developer.apple.com/documentation/swiftui/commandgroup.)

Map the ground-truth verbs:
- **New** (`CommandGroup(.newItem)`), **Open + Repair** (⌘O → file importer), **Unrar Archive…** (⌘U), **Repair again**, **Add / Remove** files, **Create par1 / Create par2**, **Cancel (⌘.)**, **Show/Hide par Output**, **Help**, **Homepage**, **Support**.
- "Copy selected file names" → ⌘C in the list; "Select all erroneous files" → custom Edit-menu command.
- Drop the original's donation/auto-update menu items.

### 8.3 Toolbar

SwiftUI `.toolbar { ToolbarItemGroup { … } }` on the session window: New, Open+Repair, Repair again, Add, Remove, Create par1, Create par2, **Cancel**, Preferences, Help. Bind enabled/disabled to `session.phase`/`isBusy`.

### 8.4 Notifications → `UserNotifications`

Replace the deprecated `NSUserNotification` with the **`UserNotifications`** framework: request authorization once, post a `UNNotificationRequest` on each operation finish (success/fail), and register a notification **action** "Show in Finder" (`UNNotificationAction`) whose handler calls `NSWorkspace.activateFileViewerSelecting([outputURL])`. This reproduces the original's "notification on each finish → click → Show in Finder."

### 8.5 Recommendation

> `Settings` scene (tabbed, `@AppStorage` + `@Observable Settings`); `commands { }` with `CommandGroup`/`CommandMenu` + `.keyboardShortcut` for the full verb set incl. **Cmd-.**; `.toolbar` mirroring the original; `UserNotifications` with a "Show in Finder" action. Drop donation/auto-update UI; use Sparkle for updates if desired.

---

## 9. Recommended module / target breakdown

```
ModernPAR.xcodeproj  (App target: ModernPARApp — thin)
└── Packages/
    └── ModernPARKit (SwiftPM)
        ├── Par2Cxx              [C++ target]  vendored par2cmdline-turbo src/ + config.h + Shim/
        │                                       umbrella header in include/, NO Swift here
        ├── Par1Cxx             [C target]     vendored parchive src + shim (small)
        ├── UnrarComponent       [C++ target / or bundled CLI]  RARLAB unrar, license-isolated
        ├── PAR2Engine           [Swift, .interoperabilityMode(.Cxx)]  wraps Par2Cxx/Par1Cxx
        │                          → publishes Sendable Swift API (EngineEvent, EngineOperation)
        │                          → contains EmbeddedEngine (a) + HelperProcessEngine (b)
        ├── ModernPARCore        [Swift, plain] models (AppModel, OperationSession, FileEntry,
        │                          Settings, SessionRoute), services (BookmarkStore,
        │                          NotificationService, PostProcessRules), NO UI, NO C++ interop
        └── ModernPARUI          [Swift, SwiftUI] all views (SessionWindow, FileTable,
                                   PreferencesView, Commands, Toolbar)
```

Key boundary discipline (the linchpin of the whole design):

- **C++ interop is quarantined in `PAR2Engine`** (and `Par2Cxx`). `.interoperabilityMode(.Cxx)` propagates to *dependents*, so `ModernPARCore`/`ModernPARUI` must **not** import the C++ module — they depend only on `PAR2Engine`'s pure-Swift, `Sendable` API. This is the documented constraint (Swift.org project-build-setup; Swift Forums [66156]) turned into an architectural rule.
- `ModernPARCore` is UI-free and C++-free → fast to compile, easy to unit-test (mock `PAR2Engine` via its protocol).
- The app target is a thin `@main` + `App` scene wiring (`§2`).

---

## 10. Key Swift type sketches (consolidated)

```swift
// ---- Engine surface (pure Swift, Sendable; the seam between options a/b/c) ----
public protocol PAR2Engine: Sendable {
    func run(_ op: EngineOperation) -> AsyncStream<EngineEvent>
}

public struct EngineOperation: Sendable {
    public enum Kind: Sendable { case create(CreateOptions), verify, repair }
    public var kind: Kind
    public var par2URLBookmark: Data        // passed as bookmark for out-of-process safety
    public var dataFileBookmarks: [Data]
    public var memoryLimitMB: Int?
    public var cpuCoreLimit: Int?           // ground-truth "limit CPU cores" pref
}

public struct CreateOptions: Sendable {     // mirrors par2 -b/-s/-r/-c/-f/-u/-l/-n
    public var redundancyPercent: Int?      // -r   (1...100)
    public var blockSizeKB: Int?            // -s   (or nil = automatic)
    public var blockCount: Int?             // -b
    public var recoveryBlockCount: Int?     // -c
    public var firstBlock: Int?             // -f
    public var uniformRecoveryFiles: Bool   // -u
    public var limitRecoveryFileSize: Bool  // -l
    public var numberOfRecoveryFiles: Int?  // -n
}

// ---- EmbeddedEngine (option a) — calls the C++ shim ----
public struct EmbeddedEngine: PAR2Engine { /* §5.2 body; bridges Par2Cxx callbacks → EngineEvent */ }

// ---- HelperProcessEngine (option b) — Foundation.Process + stdout parse ----
public struct HelperProcessEngine: PAR2Engine { /* §3 option b body */ }
```

```cpp
// ---- C++ shim header (Par2Cxx/include/Par2Shim.h) — only C-friendly types cross the line ----
typedef bool (*par2_progress_cb)(void *ctx, int eventKind, double fraction,
                                 const char *fileName, int fileStatus);
//  returns false → engine should cancel cooperatively (§5.1)

extern "C" int par2_verify(const char *par2Path, const char *const *files, int count,
                           par2_progress_cb cb, void *ctx);   // wraps Par2Repairer
extern "C" int par2_repair(/* … */);                          // wraps Par2Repairer
extern "C" int par2_create(/* … CreateOptions fields … */);   // wraps Par2Creator
// shim catches C++ exceptions internally and returns error codes.
```

---

## 11. Open questions / risks

1. **par2cmdline-turbo build integration.** It uses autotools; we must vendor `src/*.cpp` and supply a hand-written `config.h` for arm64-apple (intrinsics + endianness `#ifdef`s) instead of `./configure`. *Mitigation:* generate `config.h` once on the dev machine, commit it; pin a turbo release tag.
2. **C++ interop maturity for STL/exceptions across the boundary.** turbo uses `std::thread`, `std::string`, exceptions. Swift/C++ interop has constraints (Swift.org *status* page). *Mitigation:* the C-style shim (§10) confines all STL/exceptions to C++; Swift only ever sees PODs + function pointers. This also keeps option (b) as a drop-in fallback.
3. **Progress fidelity under option (b).** CLI stdout is version-sensitive; per-file status parsing is brittle. *Mitigation:* prefer option (a); if forced to (b), pin the helper version and snapshot-test the parser against known output.
4. **List performance at 32k files.** macOS `List`/`Table` lazy-loading is still imperfect. *Mitigation:* `Table` + stable ids + `.equatable()` rows + event coalescing (§6.2); consider an `NSTableView`/`NSViewRepresentable` escape hatch only if SwiftUI `Table` can't hold 60fps.
5. **GPL ⇒ no Mac App Store.** Confirmed incompatibility. *Mitigation:* commit to Developer-ID + notarized distribution; publish corresponding engine source; this loses nothing functional.
6. **UnRAR license entanglement.** Keep RARLAB unrar isolated from the GPL par2 engine (separate component/process) to avoid "further restrictions" combination issues; ship the UnRAR license text. Evaluate libarchive only as a partial fallback (no proprietary RAR filters).
7. **Sandbox folder-grant UX.** Opening a single `.par2` doesn't grant the *folder* we must scan. Need a clean one-time "grant this folder" flow; verify the powerbox pre-selection lands on the right directory.
8. **Quit-while-busy + window restoration.** `applicationShouldTerminate` gating interacts with SwiftUI scene restoration of `SessionRoute` windows; confirm restored windows don't auto-launch destructive repairs without consent.

---

## 12. Sources

- Swift.org — *Mixing Swift and C++*: https://www.swift.org/documentation/cxx-interop/
- Swift.org — *Setting Up Mixed-Language Swift and C++ Projects (SwiftPM)*: https://www.swift.org/documentation/cxx-interop/project-build-setup/
- Swift.org — *Supported Features and Constraints of C++ Interoperability*: https://www.swift.org/documentation/cxx-interop/status/
- Swift Forums — interop propagation issue [66156]: https://github.com/swiftlang/swift/issues/66156
- par2cmdline-turbo (engine, GPL-2.0+, libpar2 API + CLI): https://github.com/animetosho/par2cmdline-turbo
- Parchive — par2cmdline / libpar2 (upstream classes Par2Creator/Par2Repairer): https://github.com/Parchive/par2cmdline ; https://github.com/Parchive/libpar2
- FSF — *GPL Enforcement in Apple's App Store*: https://www.fsf.org/news/2010-05-app-store-compliance
- FSF — *More about the App Store GPL Enforcement*: https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement
- Computerworld — *GPLv2 blocks VLC from Apple's App Store*: https://www.computerworld.com/article/1347653/
- RARLAB — UnRAR license: https://www.rarlab.com/license.htm
- libarchive — RAR5 read support / proprietary-filter limits: https://github.com/libarchive/libarchive/issues/1035 ; https://gitlab.gnome.org/GNOME/evince/-/issues/1190
- Apple — *Accessing files from the macOS App Sandbox*: https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
- Apple — *Enabling App Sandbox (entitlement keys)*: https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html
- AppCoda — *Remember User Intent for Folders (security-scoped bookmarks)*: https://www.appcoda.com/mac-apps-user-intent/
- Apple — *Build document-based apps in SwiftUI* (WWDC20): https://developer.apple.com/videos/play/wwdc2020/10039/
- Apple — *Bring multiple windows to your SwiftUI app* (WWDC22): https://developer.apple.com/videos/play/wwdc2022/10061/
- Rhonabwy — *SwiftUI Field Notes: DocumentGroup*: https://rhonabwy.com/2022/07/19/swiftui-field-notes-documentgroup/
- Nil Coalescing — *Scene types in a SwiftUI Mac app*: https://nilcoalescing.com/blog/ScenesTypesInASwiftUIMacApp/
- Apple — *Managing model data in your app* (Observation): https://developer.apple.com/documentation/SwiftUI/Managing-model-data-in-your-app
- Apple Dev Forums — *List performance on macOS*: https://developer.apple.com/forums/thread/767585
- fatbobman — *Demystifying SwiftUI List Responsiveness*: https://fatbobman.com/en/posts/optimize_the_response_efficiency_of_list/
- Donny Wals — *Setting default actor isolation in Xcode 26*: https://www.donnywals.com/setting-default-actor-isolation-in-xcode-26/
- Donny Wals — *What is Approachable Concurrency in Xcode 26?*: https://www.donnywals.com/what-is-approachable-concurrency-in-xcode-26/
- SwiftLee — *Default Actor Isolation in Swift 6.2*: https://www.avanderlee.com/concurrency/default-actor-isolation-in-swift-6-2/
- Swift Forums — *Why AsyncStream breaks structured concurrency*: https://forums.swift.org/t/why-asyncstream-breaks-structured-concurrency/71477
- tanaschita — *Task cancellation and AsyncStream*: https://tanaschita.com/swift-async-tasks-cancellation-asyncstream/
- Swift with Majid — *Commands in SwiftUI*: https://swiftwithmajid.com/2020/11/24/commands-in-swiftui/
- Apple — *CommandGroup*: https://developer.apple.com/documentation/swiftui/commandgroup
