import CUnrar
import Foundation
import ModernPARCore

/// Set by the stream's `onTermination`, polled by the shim's `should_cancel` callback on
/// engine threads (same shape as Par2Kit's token; duplicated so the modules stay independent).
final class ExtractCancelToken: @unchecked Sendable {
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

/// Bridges the engine's synchronous password callback (blocking an engine-queue thread, never
/// the main thread) to the async `PasswordProvider`, caching the first answer so a
/// list-pass + extract-pass operation prompts the user exactly once. (ROADMAP Phase 4)
final class PasswordBroker: @unchecked Sendable {
    private let lock = NSLock()
    private let provider: any PasswordProvider
    private let token: ExtractCancelToken
    private let archiveName: String
    private var cached: String?
    private var prompts = 0

    init(provider: any PasswordProvider, token: ExtractCancelToken, archiveName: String) {
        self.provider = provider
        self.token = token
        self.archiveName = archiveName
    }

    /// How many times the async provider was actually consulted (the prompt-once contract).
    var promptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return prompts
    }

    /// True once any password request happened — used to tell "wrong password" from "corrupt
    /// data" on formats that cannot distinguish them (RAR3 has no password check value).
    var wasConsulted: Bool { promptCount > 0 }

    /// Blocking bridge for the C callback. Returns nil when the user declines or the run is
    /// cancelled while the prompt is up.
    func passwordSync() -> String? {
        if token.isCancelled { return nil }  // never raise a prompt for a dead run
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        prompts += 1
        lock.unlock()

        let semaphore = DispatchSemaphore(value: 0)
        let box = ValueBox<String?>(nil)
        let provider = provider
        let name = archiveName
        Task.detached {
            box.set(await provider.password(forVolume: name))
            semaphore.signal()
        }
        // Poll so a cancelled run never leaves the engine thread waiting on UI forever.
        while semaphore.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if token.isCancelled { return nil }
        }
        guard let value = box.get(), !value.isEmpty else { return nil }
        lock.lock()
        cached = value
        lock.unlock()
        return value
    }
}

/// Same blocking-bridge shape for the destination-conflict decision.
final class ConflictBroker: @unchecked Sendable {
    private let resolver: any ConflictResolver
    private let token: ExtractCancelToken

    init(resolver: any ConflictResolver, token: ExtractCancelToken) {
        self.resolver = resolver
        self.token = token
    }

    func resolveSync(conflictAt url: URL) -> ConflictPolicy {
        if token.isCancelled { return .cancel }  // never raise a dialog for a dead run
        let semaphore = DispatchSemaphore(value: 0)
        let box = ValueBox<ConflictPolicy>(.cancel)
        let resolver = resolver
        Task.detached {
            box.set(await resolver.resolve(conflictAt: url))
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if token.isCancelled { return .cancel }
        }
        // `.ask` is an input policy, not a decision — treat it as a refusal.
        let decision = box.get()
        return decision == .ask ? .cancel : decision
    }
}

/// Lock-protected single value handed across the sync/async boundary.
final class ValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// One archive entry from the list pass.
struct RAREntry: Sendable {
    var name: String
    var unpackedSize: UInt64
    var isDirectory: Bool
    var isEncrypted: Bool
    /// Format generation needed to unpack (15/20/29 for RAR1.5–4.x, 50+ for RAR5).
    var unpVersion: Int
}

/// Collects the list pass results (entry callback) and abort facts. Engine callbacks arrive
/// synchronously on the calling thread for listing, but stay lock-protected for uniformity.
final class ListCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RAREntry] = []
    private var missingVolumeName: String?
    let broker: PasswordBroker
    let token: ExtractCancelToken

    init(broker: PasswordBroker, token: ExtractCancelToken) {
        self.broker = broker
        self.token = token
    }

    func add(_ entry: RAREntry) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    func noteMissingVolume(_ name: String) {
        lock.lock()
        missingVolumeName = name
        lock.unlock()
    }

    var collected: [RAREntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var missingVolume: String? {
        lock.lock()
        defer { lock.unlock() }
        return missingVolumeName
    }
}

