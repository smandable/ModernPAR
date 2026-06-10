# ModernPAR — Phase 0 Scaffold Spec

> **Purpose.** A concrete, buildable initial-scaffold specification. A follow-up
> implementation step executes this verbatim to produce an empty-but-launchable
> SwiftUI app with the final module topology, navigation shell, and engine seam in
> place — *before* any engine, parser, or real UI is wired.
>
> **Binding inputs.** This spec implements `docs/ARCHITECTURE.md` (the decided
> architecture) and `docs/ROADMAP.md` Phase 0. Where ROADMAP Phase 0 still uses the
> older doc-04 module names (`Par2Cxx` / `PAR2Engine` / *embedded* C++ par2), this
> spec follows **ARCHITECTURE.md instead** — see the reconciliation note in §0.1. The
> ARCHITECTURE doc is newer and is the "decided" source of truth.
>
> **Verified environment (2026-06-09):** Apple Swift 6.3.2, target
> `arm64-apple-macosx26.0`; Xcode 26.5 (17F42); macOS SDK 26.5. These are the real
> on-box tools; everything below is checked against them.

---

## 0. The structural decision (DECIDED, then committed)

**Decision: Hybrid — an Xcode `.xcodeproj` app target + a local SwiftPM package
(`Packages/PARKit`).** Not SPM-only. Not C/C++ dropped straight into the app target.

**Why (one paragraph, then move on):** SwiftPM alone cannot emit a real `.app`
bundle — no `Info.plist`, no `CFBundleDocumentTypes`, no `actool`-compiled asset
catalog, no entitlements-driven signed bundle, no Sparkle copy-phase. Dropping the
C/C++ engine sources directly into the app target couples the engine to the UI, makes
it untestable headless, and globalizes C++ build flags. The hybrid (doc-06 "Option C")
gives Xcode ownership of the bundle/signing/notarization while the SwiftPM package
gives a clean, `swift test`-able module graph with per-target build settings and the
**C++-interop quarantine** the architecture depends on. This is the committed layout
in ARCHITECTURE.md §2.

Static-linking note: the `PARKit` *library* products link statically into
`MacOS/ModernPAR`, so there is **no separate dylib to sign**. The one bundled
*executable* is the GPL `par2` helper in `Contents/Helpers/` (Phase 5; a stub
placeholder in Phase 0), kept at arm's length as a subprocess — never linked.

> **⚠️ Superseded (2026-06-09, after the Phase 0 build):** the owner confirmed ModernPAR
> is itself **GPL-2.0-or-later**, which restores ROADMAP Decision 2 — the PAR2 engine is
> **embedded in-process** (`Par2Cxx` + C shim, primary, arriving in Phase 2) with the
> subprocess `HelperProcessEngine` as the designed-in fallback. The subprocess-only framing
> in this document (written under the interim permissive-posture assumption) is historical;
> the as-built Phase 0 artifacts are engine-agnostic and remain accurate. See
> ARCHITECTURE.md §0–§2 and ROADMAP "Settled architectural decisions."

### 0.1 Module-name reconciliation (resolve before coding)

ROADMAP Phase 0 predates the GPL-boundary decision and lists embedded-C++ par2 names.
**Use the ARCHITECTURE.md §2 names below.** *(Historical note — see the supersession box
above: with the 2026-06-09 license decision, `Par2Cxx` returns in Phase 2 as the embedded
engine target; the Phase 0 as-built module set below is unchanged.)* The difference is not
cosmetic — it encodes the GPL firewall: par2 is a *subprocess* (`Par2Kit`, pure Swift,
zero C/C++), so the only C++-interop target in the whole project is `ArchiveKit` (RAR/zip).

| Concept | ROADMAP Phase 0 (stale) | **This spec / ARCHITECTURE.md (use this)** |
|---|---|---|
| PAR2 engine integration | embedded C++ `Par2Cxx` | **subprocess** `Par2Kit` (pure Swift) |
| Swift engine wrapper | `PAR2Engine` target | folded into `Par2Kit` + protocols in `ModernPARCore` |
| C++ interop target(s) | `Par2Cxx`, `RarComponent` | **`ArchiveKit`** + `CUnrar` + `CLibArchive` only |
| Core models | `ModernPARCore` | `ModernPARCore` (same) |
| UI | `ModernPARUI` | `ModernPARUI` (same) |

> Action for the implementer: after scaffolding, update ROADMAP Phase 0 task bullets to
> these names so the two docs stop disagreeing. (Out of scope for the build itself.)

### 0.2 Phase 0 simplification: C/C++ targets are *declared but empty*

Phase 0 must **build and run with no C/C++ and no engine**. To keep the module
topology final while staying green:

- `Par2Kit` ships a **`MockEngine`** (pure Swift, canned events) conforming to
  `PAR2Engine`. The real `HelperProcessEngine` is a compiling stub that returns a
  "not implemented" finished event.
