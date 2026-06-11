import Foundation
import ModernPARCore
import Par2Cxx

/// The primary PAR2 engine: par2cmdline-turbo embedded in-process behind the Par2Shim C ABI.
/// (ARCHITECTURE.md §0, §1.1, §6; ROADMAP Phase 2)
///
/// `run` starts the operation immediately (the stream is NOT cold — consume it promptly;
/// events buffer until read). The blocking engine call runs on a detached task; Par2Shim's
/// line callback feeds `TurboOutputParser`, whose events are yielded into the stream.
/// Cancelling the consuming task (Cmd-.) trips the cancel token, the shim's next output poll
/// throws inside the engine, and the run unwinds cooperatively.
///
/// All embedded runs are SERIALIZED on one queue: a cancelled run keeps the engine briefly
/// while it unwinds, and a follow-up verify/repair must never overlap it on the same files.
public final class EmbeddedEngine: PAR2Engine, Sendable {
    private static let executionQueue = DispatchQueue(
        label: "org.modernpar.embedded-engine", qos: .userInitiated)
    /// Repair automatically when verify finds repairable damage (the MacPAR loop). Verify-only
    /// runs (e.g. restored windows, where auto-repair must not fire without consent) pass false.
    private let repairsAutomatically: Bool
    /// Engine thread count; 0 = automatic (turbo's default). Wired to the "limit CPU cores"
    /// preference in Phase 7.
    private let threadCount: UInt32

    public init(repairsAutomatically: Bool = true, threadCount: UInt32 = 0) {
        self.repairsAutomatically = repairsAutomatically
        self.threadCount = threadCount
    }

