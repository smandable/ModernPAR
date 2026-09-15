import Foundation
import Testing

@testable import ModernPARCore

/// The build window's handling of empty (0-byte) files: a PAR2 set leaves them out, like the
/// par2 CLI, and the window says so before Create. PAR1 sets keep them.
@MainActor
struct CreateEmptyFileTests {

    private func makeFolder(_ files: [(String, Int)]) throws -> (dir: URL, urls: [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("createempty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (name, size) in files {
            let url = dir.appendingPathComponent(name)
            try Data(count: size).write(to: url)
            urls.append(url)
        }
        return (dir, urls)
    }

    @Test func anEmptyFileIsFlaggedAndNoted() throws {
        let (dir, urls) = try makeFolder([("data.bin", 1000), ("empty.txt", 0)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = CreateModel(kind: .par2)
        model.add(urls)

        #expect(model.skippedEmptyItems.map(\.name) == ["empty.txt"])
        #expect(
            model.emptyFilesNote
                == "“empty.txt” is empty and will be left out — an empty file has no data for a PAR2 set to protect."
        )
        // The file stays listed and the set is still creatable from the rest.
        #expect(model.items.count == 2)
        #expect(model.includedItemCount == 1)
        #expect(model.canCreate)
    }

    @Test func aControlCharacterInANameCannotBreakTheNote() throws {
        // A folder with a custom icon holds an empty "Icon\r" (the icon lives in its resource
        // fork). The note prints control characters the way the engine does.
        let (dir, urls) = try makeFolder([("data.bin", 1000), ("Icon\r", 0)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = CreateModel(kind: .par2)
        model.add(urls)

        #expect(
            model.emptyFilesNote
                == "“Icon%0D” is empty and will be left out — an empty file has no data for a PAR2 set to protect."
        )
    }

    @Test func aSymlinkIsSizedByTheFileItPointsTo() throws {
        // The engine follows symlinks, so a link to an empty file is an empty member — and a
        // link to data is protected at the target's size, not the link's own few bytes.
        let (dir, urls) = try makeFolder([("data.bin", 5000), ("empty.txt", 0)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let links = [
            dir.appendingPathComponent("link-to-data"), dir.appendingPathComponent("link-to-empty"),
        ]
        for (link, target) in zip(links, urls) {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        }
        let model = CreateModel(kind: .par2)
        model.add(links)

        #expect(model.items.first { $0.name == "link-to-data" }?.sizeBytes == 5000)
        #expect(model.skippedEmptyItems.map(\.name) == ["link-to-empty"])
    }

    @Test func severalEmptyFilesShareOneNote() throws {
        let (dir, _) = try makeFolder([
            ("data.bin", 1000), ("e1", 0), ("e2", 0), (".localized", 0),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = CreateModel(kind: .par2)
        model.add([dir])  // a dropped folder, hidden files included

        #expect(model.skippedEmptyItems.count == 3)
        #expect(
            model.emptyFilesNote
                == "3 empty files will be left out — empty files have no data for a PAR2 set to protect."
        )
    }

    @Test func par1SetsKeepEmptyFiles() throws {
        let (dir, urls) = try makeFolder([("data.bin", 1000), ("empty.txt", 0)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = CreateModel(kind: .par1)
        model.add(urls)

        #expect(model.skippedEmptyItems.isEmpty)
        #expect(model.emptyFilesNote == nil)
        #expect(model.items.contains { $0.name == "empty.txt" && $0.isEmpty })
    }

    @Test func anUnreadableFileIsNotMistakenForAnEmptyOne() throws {
        // Its size can't be read; that is not "empty" — the engine reports it at create time.
        let (dir, urls) = try makeFolder([("data.bin", 1000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = CreateModel(kind: .par2)
        model.add(urls + [dir.appendingPathComponent("gone.bin")])

        #expect(model.items.count == 2)
        #expect(model.skippedEmptyItems.isEmpty)
        #expect(model.emptyFilesNote == nil)
    }
}