- `ArchiveKit`, `CUnrar`, `CLibArchive` are **omitted entirely from Phase 0** and added
  in Phase 4 (RAR) / Phase 4–5 (zip). Reason: vendoring `unrarsrc`/libarchive headers
  and turning on `.interoperabilityMode(.Cxx)` is the single most likely build-failure
  point (07 Claim 4); there is nothing in Phase 0 that needs it, and adding it now buys
  only risk. The topology is still "final" — these targets slot in behind the already-
  defined `ArchiveExtractor` protocol without restructuring.

The result: Phase 0 is **100% Swift**, no interop flag anywhere, fully `swift test`-able.

---

## 1. Directory / file tree to create

```
modern-par/                                    (existing git root)
├── ModernPAR.xcodeproj/                        NEW — Xcode app project (see §3 for settings)
│   └── project.pbxproj
├── App/                                         NEW — app-target sources (thin shell only)
│   ├── ModernPARApp.swift                       @main App: scenes, AppModel, delegate adaptor
│   ├── AppDelegate.swift                         NSApplicationDelegateAdaptor: dock-drop / open-with
│   ├── Info.plist                                bundle id, doc types, Sparkle keys, URL scheme
│   ├── ModernPAR.entitlements                    sandbox + bookmarks + network + Sparkle (verbatim §4)
│   └── Assets.xcassets/                          app icon + accent color (empty placeholders OK)
│       ├── Contents.json
│       ├── AppIcon.appiconset/Contents.json
│       └── AccentColor.colorset/Contents.json
├── Packages/
│   └── PARKit/                                  NEW — local SwiftPM package (the engine + logic layer)
│       ├── Package.swift                          tools 6.0; targets below; no C++ in Phase 0
│       ├── Sources/
│       │   ├── ModernPARCore/                     pure Swift, UI-free, C/C++-free
│       │   │   ├── SessionRoute.swift             Codable+Hashable window identity (folder bookmark)
│       │   │   ├── ParSet.swift                   parser-derived set description (empty init OK)
│       │   │   ├── FileEntry.swift                one Table row; Identifiable+Equatable+Sendable
│       │   │   ├── FileStatus.swift               status enum + StatusIcon mapping (the icon vocab)
│       │   │   ├── DocStatus.swift                document-level status line + green/red end-state
│       │   │   ├── EngineEvent.swift              Sendable event stream enum + EngineError + summaries
│       │   │   ├── PAR2Engine.swift               `protocol PAR2Engine: Sendable` (the engine seam)
│       │   │   ├── ArchiveExtractor.swift          extractor protocol + Password/Destination/Conflict
│       │   │   ├── ScopedAccess.swift              security-scoped bookmark round-trip helper
│       │   │   ├── OperationSession.swift         @MainActor @Observable per-window session
│       │   │   ├── AppModel.swift                 @MainActor @Observable app-wide model
│       │   │   ├── Settings.swift                 Observable settings (mirrors Preferences keys)
│       │   │   └── RecentsStore.swift             hand-rolled Open-Recent (we don't use NSDocumentController)
│       │   ├── Par2Kit/                            pure Swift; PAR2 subprocess engine (the GPL firewall)
│       │   │   ├── MockEngine.swift                PAR2Engine that emits canned events (drives UI now)
│       │   │   ├── HelperProcessEngine.swift       compiling stub of the Foundation.Process engine
│       │   │   └── ArgumentBuilder.swift           SessionRoute → par2 CLI args (stub; real in Phase 5)
│       │   └── ModernPARUI/                        SwiftUI views; depends on ModernPARCore
│       │       ├── SetWindow.swift                 one window per SessionRoute; owns OperationSession
│       │       ├── FileTable.swift                 Table<FileEntry> (empty rows in Phase 0)
│       │       ├── StatusBar.swift                 bottom status line + Cancel button
│       │       ├── ParOutputPane.swift             collapsible raw-log pane (placeholder)
│       │       ├── SettingsView.swift              tabbed Settings (placeholder tabs)
│       │       ├── ModernPARCommands.swift         menu commands + Cmd-O/S/U/R/. shortcuts
│       │       └── StatusIcon+Image.swift          StatusIcon → SwiftUI Image (SF Symbols for now)
│       └── Tests/
│           ├── ModernPARCoreTests/
│           │   └── EngineSeamTests.swift           MockEngine drives a fake verify end-to-end
│           └── Par2KitTests/
│               └── ArgumentBuilderTests.swift       placeholder (asserts stub shape; real in Phase 5)
├── COPYING                                      NEW — GPL-2.0-or-later (ModernPAR's own license; also covers vendored turbo)
├── THIRD-PARTY-LICENSES.md                      NEW — index of bundled licenses + source offer
├── docs/
│   └── licenses/
│       └── UnRAR-license.txt                    NEW — placeholder for verbatim RARLAB UnRAR paragraph
├── .swift-format                                NEW — first-party swift-format config
├── .gitignore                                   NEW — Swift/Xcode/DerivedData ignores
└── .github/
    └── workflows/
        └── ci.yml                               NEW — macos-26: swift test + xcodebuild build
```

