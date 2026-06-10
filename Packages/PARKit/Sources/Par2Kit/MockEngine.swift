import Foundation
import ModernPARCore

/// Emits a canned verify sequence so the full UI pipeline (file roster → per-file status → progress
/// → document status) is exercised before the real engine and parser exist. Phase 0 only.
public struct MockEngine: PAR2Engine {
    public init() {}

    public func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let task = Task {
                let files = [
                    FileEntry(name: "big.movie.part1.rar", sizeBytes: 367_001_600),
                    FileEntry(name: "big.movie.part2.rar", sizeBytes: 367_001_600),
                    FileEntry(name: "big.movie.part3.rar", sizeBytes: 367_001_600),
                    FileEntry(name: "big.movie.nfo", sizeBytes: 2_048),
                    FileEntry(name: "big.movie.sfv", sizeBytes: 256),
                ]

                continuation.yield(.scanningStarted(totalFiles: files.count))
                continuation.yield(.filesDiscovered(files))
                continuation.yield(.docStatusChanged(.checking))
                continuation.yield(.logLine("Loading \"\(route.mode)\" set…"))

                for (i, file) in files.enumerated() {
                    if Task.isCancelled {
                        continuation.yield(.docStatusChanged(.internalError))
                        continuation.yield(.finished(.failure(.cancelled)))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.fileStatusChanged(id: file.id, status: .checking))
                    try? await Task.sleep(for: .milliseconds(150))
                    continuation.yield(.fileStatusChanged(id: file.id, status: .ok))
                    continuation.yield(.logLine("Target: \"\(file.name)\" - found."))
                    continuation.yield(
                        .overallProgress(fraction: Double(i + 1) / Double(files.count)))
                }

                continuation.yield(.docStatusChanged(.allFilesOK))
                continuation.yield(.finished(.success(OperationSummary())))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
