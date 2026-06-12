import Foundation
import ModernPARCore

/// Staging + placement machinery shared by every extractor (RAR, zip): output is extracted
/// into a fresh hidden staging folder inside the destination, then moved into place — a
/// single top-level item lands directly (no enclosing folder); multiple items land in a
/// folder named after the archive. Staging means a cancelled or failed run never leaves
/// half-written output mixed into the user's folder, and "keep both" is a simple rename.
/// (ROADMAP Phase 4 "output placement"; Phase 5 reuses it for zip.)
public enum ExtractPlacement {

    public static let stagingPrefix = ".ModernPAR-extract-"

    /// Reclaims staging folders orphaned by a hard crash/power loss (the in-run cleanup is a
    /// `defer`, which cannot run if the process dies). Only sweeps clearly-stale ones so a
    /// hypothetical concurrent extraction from another ModernPAR process is not disturbed.
    static func sweepStaleStaging(in folder: URL) {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.creationDateKey], options: [])
        else { return }
        let cutoff = Date(timeIntervalSinceNow: -3600)
        for entry in entries where entry.lastPathComponent.hasPrefix(stagingPrefix) {
            let created =
                (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? .distantPast
            if created < cutoff { try? manager.removeItem(at: entry) }
        }
    }

    /// Creates the run's staging folder inside the destination (same volume → atomic move).
    static func makeStaging(in destFolder: URL) throws -> URL {
        let staging = destFolder.appendingPathComponent(
            stagingPrefix + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        return staging
    }

    enum Placement {
        case placed(URL)
        case cancelledByUser
        case nothingToPlace
        case failed(String)
    }

    /// Moves the staged output into the destination. `isReservedTarget` names items that must
    /// NEVER be trashed by the overwrite policy (the source archive and its sibling volumes) —
    /// a colliding output is renamed instead.
    static func place(
        staging: URL,
        destFolder: URL,
        fallbackName: String,
        isReservedTarget: (URL) -> Bool,
        conflicts: ConflictBroker,
        continuation: AsyncStream<EngineEvent>.Continuation
    ) -> Placement {
        let manager = FileManager.default
        let items: [URL]
        do {
            items = try manager.contentsOfDirectory(
                at: staging, includingPropertiesForKeys: nil, options: [])
        } catch {
            return .failed("Could not read the extraction output: \(error.localizedDescription)")
        }
        guard !items.isEmpty else { return .nothingToPlace }

        let source: URL
        var target: URL
        if items.count == 1 {
            source = items[0]
            target = destFolder.appendingPathComponent(items[0].lastPathComponent)
        } else {
            source = staging
            target = destFolder.appendingPathComponent(fallbackName)
        }

        // Never let the conflict dialog put the SOURCE archive (or a sibling volume of its
        // set) in the Trash because an output name collides with it — rename instead.
        if isReservedTarget(target) {
            let safe = RARVolumes.uniqueDestination(for: target)
            continuation.yield(
                .logLine(
                    "Output name \(target.lastPathComponent) collides with the archive — extracting as \(safe.lastPathComponent)."
                ))
            target = safe
        }

        if manager.fileExists(atPath: target.path) {
            switch conflicts.resolveSync(conflictAt: target) {
            case .overwrite, .overwriteAll:  // the broker normalizes; defensive here
                do {
                    try trashOrRemove(target)
                } catch {
                    return .failed(
                        "Could not replace \(target.lastPathComponent): \(error.localizedDescription)"
                    )
                }
                continuation.yield(.logLine("Replaced existing \(target.lastPathComponent)."))
            case .keepBoth:
                target = RARVolumes.uniqueDestination(for: target)
                continuation.yield(
                    .logLine("Keeping both — extracting as \(target.lastPathComponent)."))
            case .ask, .cancel:
                return .cancelledByUser
            }
        }

        do {
            try manager.moveItem(at: source, to: target)
        } catch {
            return .failed(
                "Could not move the extracted files into place: \(error.localizedDescription)")
        }
        return .placed(target)
    }

    /// Prefer the Trash (recoverable) for "overwrite"; fall back to deletion where the Trash
    /// is unavailable (some network volumes).
    private static func trashOrRemove(_ url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Logs an engine failure's message (if any) and finishes the stream with it.
func yieldExtractFailure(
    _ error: EngineError, continuation: AsyncStream<EngineEvent>.Continuation
) {
    if case .engine(_, let message) = error {
        continuation.yield(.logLine(message))
    }
    continuation.yield(.finished(.failure(error)))
}