Notes:
- The app target's Swift sources live in `App/` (not inside the package) and depend on
  the package's library products `ModernPARUI` (which re-exports `ModernPARCore`).
- The package has **no executable product** — only libraries — because the executable
  is the Xcode `.app`.
- `ArchiveKit` / `CUnrar` / `CLibArchive` directories are intentionally **absent** until
  Phase 4 (§0.2).

---

## 2. Swift file skeletons

These are compiling, no-op-or-thin skeletons. They build and launch an empty shell, and
the engine seam is exercised end-to-end by `MockEngine`. Target macOS 26 / Swift 6
language mode, `MainActor`-default isolation (Approachable Concurrency on).

### 2.1 `ModernPARCore` — domain & seams

**`SessionRoute.swift`**
```swift
import Foundation

/// Identifies one window/session. Codable+Hashable so WindowGroup(for:) restores it. (ARCH §3.1)
public struct SessionRoute: Codable, Hashable, Sendable, Identifiable {
    public enum Mode: Codable, Hashable, Sendable {
        case verifyRepair      // open an existing PAR set, verify → repair
        case createSet         // author a new set in a folder
        case extractArchive    // unrar / unzip
    }
    public var id = UUID()
    public var mode: Mode
    /// Security-scoped bookmark for the working FOLDER (set lives beside its data files).
    public var folderBookmark: Data?
    /// Bookmark for the specific .par2 / .par / .rar the user opened, if any.
    public var anchorBookmark: Data?

    public init(mode: Mode, folderBookmark: Data? = nil, anchorBookmark: Data? = nil) {
        self.mode = mode
        self.folderBookmark = folderBookmark
        self.anchorBookmark = anchorBookmark
    }
}
```

**`FileStatus.swift`**
```swift
import Foundation

/// The MacPAR deLuxe status vocabulary, collapsed but preserving recoverable/non-recoverable. (ARCH §3.2)
public enum FileStatus: Sendable, Equatable {
    case pending                 // queued, not yet checked
    case checking                // being hashed/matched now
    case ok                      // verified OK
    case recoverableMissing      // missing, recoverable
    case recoverableCorrupt      // bad checksum, recoverable
    case unrecoverableMissing    // missing, cannot recover
    case unrecoverableCorrupt    // bad checksum, cannot recover
    case recovered               // repaired this run
    case renamed(from: String)   // file was renamed
    case notInSet                // present but not part of parity
    case possibleError           // might be recoverable

    public var icon: StatusIcon {
        switch self {
        case .ok, .recovered:                                          return .ok
        case .recoverableMissing, .recoverableCorrupt, .possibleError: return .recoverable
        case .unrecoverableMissing, .unrecoverableCorrupt:             return .error
        case .notInSet:                                                return .notInVolumeSet
        case .pending, .checking, .renamed:                            return .neutral
        }
    }
    public var isRecoverable: Bool {
        switch self {
        case .recoverableMissing, .recoverableCorrupt, .possibleError: return true
        default: return false
        }
    }
    public var isTerminalOK: Bool { self == .ok || self == .recovered }   // → skip on retry
}

public enum StatusIcon: Sendable { case neutral, ok, recoverable, error, notInVolumeSet }
```

**`DocStatus.swift`**
```swift
/// Document-level status line, green on OK end-states, red otherwise. (ARCH §3.2)
public enum DocStatus: Sendable, Equatable {
    case waitingToStart
    case checking
    case allFilesOK
    case repairing
    case restoredSuccessfully
    case restoredWithRenames
    case needMoreRecovery(blocks: Int)
    case onlyNonRecoverableMissing
    case notValid
    case internalError

    public var isGreenEndState: Bool {
        switch self {
        case .allFilesOK, .restoredSuccessfully, .restoredWithRenames: return true
        default: return false
        }
    }
}
```

**`FileEntry.swift`**
```swift
import Foundation

/// One row in the file table. Equatable + stable id so Table can diff cheaply at 32k rows. (ARCH §3.2)
public struct FileEntry: Identifiable, Equatable, Sendable {
    public let id: UUID            // Phase 1 replaces with the real PAR2 File ID
    public var name: String
    public var sizeBytes: UInt64
    public var status: FileStatus
    public var blocksNeeded: Int

    public init(id: UUID = UUID(), name: String, sizeBytes: UInt64 = 0,
                status: FileStatus = .pending, blocksNeeded: Int = 0) {
        self.id = id; self.name = name; self.sizeBytes = sizeBytes
        self.status = status; self.blocksNeeded = blocksNeeded
    }
}
```

