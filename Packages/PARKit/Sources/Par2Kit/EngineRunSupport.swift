import Foundation
import ModernPARCore
import Par2Cxx

/// Scaffolding shared by `EmbeddedEngine` and `HelperProcessEngine`: both drive the same
/// par2cmdline-turbo code (in-process vs. subprocess), so scope handling, roster painting,
/// extra-file gathering, result mapping, and run serialization are identical by design —
/// the protocol-level test suite holds them to it.
enum EngineRunSupport {
    /// ALL engine runs serialize here: a cancelled run keeps its engine (and its files) briefly
    /// while unwinding, and a follow-up run must never overlap it on the same files.
    static let serialQueue = DispatchQueue(label: "org.modernpar.par2-engine", qos: .userInitiated)

    struct Scopes {
        let anchor: URL?
        let stops: [URL]
        func end() {
            for url in stops { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// Resolves the route's bookmarks (folder first — repair writes into it) and returns the
    /// anchor `.par2` URL. The caller must `end()` the scopes when the run finishes.
    static func beginScopes(for route: SessionRoute) -> Scopes {
        var stops: [URL] = []
        if let data = route.folderBookmark, let folder = try? ScopedAccess.resolve(data),
            folder.didStart
        {
            stops.append(folder.url)
        }
        var anchor: URL?
        if let data = route.anchorBookmark, let resolved = try? ScopedAccess.resolve(data) {
            anchor = resolved.url
            if resolved.didStart { stops.append(resolved.url) }
        }
        return Scopes(anchor: anchor, stops: stops)
    }

    /// The native parser is the model; the engine is the actuator. Paints the roster so the UI
    /// has rows before the first engine line, and returns the engine-printed-name → row-id map.
    /// (ARCHITECTURE.md §1.3)
    static func paintRoster(
        anchor: URL, continuation: AsyncStream<EngineEvent>.Continuation
    ) -> [String: UUID] {
        guard let set = try? Par2Parser.loadSet(anchor: anchor) else {
            continuation.yield(.scanningStarted(totalFiles: 0))
            return [:]
        }
        let parSet = ParSet(par2: set)
        continuation.yield(.scanningStarted(totalFiles: parSet.files.count))
        continuation.yield(.filesDiscovered(parSet.files))
        return rosterNames(for: set)
    }

    /// Sandbox heads-up: with only a single-file grant the engine cannot read the sibling data
    /// files and would report everything missing. (Folder powerbox flow lives in the UI layer.)
    static func warnIfFolderUnreadable(
        route: SessionRoute, anchor: URL, continuation: AsyncStream<EngineEvent>.Continuation
    ) {
        if route.folderBookmark == nil,
            !FileManager.default.isReadableFile(atPath: anchor.deletingLastPathComponent().path)
        {
            continuation.yield(
                .logLine(
                    "[err] ModernPAR may not have permission to read the set's folder — open the enclosing folder (not just the .par2) and verify again."
                ))
        }
    }

    /// The folder's data files, handed to the engine as extra files to scan — the equivalent
    /// of `par2 r set.par2 *`. This is what powers misnamed/renamed-data detection, including
    /// the engine's own `name.N` backups left by an interrupted repair. PAR metadata files
    /// are excluded (the engine loads those itself).
    static func extraFiles(near anchor: URL) -> [URL] {
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
            insert(engineDisplayName(for: description.asciiName), description.fileID.uuid)
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

    /// Maps the engine result (libpar2 `Result` — identical numeric values for the shim enum
    /// and the CLI exit code) plus the parser's tallies into the stream's terminal events.
    static func finish(
        code: Int32,
        wasCancelled: Bool,
        bridge: LineBridge,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) {
        if wasCancelled {
            continuation.yield(.finished(.failure(.cancelled)))
            return
        }
        switch code {
        case 0:  // eSuccess
            continuation.yield(
                .finished(.success(OperationSummary(repaired: bridge.repairedCount))))
        case 1:  // eRepairPossible (verify-only run on a repairable set)
            continuation.yield(
                .finished(.success(OperationSummary(stillMissing: bridge.recoverableCount))))
        case 2:  // eRepairNotPossible
            continuation.yield(
                .finished(.success(OperationSummary(stillMissing: bridge.unrecoverableCount))))
        case 5:  // eRepairFailed — the parser settled rows/doc status from "Repair Failed."
            continuation.yield(
                .finished(
                    .failure(
                        .engine(
                            code: code,
                            message: "repair completed but files are still damaged"))))
        default:
            continuation.yield(.docStatusChanged(.internalError))
            continuation.yield(
                .finished(.failure(.engine(code: code, message: "par2 engine failed"))))
        }
    }
}