    public func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
        let repairs = repairsAutomatically
        let threads = threadCount
        return AsyncStream { continuation in
            let token = CancelToken()
            continuation.onTermination = { _ in token.cancel() }
            Task.detached(priority: .userInitiated) {
                Self.executionQueue.sync {
                    Self.execute(
                        route: route, repairs: repairs, threads: threads,
                        token: token, continuation: continuation)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Blocking engine drive (off the main actor)

    private static func execute(
        route: SessionRoute,
        repairs: Bool,
        threads: UInt32,
        token: CancelToken,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) {
        guard route.mode == .verifyRepair else {
            continuation.yield(.finished(.failure(.notImplemented)))
            return
        }

        // Bracket the whole run in the folder grant (repair writes into the folder), then
        // resolve the anchor .par2. (ARCHITECTURE.md §5.2)
        let folderScope = route.folderBookmark.flatMap { try? ScopedAccess.resolve($0) }
        defer {
            if folderScope?.didStart == true {
                folderScope?.url.stopAccessingSecurityScopedResource()
            }
        }
        let anchorScope = route.anchorBookmark.flatMap { try? ScopedAccess.resolve($0) }
        defer {
            if anchorScope?.didStart == true {
                anchorScope?.url.stopAccessingSecurityScopedResource()
            }
        }
        guard let anchor = anchorScope?.url else {
            continuation.yield(
                .finished(.failure(.launchFailed("session has no .par2 anchor bookmark"))))
            return
        }

        // The native parser is the model; the engine is the actuator. Paint the roster first
        // so the UI has rows before the first engine line arrives. (ARCHITECTURE.md §1.3)
        var fileIDsByName: [String: UUID] = [:]
        if let set = try? Par2Parser.loadSet(anchor: anchor) {
            let parSet = ParSet(par2: set)
            continuation.yield(.scanningStarted(totalFiles: parSet.files.count))
            continuation.yield(.filesDiscovered(parSet.files))
            fileIDsByName = Self.rosterNames(for: set)
        } else {
            continuation.yield(.scanningStarted(totalFiles: 0))
        }
        continuation.yield(.docStatusChanged(.checking))

        // Sandbox heads-up: with only a single-file grant the engine cannot read the sibling
        // data files and would report everything missing. (Folder powerbox flow = Phase 3.)
        if route.folderBookmark == nil,
            !FileManager.default.isReadableFile(
                atPath: anchor.deletingLastPathComponent().path)
        {
            continuation.yield(
                .logLine(
                    "[err] ModernPAR may not have permission to read the set's folder — open the enclosing folder (not just the .par2) and verify again."
                ))
        }

        let bridge = LineBridge(
            parser: TurboOutputParser(fileIDsByName: fileIDsByName, repairsAutomatically: repairs),
            continuation: continuation)
        let result = Self.shimRepair(
            anchor: anchor, repair: repairs, threads: threads, token: token, bridge: bridge)

        switch result {
        case PAR2SHIM_SUCCESS:
            continuation.yield(
                .finished(.success(OperationSummary(repaired: bridge.repairedCount))))
        case PAR2SHIM_REPAIR_POSSIBLE:
            // Verify-only run on a repairable set: damage found, nothing repaired yet.
            continuation.yield(
                .finished(.success(OperationSummary(stillMissing: bridge.recoverableCount))))
        case PAR2SHIM_REPAIR_NOT_POSSIBLE:
            continuation.yield(
                .finished(.success(OperationSummary(stillMissing: bridge.unrecoverableCount))))
        case PAR2SHIM_CANCELLED:
            continuation.yield(.finished(.failure(.cancelled)))
        case PAR2SHIM_REPAIR_FAILED:
            // The parser settled rows and doc status from "Repair Failed."; surface the result.
            continuation.yield(
                .finished(
                    .failure(
                        .engine(
                            code: Int32(result.rawValue),
                            message: "repair completed but files are still damaged"))))
        default:
            continuation.yield(.docStatusChanged(.internalError))
            continuation.yield(
                .finished(
                    .failure(.engine(code: Int32(result.rawValue), message: "par2 engine failed")))
            )
        }
    }

    /// Builds the roster map keyed by the names the ENGINE will print: the Description-packet
    /// (ASCII-field) name passed through the engine's par2→local translation — on macOS,
    /// backslashes become '/' and control bytes become %XX (descriptionpacket.cpp,
    /// TranslateFilenameFromPar2ToLocal at nlNormal). The display (Unicode) name is also
    /// mapped as a fallback. Ambiguous names (two files translating to one string) are
    /// dropped entirely so no row receives another file's events.
    static func rosterNames(for set: Par2RecoverySet) -> [String: UUID] {
        var map: [String: UUID] = [:]
        var ambiguous: Set<String> = []
        func insert(_ name: String, _ id: UUID) {
            if let existing = map[name], existing != id {
                ambiguous.insert(name)
            } else {
                map[name] = id
            }
        }
        for id in set.recoveryFileIDs + set.nonRecoveryFileIDs {
            guard let description = set.descriptions[id] else { continue }
            insert(Self.engineDisplayName(for: description.asciiName), description.fileID.uuid)
            insert(description.preferredName, description.fileID.uuid)
        }
        for name in ambiguous {
            map.removeValue(forKey: name)
        }
        return map
    }

    /// Mirrors `DescriptionPacket::TranslateFilenameFromPar2ToLocal` for macOS at nlNormal:
    /// '\' → '/', bytes < 32 → "%XX" (uppercase hex), everything else unchanged.
    static func engineDisplayName(for asciiName: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(asciiName.utf8.count)
        for byte in asciiName.utf8 {
            if byte < 32 {
                bytes.append(UInt8(ascii: "%"))
                let hex = String(format: "%02X", byte)
                bytes.append(contentsOf: Array(hex.utf8))
            } else if byte == UInt8(ascii: "\\") {
                bytes.append(UInt8(ascii: "/"))
            } else {
                bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func shimRepair(
        anchor: URL, repair: Bool, threads: UInt32, token: CancelToken, bridge: LineBridge
    ) -> Par2ShimResult {
        let bridgeContext = Unmanaged.passUnretained(bridge).toOpaque()
        let tokenContext = Unmanaged.passUnretained(token).toOpaque()
        let extras = extraFiles(near: anchor)
        var argv: [UnsafePointer<CChar>?] = extras.map { UnsafePointer(strdup($0.path)) }
        defer {
            for pointer in argv { free(UnsafeMutablePointer(mutating: pointer)) }
        }
        return argv.withUnsafeBufferPointer { buffer in
            par2shim_repair(
                anchor.path,
                nil,
                buffer.baseAddress,
                extras.count,
                threads,
                0,
                repair ? 1 : 0,
                { context, line, isError in
                    guard let context, let line else { return }
                    Unmanaged<LineBridge>.fromOpaque(context).takeUnretainedValue()
                        .handle(String(cString: line), isError: isError != 0)
                },
                bridgeContext,
                { context in
                    guard let context else { return 0 }
                    return Unmanaged<CancelToken>.fromOpaque(context).takeUnretainedValue()
                        .isCancelled
                        ? 1 : 0
                },
                tokenContext
            )
        }
    }

    /// The folder's data files, handed to the engine as extra files to scan — the equivalent
    /// of `par2 r set.par2 *`. This is what powers misnamed/renamed-data detection, including
    /// the engine's own `name.N` backups left by an interrupted repair. PAR metadata files
    /// are excluded (the engine loads those itself).
    private static func extraFiles(near anchor: URL) -> [URL] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: anchor.deletingLastPathComponent(),
                includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        return entries.filter { url in
            guard
                (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return false }
            let ext = url.pathExtension.lowercased()
            return ext != "par2" && ext != "par"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Set by `onTermination`, polled by the shim on engine threads.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Serializes engine output lines (which arrive on multiple engine threads) into the parser
/// and forwards the resulting events to the stream continuation (which is thread-safe).
final class LineBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: TurboOutputParser
    private let continuation: AsyncStream<EngineEvent>.Continuation

    init(parser: TurboOutputParser, continuation: AsyncStream<EngineEvent>.Continuation) {
        self.parser = parser
        self.continuation = continuation
    }

    func handle(_ line: String, isError: Bool) {
        lock.lock()
        let events = parser.consume(line, isError: isError)
        lock.unlock()
        for event in events {
            continuation.yield(event)
        }
    }

    var repairedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parser.repairedCount
    }

    var unrecoverableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parser.unrecoverableCount
    }

    var recoverableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parser.recoverableCount
    }
}