**`ParSet.swift`**
```swift
import Foundation

public enum ParKind: Sendable { case par1, par2 }

/// Immutable, parser-derived description of a PAR set. Phase 1 fills this from the native parser.
public struct ParSet: Identifiable, Sendable {
    public let id: UUID
    public let kind: ParKind
    public let sliceSizeBytes: UInt64
    public let sourceBlockCount: Int
    public let recoveryBlocksAvailable: Int
    public let files: [FileEntry]

    public init(id: UUID = UUID(), kind: ParKind, sliceSizeBytes: UInt64 = 0,
                sourceBlockCount: Int = 0, recoveryBlocksAvailable: Int = 0,
                files: [FileEntry] = []) {
        self.id = id; self.kind = kind; self.sliceSizeBytes = sliceSizeBytes
        self.sourceBlockCount = sourceBlockCount
        self.recoveryBlocksAvailable = recoveryBlocksAvailable; self.files = files
    }
}
```

**`EngineEvent.swift`**
```swift
import Foundation

/// The single event stream both the PAR2 helper engine and native PAR1 engine emit. (ARCH §4.1)
public enum EngineEvent: Sendable {
    case scanningStarted(totalFiles: Int)
    case fileStatusChanged(id: UUID, status: FileStatus)
    case overallProgress(fraction: Double)            // 0...1
    case logLine(String)                              // raw output → "Show par Output"
    case docStatusChanged(DocStatus)
    case finished(Result<OperationSummary, EngineError>)
}

public struct OperationSummary: Sendable, Equatable {
    public var repaired: Int
    public var stillMissing: Int
    public init(repaired: Int = 0, stillMissing: Int = 0) {
        self.repaired = repaired; self.stillMissing = stillMissing
    }
}

public enum EngineError: Error, Sendable, Equatable {
    case notImplemented
    case launchFailed(String)
    case cancelled
    case engine(code: Int32, message: String)
}
```

**`PAR2Engine.swift`** (the seam)
```swift
import Foundation

/// PAR2/PAR1 engine seam. Iterating the returned stream starts the operation;
/// cancel via the consuming Task (which terminates the child process / stops the loop).
public protocol PAR2Engine: Sendable {
    func run(_ route: SessionRoute) -> AsyncStream<EngineEvent>
}
```

**`ArchiveExtractor.swift`** (declared now; concretes arrive Phase 4)
```swift
import Foundation

public protocol ArchiveExtractor: Sendable {
    func extract(_ archive: SessionRoute,
                 to destination: ExtractDestination,
                 password: any PasswordProvider) -> AsyncStream<EngineEvent>
}

/// "Prompt once, reuse." (ARCH §6)
public protocol PasswordProvider: Sendable {
    func password(forVolume name: String) async -> String?
}

public enum ExtractDestination: Sendable {
    case besideArchive
    case ask
    case fixed(bookmark: Data)
}

public enum ConflictPolicy: Sendable { case ask, overwrite, keepBoth, cancel }
```

**`ScopedAccess.swift`**
```swift
import Foundation

/// Security-scoped bookmark round-trip (mandatory for drop/dock URLs). (ARCH §5.2)
public enum ScopedAccess {
    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    /// Resolve + begin access; caller must balance with stopAccessingSecurityScopedResource().
    public static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool, didStart: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale, url.startAccessingSecurityScopedResource())
    }
}
```

**`OperationSession.swift`**
```swift
import Foundation

@MainActor @Observable
public final class OperationSession {
    public private(set) var set: ParSet?
    public private(set) var rows: [FileEntry] = []
    public private(set) var docStatus: DocStatus = .waitingToStart
    public private(set) var progress: Double = 0
    public private(set) var log: [String] = []
    public private(set) var isBusy = false

    private var task: Task<Void, Never>?

    public init() {}

    public func start(_ route: SessionRoute, engine: any PAR2Engine) {
        cancel()
        isBusy = true
        let stream = engine.run(route)
        task = Task { [weak self] in
            await self?.consume(stream)
            self?.isBusy = false
        }
    }

    public func cancel() { task?.cancel(); task = nil }

    private func consume(_ stream: AsyncStream<EngineEvent>) async {
        var batch: [EngineEvent] = []
        for await event in stream {
            batch.append(event)
            if batch.count >= 256 { apply(batch); batch.removeAll(keepingCapacity: true) }
        }
        if !batch.isEmpty { apply(batch) }
    }

    /// Fold a coalesced batch into the model once (avoids invalidating 32k rows per frame). (ARCH §4.2)
    private func apply(_ batch: [EngineEvent]) {
        var index = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        for event in batch {
            switch event {
            case .scanningStarted:                 docStatus = .checking
            case let .fileStatusChanged(id, st):   if let i = index[id] { rows[i].status = st }
            case let .overallProgress(f):          progress = f
            case let .logLine(line):               log.append(line)
            case let .docStatusChanged(ds):        docStatus = ds
            case .finished:                        progress = 1
            }
        }
        _ = index   // (placeholder; Phase 1 builds rows from the parser, then this index is meaningful)
    }
}
```

