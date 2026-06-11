import Foundation
import Testing

@testable import ModernPARCore

/// Session-level behavior of the Phase 4 extraction flow: event folding, the placed-output
/// URL, terminal errors the UI reacts to, and cancel/reset bookkeeping — all through a fake
/// extractor so this stays engine-free (the real engine is covered by ArchiveKitTests).
@MainActor
struct ExtractSessionTests {

    /// Emits a canned extraction event sequence.
    struct FakeExtractor: ArchiveExtractor {
        let events: [EngineEvent]

        func extract(
            _ archive: SessionRoute,
            to destination: ExtractDestination,
            password: any PasswordProvider,
            conflicts: any ConflictResolver
        ) -> AsyncStream<EngineEvent> {
            AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    struct NoPassword: PasswordProvider {
        func password(forVolume name: String) async -> String? { nil }
    }

    struct CancelConflicts: ConflictResolver {
        func resolve(conflictAt url: URL) async -> ConflictPolicy { .cancel }
    }

    private func drain(_ session: OperationSession) async {
        // The session consumes its stream on a child task; yield until it goes idle.
        for _ in 0..<200 {
            if !session.isBusy { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func run(_ events: [EngineEvent]) async -> OperationSession {
        let session = OperationSession()
        let route = SessionRoute(mode: .extractArchive)
        session.startExtract(
            route, using: FakeExtractor(events: events),
            password: NoPassword(), conflicts: CancelConflicts())
        await drain(session)
        return session
    }

    @Test func successfulExtractionFoldsRosterStatusAndPlacedURL() async throws {
        let row = FileEntry(name: "inside.txt", sizeBytes: 42)
        let placed = URL(fileURLWithPath: "/tmp/extracted-output")
        let session = await run([
            .scanningStarted(totalFiles: 1),
            .filesDiscovered([row]),
            .docStatusChanged(.extracting),
            .fileStatusChanged(id: row.id, status: .checking),
            .overallProgress(fraction: 0.5),
            .fileStatusChanged(id: row.id, status: .ok),
            .extractionPlaced(placed),
            .docStatusChanged(.extractedSuccessfully),
            .finished(.success(OperationSummary())),
        ])
        #expect(session.rows.map(\.name) == ["inside.txt"])
        #expect(session.rows.first?.status == .ok)
        #expect(session.placedURL == placed)
        #expect(session.docStatus == .extractedSuccessfully)
        #expect(session.docStatus.isGreenEndState)
        #expect(session.lastError == nil)
        #expect(session.progress == 1)
        #expect(!session.isBusy)
    }

    @Test func passwordAndVolumeFailuresSurfaceForTheUI() async throws {
        for (error, expectedFragment) in [
            (EngineError.passwordNeeded, "password"),
            (.badPassword, "password"),
            (.volumeMissing("set.part3.rar"), "set.part3.rar"),
        ] {
            let session = await run([
                .docStatusChanged(.extracting),
                .finished(.failure(error)),
            ])
            #expect(session.lastError == error)
            #expect(session.docStatus == .extractionFailed)
            #expect(
                session.log.contains { $0.localizedCaseInsensitiveContains(expectedFragment) },
                "log \(session.log) should mention \(expectedFragment)")
        }
    }

    @Test func startingANewRunClearsPlacedURLAndLastError() async throws {
        let placed = URL(fileURLWithPath: "/tmp/previous-output")
        let session = await run([
            .extractionPlaced(placed),
            .finished(.failure(.badPassword)),
        ])
        #expect(session.placedURL == placed)
        #expect(session.lastError == .badPassword)

        session.startExtract(
            SessionRoute(mode: .extractArchive),
            using: FakeExtractor(events: [.docStatusChanged(.extracting)]),
            password: NoPassword(), conflicts: CancelConflicts())
        #expect(session.placedURL == nil)
        #expect(session.lastError == nil)
        await drain(session)
    }

    /// Review finding: the user answering "Cancel" at the destination-conflict dialog makes
    /// the ENGINE report .cancelled (no task cancellation happens) — the running status must
    /// still clear instead of showing "Extracting files…" forever.
    @Test func engineReportedCancelClearsTheRunningStatus() async throws {
        let session = await run([
            .docStatusChanged(.extracting),
            .finished(.failure(.cancelled)),
        ])
        #expect(session.docStatus == .waitingToStart)
        #expect(!session.isBusy)
    }

    /// Review finding: the badPassword auto-retry guards on `!isBusy` at the moment
    /// `lastError` is published — both must change in the same main-actor job. The fake
    /// extractor keeps its stream OPEN after the finished event, so only `apply`'s own
    /// setBusy(false) can have cleared the flag when lastError becomes visible.
    @Test func terminalErrorAndBusyClearAtomically() async throws {
        struct NeverFinishingExtractor: ArchiveExtractor {
            func extract(
                _ archive: SessionRoute, to destination: ExtractDestination,
                password: any PasswordProvider, conflicts: any ConflictResolver
            ) -> AsyncStream<EngineEvent> {
                AsyncStream { continuation in
                    continuation.yield(.docStatusChanged(.extracting))
                    continuation.yield(.finished(.failure(.badPassword)))
                    // Deliberately never finished: the post-consume busy backstop can't run.
                }
            }
        }
        let session = OperationSession()
        session.startExtract(
            SessionRoute(mode: .extractArchive), using: NeverFinishingExtractor(),
            password: NoPassword(), conflicts: CancelConflicts())
        for _ in 0..<200 {
            if session.lastError != nil { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.lastError == .badPassword)
        #expect(!session.isBusy, "busy must clear in the same job that publishes lastError")
        session.cancel()
    }

    @Test func cancellingAnExtractionRestoresIdleState() async throws {
        let session = OperationSession()
        session.startExtract(
            SessionRoute(mode: .extractArchive),
            using: FakeExtractor(events: [.docStatusChanged(.extracting)]),
            password: NoPassword(), conflicts: CancelConflicts())
        #expect(session.isBusy)
        session.cancel()
        #expect(!session.isBusy)
        #expect(session.docStatus == .waitingToStart)
    }

    @Test func restoredArchiveWindowSurfacesTheArchiveWithoutRunning() async throws {
        let session = OperationSession()
        let url = URL(fileURLWithPath: "/tmp/archive.rar")
        session.noteRestoredArchive(url)
        #expect(session.anchorURL == url)
        #expect(!session.isBusy)
        #expect(session.docStatus == .waitingToStart)
    }

    /// A canned PAR2 "engine" ending in the given green state — drives the chain trigger.
    struct GreenVerifyEngine: PAR2Engine {
        var endState: DocStatus = .allFilesOK

        func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
            AsyncStream { continuation in
                continuation.yield(.docStatusChanged(.checking))
                continuation.yield(.docStatusChanged(endState))
                continuation.yield(.finished(.success(OperationSummary())))
                continuation.finish()
            }
        }
    }

    @Test func greenVerifyBumpsThePostProcessTrigger() async throws {
        let session = OperationSession()
        #expect(session.postProcessReady == 0)
        session.start(SessionRoute(mode: .verifyRepair), engine: GreenVerifyEngine())
        await drain(session)
        #expect(session.postProcessReady == 1)
        // A second green verify bumps again (each success may chain once).
        session.start(SessionRoute(mode: .verifyRepair), engine: GreenVerifyEngine())
        await drain(session)
        #expect(session.postProcessReady == 2)
    }

    @Test func extractionGreenEndDoesNotReFireThePostProcessTrigger() async throws {
        let session = await run([
            .docStatusChanged(.extracting),
            .docStatusChanged(.extractedSuccessfully),
            .finished(.success(OperationSummary())),
        ])
        #expect(session.postProcessReady == 0, "a chained extraction must never re-chain")
    }

    @Test func failedVerifyDoesNotFireThePostProcessTrigger() async throws {
        struct RedVerifyEngine: PAR2Engine {
            func run(_ route: SessionRoute) -> AsyncStream<EngineEvent> {
                AsyncStream { continuation in
                    continuation.yield(.docStatusChanged(.checking))
                    continuation.yield(.docStatusChanged(.needMoreRecovery(blocks: 3)))
                    continuation.yield(
                        .finished(.success(OperationSummary(repaired: 0, stillMissing: 1))))
                    continuation.finish()
                }
            }
        }
        let session = OperationSession()
        session.start(SessionRoute(mode: .verifyRepair), engine: RedVerifyEngine())
        await drain(session)
        #expect(session.postProcessReady == 0)
    }

    @Test func chainingIntoAnArchivePreservesTheLogAndMovesTheAnchor() async throws {
        let session = OperationSession()
        session.start(SessionRoute(mode: .verifyRepair), engine: GreenVerifyEngine())
        await drain(session)
        session.note("verify history line")

        let archive = URL(fileURLWithPath: "/tmp/payload.rar")
        session.chainIntoArchive(
            archive, ruleName: "Built-in Unrar",
            using: FakeExtractor(events: [
                .docStatusChanged(.extracting),
                .docStatusChanged(.extractedSuccessfully),
                .finished(.success(OperationSummary())),
            ]),
            password: NoPassword(), conflicts: CancelConflicts())
        await drain(session)

        #expect(session.anchorURL == archive)
        #expect(session.log.contains("verify history line"), "chained run must keep the log")
        #expect(session.log.contains { $0.contains("Post-processing (Built-in Unrar)") })
        #expect(session.docStatus == .extractedSuccessfully)
        #expect(session.postProcessReady == 1, "the chained extraction must not re-bump")
    }

    @Test func rarFileTypeRoutingMatchesVolumeNaming() {
        #expect(ArchiveFileTypes.isRARArchive(URL(fileURLWithPath: "/x/a.rar")))
        #expect(ArchiveFileTypes.isRARArchive(URL(fileURLWithPath: "/x/a.RAR")))
        #expect(ArchiveFileTypes.isRARArchive(URL(fileURLWithPath: "/x/a.r00")))
        #expect(ArchiveFileTypes.isRARArchive(URL(fileURLWithPath: "/x/a.s99")))
        #expect(!ArchiveFileTypes.isRARArchive(URL(fileURLWithPath: "/x/a.par2")))
        #expect(!ArchiveFileTypes.isRARArchive(URL(fileURLWithPath: "/x/a.q00")))
        #expect(!ArchiveFileTypes.isRARArchive(URL(fileURLWithPath: "/x/a.r0")))
        #expect(!ArchiveFileTypes.isRARArchive(URL(fileURLWithPath: "/x/rar")))
    }
}
