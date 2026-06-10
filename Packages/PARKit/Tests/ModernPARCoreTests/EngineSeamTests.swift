import Foundation
import Testing

@testable import ModernPARCore
@testable import Par2Kit

/// Drives `MockEngine` end-to-end through the same consumption path the UI uses, asserting the
/// engine seam produces a valid verify sequence. (SCAFFOLD.md §7 DoD #2)
@MainActor
struct EngineSeamTests {
    /// Collect every event the engine emits for a route.
    private func collect(_ engine: any PAR2Engine, _ route: SessionRoute) async -> [EngineEvent] {
        var events: [EngineEvent] = []
        for await event in engine.run(route) { events.append(event) }
        return events
    }

    @Test func mockEngineProducesSuccessfulVerify() async {
        let events = await collect(MockEngine(), SessionRoute(mode: .verifyRepair))

        // A roster is discovered…
        let roster = events.compactMap { event -> [FileEntry]? in
            if case .filesDiscovered(let files) = event { return files }
            return nil
        }.first
        #expect(roster?.isEmpty == false)

        // …every roster file ends OK…
        let okIDs = Set(
            events.compactMap { event -> UUID? in
                if case .fileStatusChanged(let id, let status) = event, status == .ok { return id }
                return nil
            })
        #expect(okIDs == Set(roster!.map(\.id)))

        // …and the operation finishes successfully with a green document status.
        if case .finished(.success) = events.last {
        } else {
            Issue.record("expected a successful finish, got \(String(describing: events.last))")
        }
        let reachedAllOK = events.contains {
            if case .docStatusChanged(.allFilesOK) = $0 { return true }
            return false
        }
        #expect(reachedAllOK)
    }

    @Test func operationSessionFoldsEventsIntoModel() async {
        let session = OperationSession()
        session.start(SessionRoute(mode: .verifyRepair), engine: MockEngine())

        // Wait for the session to finish consuming (poll the @MainActor flag).
        while session.isBusy { try? await Task.sleep(for: .milliseconds(20)) }

        #expect(session.rows.isEmpty == false)
        #expect(session.rows.allSatisfy { $0.status == .ok })
        #expect(session.docStatus == .allFilesOK)
        #expect(session.docStatus.isGreenEndState)
        #expect(session.progress == 1)
    }
}