**`AppModel.swift`**
```swift
import Foundation

@MainActor @Observable
public final class AppModel {
    public var settings = Settings()
    public var recents = RecentsStore()
    /// Phase 0 wires the MockEngine; Phase 5 swaps in HelperProcessEngine behind the same protocol.
    public var par2Engine: any PAR2Engine

    public init(par2Engine: any PAR2Engine) {
        self.par2Engine = par2Engine
    }
}
```

**`Settings.swift`**
```swift
import Foundation

/// Mirrors the Preferences panes; Phase 7 fleshes this out. Plain Observable for now.
@MainActor @Observable
public final class Settings {
    public var defaultMode: SessionRoute.Mode = .verifyRepair
    public var cpuCoreLimit: Int? = nil
    public var autoRepair = true
    public init() {}
}
```

**`RecentsStore.swift`**
```swift
import Foundation

public struct RecentItem: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var displayName: String
    public var folderBookmark: Data
}

@MainActor @Observable
public final class RecentsStore {
    public private(set) var items: [RecentItem] = []
    public init() {}
    public func add(_ item: RecentItem) {
        items.removeAll { $0.folderBookmark == item.folderBookmark }
        items.insert(item, at: 0)
        if items.count > 20 { items.removeLast(items.count - 20) }
    }
}
```

### 2.2 `Par2Kit` — pure-Swift PAR2 engine (stubs)

**`MockEngine.swift`** (drives the UI in Phase 0; satisfies the exit criterion)
```swift
import Foundation
import ModernPARCore

/// Emits a canned verify sequence so the UI pipeline is exercised before the real engine exists.
public struct MockEngine: PAR2Engine {
    public init() {}

    public func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let task = Task {
                let ids = (0..<5).map { _ in UUID() }
                continuation.yield(.scanningStarted(totalFiles: ids.count))
                continuation.yield(.docStatusChanged(.checking))
                for (i, id) in ids.enumerated() {
                    if Task.isCancelled { continuation.yield(.finished(.failure(.cancelled))); break }
                    continuation.yield(.fileStatusChanged(id: id, status: .checking))
                    try? await Task.sleep(for: .milliseconds(120))
                    continuation.yield(.fileStatusChanged(id: id, status: .ok))
                    continuation.yield(.overallProgress(fraction: Double(i + 1) / Double(ids.count)))
                }
                continuation.yield(.docStatusChanged(.allFilesOK))
                continuation.yield(.finished(.success(OperationSummary())))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

**`HelperProcessEngine.swift`** (compiling stub; real body in Phase 5)
```swift
import Foundation
import ModernPARCore

/// PAR2 via the bundled GPL `par2` helper over a process boundary — the license firewall. (ARCH §6)
/// Phase 0 stub: returns notImplemented. Phase 5 fills in Process launch + parser.
public actor HelperProcessEngine: PAR2Engine {
    private let helperURL: URL
    public init(helperURL: URL) { self.helperURL = helperURL }

    nonisolated public func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            continuation.yield(.finished(.failure(.notImplemented)))
            continuation.finish()
        }
    }
}
```

**`ArgumentBuilder.swift`** (stub)
```swift
import Foundation
import ModernPARCore

/// SessionRoute → par2 CLI args (c|v|r + -b -s -r -c -f -u -l -n -m -t). Stub now; real mapping Phase 5.
public enum ArgumentBuilder {
    public static func build(for route: SessionRoute) -> [String] {
        switch route.mode {
        case .verifyRepair:   return ["v"]
        case .createSet:      return ["c"]
        case .extractArchive: return []   // handled by ArchiveExtractor, not par2
        }
    }
}
```

### 2.3 `ModernPARUI` — SwiftUI shell

**`SetWindow.swift`**
```swift
import SwiftUI
import ModernPARCore

public struct SetWindow: View {
    @Environment(AppModel.self) private var model
    @State private var session = OperationSession()
    let route: SessionRoute?

    public init(route: SessionRoute?) { self.route = route }

    public var body: some View {
        VStack(spacing: 0) {
            FileTable(rows: session.rows)
            Divider()
            StatusBar(docStatus: session.docStatus,
                      progress: session.progress,
                      isBusy: session.isBusy,
                      onCancel: { session.cancel() })
        }
        .frame(minWidth: 560, minHeight: 360)
        .navigationTitle("ModernPAR")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Verify") {
                    if let route { session.start(route, engine: model.par2Engine) }
                }
            }
        }
    }
}
```

**`FileTable.swift`**
```swift
import SwiftUI
import ModernPARCore

public struct FileTable: View {
    let rows: [FileEntry]
    public init(rows: [FileEntry]) { self.rows = rows }

