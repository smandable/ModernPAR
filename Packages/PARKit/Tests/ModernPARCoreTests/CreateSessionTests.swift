import Foundation
import Testing

@testable import ModernPARCore

/// Session + model behavior for the create flow (ROADMAP Phase 6): event folding, placedURL,
/// terminal states, and the build-a-set model's one-folder enforcement + derived preview.
@MainActor
struct CreateSessionTests {

    struct FakeCreator: Par2Creator {
        let events: [EngineEvent]
        func create(_ request: CreateRequest) -> AsyncStream<EngineEvent> {
            AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private func drain(_ session: OperationSession) async {
        for _ in 0..<200 {
            if !session.isBusy { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func request() -> CreateRequest {
        CreateRequest(
            parFile: URL(fileURLWithPath: "/tmp/out.par2"),
            files: [URL(fileURLWithPath: "/tmp/a.bin")], options: CreateOptions())
    }

    @Test func successfulCreateSetsPlacedURLAndGreenStatus() async throws {
        let parFile = URL(fileURLWithPath: "/tmp/out.par2")
        let session = OperationSession()
        session.startCreate(
            request(),
            using: FakeCreator(events: [
                .docStatusChanged(.creating),
                .overallProgress(fraction: 0.5),
                .overallProgress(fraction: 1),
                .extractionPlaced(parFile),
                .docStatusChanged(.createdSuccessfully),
                .finished(.success(OperationSummary())),
            ]))
        await drain(session)
        #expect(session.docStatus == .createdSuccessfully)
        #expect(session.docStatus.isGreenEndState)
        #expect(session.placedURL == parFile)
        #expect(session.postProcessReady == 0, "create must never arm the post-process chain")
        #expect(!session.isBusy)
    }

    @Test func failedCreateShowsCreateFailed() async throws {
        let session = OperationSession()
        session.startCreate(
            request(),
            using: FakeCreator(events: [
                .docStatusChanged(.creating),
                .docStatusChanged(.createFailed),
                .finished(.failure(.engine(code: 6, message: "io error"))),
            ]))
        await drain(session)
        #expect(session.docStatus == .createFailed)
        #expect(session.lastError == .engine(code: 6, message: "io error"))
    }

    @Test func launchFailedCreateKeepsCreateFailedStatus() async throws {
        let session = OperationSession()
        session.startCreate(
            request(),
            using: FakeCreator(events: [
                .docStatusChanged(.creating),
                .docStatusChanged(.createFailed),
                .finished(.failure(.launchFailed("no files"))),
            ]))
        await drain(session)
        // The engine's .createFailed is authoritative — not overridden by .notValid.
        #expect(session.docStatus == .createFailed)
    }

    @Test func cancellingCreateRestoresIdleState() async throws {
        let session = OperationSession()
        session.startCreate(
            request(), using: FakeCreator(events: [.docStatusChanged(.creating)]))
        #expect(session.isBusy)
        session.cancel()
        #expect(!session.isBusy)
        #expect(session.docStatus == .cancelled)
    }

    // MARK: - CreateModel

    private func makeFolder(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("createmodel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    @Test func modelAddsFilesAndComputesPreview() throws {
        let dir = try makeFolder(["a.bin", "b.bin"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = CreateModel()
        let added = model.add([
            dir.appendingPathComponent("a.bin"), dir.appendingPathComponent("b.bin"),
        ])
        #expect(Set(added) == ["a.bin", "b.bin"])
        #expect(model.items.count == 2)
        #expect(model.folder?.standardizedFileURL == dir.standardizedFileURL)
        #expect(model.totalBytes == 2)
        #expect(model.canCreate)
        #expect(model.defaultParName == dir.lastPathComponent)
    }

    @Test func modelEnforcesOneFolder() throws {
        let dirA = try makeFolder(["a.bin"])
        let dirB = try makeFolder(["b.bin"])
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let model = CreateModel()
        model.add([dirA.appendingPathComponent("a.bin")])
        let added = model.add([dirB.appendingPathComponent("b.bin")])
        #expect(added.isEmpty, "a file in a different folder must be rejected")
        #expect(model.items.count == 1)
        #expect(model.lastRejection?.contains("one folder") == true)
    }

    @Test func modelExpandsADroppedFolder() throws {
        let dir = try makeFolder(["one.bin", "two.bin", "three.bin"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = CreateModel()
        model.add([dir])  // drop the folder itself
        #expect(model.items.count == 3)
        #expect(model.folder?.standardizedFileURL == dir.standardizedFileURL)
    }

    @Test func modelDeduplicatesAndRemoves() throws {
        let dir = try makeFolder(["a.bin", "b.bin"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = CreateModel()
        let a = dir.appendingPathComponent("a.bin")
        model.add([a])
        model.add([a])  // duplicate
        #expect(model.items.count == 1)
        model.add([dir.appendingPathComponent("b.bin")])
        model.remove([a])
        #expect(model.items.map(\.name) == ["b.bin"])
    }

    @Test func modelValidationGatesCreate() throws {
        let dir = try makeFolder(["a.bin"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = CreateModel()
        #expect(!model.canCreate, "no files → cannot create")
        model.add([dir.appendingPathComponent("a.bin")])
        model.options.redundancyPercent = 0
        #expect(!model.canCreate)
        #expect(model.validationErrors.contains { $0.contains("between 1 and 100") })
        model.options.redundancyPercent = 10
        #expect(model.canCreate)
    }
}