/// Serializes extraction callbacks (engine threads) into `EngineEvent`s on the continuation,
/// accumulating progress and the per-file outcome tallies the result mapping needs.
final class ExtractBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let idsByName: [String: UUID]
    /// Encrypted entries in pre-RAR5 formats only — RAR5 verifies passwords up front (check
    /// value), so only legacy formats can masquerade a wrong password as a CRC failure.
    private let legacyEncryptedNames: Set<String>
    private let totalBytes: UInt64
    private var doneBytes: UInt64 = 0
    private var lastPermille = -1
    private var succeededCount = 0
    private var failedCount = 0
    private var skippedCount = 0
    private var allFailuresWereLegacyEncrypted = true
    private var missingVolumeName: String?

    let broker: PasswordBroker
    let token: ExtractCancelToken

    init(
        continuation: AsyncStream<EngineEvent>.Continuation,
        idsByName: [String: UUID],
        legacyEncryptedNames: Set<String>,
        totalBytes: UInt64,
        broker: PasswordBroker,
        token: ExtractCancelToken
    ) {
        self.continuation = continuation
        self.idsByName = idsByName
        self.legacyEncryptedNames = legacyEncryptedNames
        self.totalBytes = totalBytes
        self.broker = broker
        self.token = token
    }

    func fileStart(_ name: String) {
        if let id = idsByName[name] {
            continuation.yield(.fileStatusChanged(id: id, status: .checking))
        }
    }

    /// Raw diagnostic line into the par-output pane (engine error details).
    func note(_ line: String) {
        continuation.yield(.logLine(line))
    }

    /// A warning-class skip (refused symlink, duplicate name, unwritable entry): reported and
    /// counted as skipped — NOT a data failure, so it never reads as "the archive is damaged"
    /// nor feeds the wrong-password heuristic.
    func skip(_ name: String, reason: String) {
        lock.lock()
        skippedCount += 1
        lock.unlock()
        if let id = idsByName[name] {
            continuation.yield(.fileStatusChanged(id: id, status: .notInSet))
        }
        continuation.yield(.logLine("Skipped \"\(name)\" (\(reason))."))
    }

    /// Engine code 21 (UNRARSHIM_UNKNOWN_ERROR) on a per-file basis means the entry was
    /// SKIPPED with a warning (e.g. an unsafe/absolute symlink the engine never extracts) —
    /// reported, but it must not read as data damage.
    func fileDone(_ name: String, code: Int32) {
        lock.lock()
        if code == 0 {
            succeededCount += 1
        } else if code == Int32(UNRARSHIM_UNKNOWN_ERROR.rawValue) {
            skippedCount += 1
        } else {
            failedCount += 1
            if !legacyEncryptedNames.contains(name) { allFailuresWereLegacyEncrypted = false }
        }
        lock.unlock()
        guard let id = idsByName[name] else { return }
        if code == 0 {
            continuation.yield(.fileStatusChanged(id: id, status: .ok))
        } else if code == Int32(UNRARSHIM_UNKNOWN_ERROR.rawValue) {
            continuation.yield(.fileStatusChanged(id: id, status: .notInSet))
            continuation.yield(.logLine("Skipped \"\(name)\" (link or unsupported entry)."))
        } else {
            continuation.yield(.fileStatusChanged(id: id, status: .unrecoverableCorrupt))
            continuation.yield(.logLine("Failed to extract \"\(name)\" (code \(code))."))
        }
    }

    func addBytes(_ bytes: UInt64) {
        // The yield happens INSIDE the lock so concurrent engine threads cannot reorder
        // progress fractions (the continuation yield is cheap and non-reentrant).
        lock.lock()
        defer { lock.unlock() }
        let (sum, overflow) = doneBytes.addingReportingOverflow(bytes)
        doneBytes = overflow ? .max : sum
        let fraction =
            totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0
        let permille = Int(fraction * 1000)
        // The engine reports every unpacked chunk; rate-limit to 0.1% steps so a multi-GB
        // archive does not flood the main actor with progress events.
        guard permille != lastPermille else { return }
        lastPermille = permille
        continuation.yield(.overallProgress(fraction: fraction))
    }

    func volumeChanged(_ name: String) {
        continuation.yield(
            .logLine("Continuing in volume \((name as NSString).lastPathComponent)."))
    }

    func noteMissingVolume(_ name: String) {
        lock.lock()
        missingVolumeName = name
        lock.unlock()
    }

    var missingVolume: String? {
        lock.lock()
        defer { lock.unlock() }
        return missingVolumeName
    }

    var succeeded: Int {
        lock.lock()
        defer { lock.unlock() }
        return succeededCount
    }

    var failed: Int {
        lock.lock()
        defer { lock.unlock() }
        return failedCount
    }

    var skipped: Int {
        lock.lock()
        defer { lock.unlock() }
        return skippedCount
    }

    /// True when every per-file failure was a pre-RAR5 encrypted entry — combined with "a
    /// password was asked for", that is the legacy wrong-password signature (RAR2/3 have no
    /// password check value, so a wrong key only ever surfaces as a CRC failure).
    var failuresLookLikeWrongPassword: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failedCount > 0 && allFailuresWereLegacyEncrypted
    }
}