    public var body: some View {
        Table(rows) {
            TableColumn("") { row in StatusIconImage(icon: row.status.icon) }.width(24)
            TableColumn("Name", value: \.name)
            TableColumn("Size") { row in Text(row.sizeBytes.formatted(.byteCount(style: .file))) }
            TableColumn("Blocks needed") { row in Text(row.blocksNeeded, format: .number) }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No PAR set open",
                    systemImage: "doc.badge.gearshape",
                    description: Text("Open a .par2 file to verify and repair."))
            }
        }
    }
}
```

**`StatusIcon+Image.swift`**
```swift
import SwiftUI
import ModernPARCore

public struct StatusIconImage: View {
    let icon: StatusIcon
    public init(icon: StatusIcon) { self.icon = icon }
    public var body: some View {
        switch icon {
        case .neutral:        Image(systemName: "circle")
        case .ok:             Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .recoverable:    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .error:          Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .notInVolumeSet: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}
```

**`StatusBar.swift`**
```swift
import SwiftUI
import ModernPARCore

public struct StatusBar: View {
    let docStatus: DocStatus
    let progress: Double
    let isBusy: Bool
    let onCancel: () -> Void
    public init(docStatus: DocStatus, progress: Double, isBusy: Bool, onCancel: @escaping () -> Void) {
        self.docStatus = docStatus; self.progress = progress
        self.isBusy = isBusy; self.onCancel = onCancel
    }
    public var body: some View {
        HStack {
            Text(label).foregroundStyle(docStatus.isGreenEndState ? .green : .primary)
            Spacer()
            if isBusy {
                ProgressView(value: progress).frame(width: 120)
                Button("Cancel", action: onCancel).keyboardShortcut(".", modifiers: .command)
            }
        }
        .padding(.horizontal, 12).frame(height: 28)
    }
    private var label: String {
        switch docStatus {
        case .waitingToStart:        return "Waiting to start"
        case .checking:              return "Checking…"
        case .allFilesOK:            return "All files OK"
        case .repairing:             return "Repairing…"
        case .restoredSuccessfully:  return "Files restored successfully"
        case .restoredWithRenames:   return "Restored (some files renamed)"
        case .needMoreRecovery(let b): return "Need \(b) more recovery blocks"
        case .onlyNonRecoverableMissing: return "Unrecoverable files missing"
        case .notValid:              return "Not a valid PAR set"
        case .internalError:         return "Internal error"
        }
    }
}
```

**`ParOutputPane.swift`**
```swift
import SwiftUI

public struct ParOutputPane: View {
    let lines: [String]
    public init(lines: [String]) { self.lines = lines }
    public var body: some View {
        ScrollView { Text(lines.joined(separator: "\n")).font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading) }
            .frame(minHeight: 80)
    }
}
```

**`SettingsView.swift`**
```swift
import SwiftUI
import ModernPARCore

public struct SettingsView: View {
    public init() {}
    public var body: some View {
        TabView {
            Text("Basic").tabItem { Label("Basic", systemImage: "gearshape") }
            Text("Par2").tabItem { Label("Par2", systemImage: "shield") }
            Text("Unrar").tabItem { Label("Unrar", systemImage: "archivebox") }
            Text("Other").tabItem { Label("Other", systemImage: "ellipsis.circle") }
        }
        .frame(width: 480, height: 300)
    }
}
```

**`ModernPARCommands.swift`**
```swift
import SwiftUI
import ModernPARCore

public struct ModernPARCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    public init() {}
    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open and Repair…") { openWindow(value: SessionRoute(mode: .verifyRepair)) }
                .keyboardShortcut("o")
            Button("Create PAR Set…")  { openWindow(value: SessionRoute(mode: .createSet)) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Unrar Archive…")   { openWindow(value: SessionRoute(mode: .extractArchive)) }
                .keyboardShortcut("u")
        }
        CommandMenu("Operation") {
            Button("Repair Again") {}.keyboardShortcut("r")
            Button("Cancel Operation") {}.keyboardShortcut(".")
            Button("Select All Non-OK") {}
        }
    }
}
```

### 2.4 App target (`App/`)

**`ModernPARApp.swift`**
```swift
import SwiftUI
import ModernPARCore
import ModernPARUI
import Par2Kit

@main
struct ModernPARApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(par2Engine: MockEngine())   // Phase 5: swap in HelperProcessEngine

    var body: some Scene {
        WindowGroup(for: SessionRoute.self) { $route in
            SetWindow(route: route).environment(model)
        } defaultValue: {
            SessionRoute(mode: .verifyRepair)
        }
        .handlesExternalEvents(matching: ["modernpar"])
        .commands { ModernPARCommands() }

        Settings { SettingsView().environment(model) }
    }
}
```

**`AppDelegate.swift`**
```swift
import AppKit

