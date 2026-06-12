import Foundation
import Testing

@testable import ModernPARCore

/// End-to-end (minus SwiftUI): `OperationSession.open` on a fixture set must populate the rows
/// and header model exactly as the Phase 1 demoable milestone requires — no engine involved.
@MainActor
struct OpenSessionTests {

    static let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    private func waitUntilIdle(_ session: OperationSession) async throws {
        for _ in 0..<200 where session.isBusy {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!session.isBusy, "session never finished parsing")
    }

    @Test func openingAPar2FilePopulatesTheDocument() async throws {
        let session = OperationSession()
        session.open(Self.fixtures.appendingPathComponent("par2cmdline/set.par2"))
        try await waitUntilIdle(session)

        let set = try #require(session.parSet)
        #expect(set.kind == .par2)
        #expect(set.sliceSizeBytes == 1000)
        #expect(set.sourceBlockCount == 15)
        #expect(set.recoveryBlocksAvailable == 7)  // siblings found via folder scan
        #expect(session.rows.count == 4)
        #expect(session.rows.allSatisfy { $0.status == .pending })
        #expect(session.docStatus == .waitingToStart)
        #expect(session.log.contains { $0.contains("Loaded PAR2 set") })
    }

    @Test func openingAFolderFindsTheIndexFile() async throws {
        let session = OperationSession()
        session.open(Self.fixtures.appendingPathComponent("par2cmdline"))
        try await waitUntilIdle(session)
        #expect(session.parSet?.kind == .par2)
        #expect(session.rows.count == 4)
    }

    @Test func openingAPar1IndexPopulatesTheDocument() async throws {
        let session = OperationSession()
        session.open(Self.fixtures.appendingPathComponent("par1/archive.par"))
        try await waitUntilIdle(session)
        let set = try #require(session.parSet)
        #expect(set.kind == .par1)
        #expect(session.rows.map(\.name).sorted() == ["alpha.dat", "beta.dat"])
    }

    @Test func cancelDuringOpenClearsBusyState() async throws {
        let session = OperationSession()
        session.open(Self.fixtures.appendingPathComponent("par2cmdline/set.par2"))
        session.cancel()
        // Cancel must restore terminal state immediately — a stuck spinner with the Open
        // button disabled was a confirmed review finding.
        #expect(!session.isBusy)
        #expect(session.docStatus == .cancelled)
        // And the discarded parse outcome must not be applied later.
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.rows.isEmpty)
        #expect(session.parSet == nil)
    }

    @Test func openingGarbageReportsNotValid() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).par2")
        try Data(repeating: 0x42, count: 256).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let session = OperationSession()
        session.open(tmp)
        try await waitUntilIdle(session)
        #expect(session.docStatus == .notValid)
        #expect(session.parSet == nil)
    }
}