/// Dock-drop / open-with robustness (onOpenURL alone is flaky on first dock drop). (ARCH §5.3)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // Phase 2: round-trip each URL through ScopedAccess.bookmark and openWindow(value:).
        // Phase 0: no-op so the app launches and accepts open-with without crashing.
    }
}
```

---

## 3. Project & package settings

### 3.1 `Packages/PARKit/Package.swift`
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PARKit",
    platforms: [.macOS(.v14)],          // deployment floor; app target may raise it
    products: [
        .library(name: "ModernPARUI", targets: ["ModernPARUI"]),
        .library(name: "ModernPARCore", targets: ["ModernPARCore"]),
        .library(name: "Par2Kit", targets: ["Par2Kit"]),
    ],
    targets: [
        .target(name: "ModernPARCore"),
        .target(name: "Par2Kit", dependencies: ["ModernPARCore"]),
        .target(name: "ModernPARUI", dependencies: ["ModernPARCore"]),
        .testTarget(name: "ModernPARCoreTests", dependencies: ["ModernPARCore", "Par2Kit"]),
        .testTarget(name: "Par2KitTests", dependencies: ["Par2Kit"]),
    ]
)
```
Notes:
- `swift-tools-version: 6.0` → Swift 6 language mode (strict concurrency) for the package.
  The 6.3.2 toolchain accepts the 6.0 tools version; there is no `6.3` tools version to set.
- **No `.interoperabilityMode(.Cxx)` anywhere in Phase 0** — there are no C/C++ targets yet.
  When `ArchiveKit`/`CUnrar`/`CLibArchive` land in Phase 4, the interop flag is confined to
  `ArchiveKit` and consumed only behind the `ArchiveExtractor` protocol (ARCH §2 quarantine rule).
- No `.executableTarget` — the app bundle is the Xcode target.

### 3.2 Xcode app-target build settings (bake into `project.pbxproj`)
| Setting | Value | Why |
|---|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | `dev.modernpar.ModernPAR` | new id (do not reuse `nl.xs4all.gp.macpardeluxe`) |
| `ARCHS` | `arm64` | escape Rosetta; one-line flip to `"arm64 x86_64"` if ever needed |
| `ONLY_ACTIVE_ARCH` | `NO` (Release), `YES` (Debug) | |
| `MACOSX_DEPLOYMENT_TARGET` | `14.0` | matches package floor; SwiftUI + concurrency available |
| `SWIFT_VERSION` | `6.0` | Swift 6 language mode |
| `SWIFT_STRICT_CONCURRENCY` | `complete` | enforce Sendable across the engine seam |
| `ENABLE_HARDENED_RUNTIME` | `YES` | mandatory for notarization |
| `ENABLE_APP_SANDBOX` | `YES` | sandbox on from day one |
| `CODE_SIGN_ENTITLEMENTS` | `App/ModernPAR.entitlements` | the file in §4 |
| `CODE_SIGN_STYLE` | `Automatic` (dev) | ad-hoc/`-` on CI PRs; Developer ID only on tags |
| `GENERATE_INFOPLIST_FILE` | `NO` | we ship an explicit `Info.plist` (doc types, Sparkle, scheme) |
| `INFOPLIST_FILE` | `App/Info.plist` | |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `0.1.0` / `1` | |

Scheme: one shared scheme `ModernPAR` (so `xcodebuild -scheme ModernPAR` and CI work).

### 3.3 `App/Info.plist` (Phase-0 essentials)
Include at minimum:
- `CFBundleExecutable`, `CFBundleIdentifier = $(PRODUCT_BUNDLE_IDENTIFIER)`,
  `CFBundleName = ModernPAR`, `CFBundlePackageType = APPL`, `LSMinimumSystemVersion = 14.0`.
- `CFBundleDocumentTypes` — declare the openable types now so open-with is wired early:
  - PAR2: extensions `par2`; PAR1: `par`, `p01`–`p99` pattern handled by UTI; RAR: `rar`.
    For Phase 0, declare `par2`, `par`, `rar` with role `Viewer`.
- `CFBundleURLTypes` — one entry with `CFBundleURLSchemes = ["modernpar"]` to match
  `handlesExternalEvents(matching:)`.
- Sparkle keys are **placeholders, commented or empty** in Phase 0 (Sparkle is added in the
  build/distribution track): `SUFeedURL`, `SUPublicEDKey`, `SUEnableInstallerLauncherService`.
  Do not add the Sparkle entitlement exceptions to a build that has no Sparkle framework — see §4.

### 3.4 `.swift-format`
```json
{
  "version": 1,
  "lineLength": 100,
  "indentation": { "spaces": 4 },
  "maximumBlankLines": 1
}
```
CI step: `swift format lint --recursive App Packages/PARKit/Sources`.

---

## 4. `App/ModernPAR.entitlements`

Two-stage approach to avoid notarization failures on a Sparkle-less Phase 0 build:

**Phase 0 (no Sparkle framework yet) — omit the two Sparkle `mach-lookup` exceptions.**
A `temporary-exception.mach-lookup.global-name` entry pointing at XPC services that do not
exist is harmless at runtime but is dead config; keep the file minimal until Sparkle is wired.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

**When Sparkle is added (build/distribution track), append verbatim (doc-06 §4c):**
```xml
    <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
    <array>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
    </array>
```
Never add `com.apple.security.cs.disable-library-validation`, any JIT entitlement, or
`com.apple.security.get-task-allow` to release builds.

---

## 5. Build & run commands

All commands run from the repo root `/Users/sean/modern-par`.

**Package unit tests (fast, headless, no GUI):**
```bash
swift test --package-path Packages/PARKit
```

**Build the app (Debug, arm64):**
```bash
xcodebuild -project ModernPAR.xcodeproj -scheme ModernPAR \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Debug clean build
```

**Build + run the app from the command line:**
```bash
xcodebuild -project ModernPAR.xcodeproj -scheme ModernPAR \
    -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/ModernPAR.app
```

**Release build with sandbox + hardened runtime, ad-hoc signed (CI PR shape):**
```bash
xcodebuild -project ModernPAR.xcodeproj -scheme ModernPAR \
    -configuration Release -derivedDataPath build \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    clean build
```

**Open the package in Xcode (engine-layer work):**
```bash
open Packages/PARKit/Package.swift
```

> Note: `swift build`/`swift run` of the *app* is intentionally not a path — the package
> has no executable product; the runnable artifact is the Xcode `.app`. Use `swift test`
> only for the package, `xcodebuild` for the app.

---

## 6. CI — `.github/workflows/ci.yml` (shape)

- Runner: `macos-26` (Xcode 26 preinstalled; select with `xcode-select`/`DEVELOPER_DIR` if needed).
- Job steps:
  1. `swift test --package-path Packages/PARKit`
  2. `swift format lint --recursive App Packages/PARKit/Sources`
  3. `xcodebuild ... -configuration Debug build` (ad-hoc / no signing on PRs)
- Developer-ID signing + notarization run **only on tag pushes**, not PRs (slow, uses a real
  Apple service). That workflow is defined in the build/distribution track, not Phase 0.

---

## 7. Definition of done (Phase 0)

Phase 0 is complete when **all** of the following hold:

1. **Builds clean.** `xcodebuild -project ModernPAR.xcodeproj -scheme ModernPAR
   -configuration Debug build` succeeds with zero errors, arm64, **App Sandbox ON**,
   **Hardened Runtime ON**, Swift 6 language mode + `SWIFT_STRICT_CONCURRENCY=complete`.
2. **Tests green.** `swift test --package-path Packages/PARKit` passes, including
   `EngineSeamTests` which drives `MockEngine` end-to-end and asserts the canned verify
   produces `fileStatusChanged(... .ok)` events and a `finished(.success)`.
3. **Launches & navigates.** `open …/ModernPAR.app` shows a window with an **empty
   `Table`** (`ContentUnavailableView` overlay), a status bar reading "Waiting to start",
   a toolbar "Verify" button, and the menu commands present. Clicking **Verify** runs the
   `MockEngine` and the status bar advances to "All files OK" (green). **`Cmd-,` opens an
   empty tabbed Settings window.** `Cmd-O`/`Cmd-S`/`Cmd-U` open new session windows.
4. **Module boundary verified.** `ModernPARCore` and `ModernPARUI` contain **no C/C++
   import** and the package has **no `.Cxx` interop flag** (there are no C/C++ targets in
   Phase 0). `ModernPARCore` is UI-free (no `import SwiftUI`). The engine seam is a
   pure-Swift `protocol PAR2Engine` and the app depends only on Swift APIs.
5. **GPL firewall shape is in place.** `Par2Kit` is pure Swift with `HelperProcessEngine`
   as a subprocess-shaped stub (no linked engine, no C/C++) — the architecture's
   arm's-length boundary exists structurally even though the helper binary isn't bundled yet.
6. **Legal/repo hygiene present.** `COPYING` (GPL-2.0-or-later), `THIRD-PARTY-LICENSES.md`
   with a corresponding-source note, and `docs/licenses/UnRAR-license.txt` placeholder all
   exist. `.gitignore` excludes `build/`, `.build/`, `DerivedData/`, `*.xcuserdata`.
7. **No drift.** ROADMAP Phase 0 module names updated to match §0.1 (or a one-line note
   added that ARCHITECTURE.md §2 names supersede them).

**Explicitly NOT in Phase 0** (so the implementer doesn't gold-plate): the native PAR2/PAR1
parser (Phase 1), the real `par2` subprocess + output parser (Phase 5), `ArchiveKit`/UnRAR/
libarchive and any C++ interop (Phase 4), Sparkle integration and notarization (build track),
security-scoped bookmark resolution wired into open-with (Phase 2), and real Settings
persistence (Phase 7). All of these have their seams stubbed here so no later phase
restructures the topology.
