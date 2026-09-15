import Foundation
import ModernPARCore

@testable import Par2Kit

/// The "Blocks needed" repro from the 2026-09-15 report, scaled from 1 MB to 4 KB blocks: an
/// 11-volume RAR-style set protected by PAR2, 100 blocks per volume. Built fresh per test in a
/// temporary folder (random data, created by the embedded engine) so tests can damage it freely.
struct DamagedVolumeSet {
    static let blockSize = 4096
    static let blocksPerVolume = 100
    static let volumeNames = (1...11).map { String(format: "movie.part%02d.rar", $0) }

    let folder: URL
    let parFile: URL

    /// An intact set with enough recovery data for every scenario below.
    static func make(recoveryBlocks: UInt32 = 400) throws -> DamagedVolumeSet {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocks-needed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var volumes: [URL] = []
        for name in volumeNames {
            var bytes = [UInt8](repeating: 0, count: blockSize * blocksPerVolume)
            arc4random_buf(&bytes, bytes.count)
            let url = folder.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            volumes.append(url)
        }
        let parFile = folder.appendingPathComponent("movie.par2")
        try Par2Create.createSet(
            parFile: parFile, files: volumes, blockSize: UInt64(blockSize),
            recoveryBlockCount: recoveryBlocks)
        return DamagedVolumeSet(folder: folder, parFile: parFile)
    }

    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    func contents(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    /// The report's damage: part03 deleted (needs all 100 blocks), a 180/1024-block region of
    /// part05 zeroed inside block 40 (needs 1 — par2cmdline: "Found 99 of 100"), part08
    /// truncated by 8.5 blocks (needs 9 — "Found 91 of 100").
    static let reportedDamage = [
        "movie.part03.rar": 100, "movie.part05.rar": 1, "movie.part08.rar": 9,
    ]

    func applyReportedDamage() throws {
        try FileManager.default.removeItem(at: url("movie.part03.rar"))
        let zeroed = url("movie.part05.rar")
        var data = try Data(contentsOf: zeroed)
        let start = Self.blockSize * 40 + 250
        data.replaceSubrange(
            start..<start + Self.blockSize * 180 / 1024,
            with: Data(count: Self.blockSize * 180 / 1024))
        try data.write(to: zeroed)
        let truncated = try FileHandle(forWritingTo: url("movie.part08.rar"))
        try truncated.truncate(
            atOffset: UInt64(Self.blockSize * Self.blocksPerVolume - Self.blockSize * 17 / 2))
        try truncated.close()
    }

    /// Damage whose blocks live in OTHER files (par2repairer.cpp's "… data blocks from" lines):
    /// part06 is gone but a partial copy under another name holds its first 60 blocks (needs
    /// 40); part07 is gone and part09's file now holds part07's first 50 blocks (part07 needs
    /// 50; part09 holds none of its own, needs 100); part10 is zero-filled, which the engine
    /// reports as `File: "…" - no data found.` rather than a Target line (needs 100).
    static let foreignDamage = [
        "movie.part06.rar": 40, "movie.part07.rar": 50, "movie.part09.rar": 100,
        "movie.part10.rar": 100,
    ]

    func applyForeignDamage() throws {
        let part06 = try contents("movie.part06.rar")
        try part06.prefix(Self.blockSize * 60).write(to: url("movie.part06.rar.partial"))
        try FileManager.default.removeItem(at: url("movie.part06.rar"))
        let part07 = try contents("movie.part07.rar")
        try FileManager.default.removeItem(at: url("movie.part07.rar"))
        try part07.prefix(Self.blockSize * 50).write(to: url("movie.part09.rar"))
        try Data(count: Self.blockSize * Self.blocksPerVolume).write(to: url("movie.part10.rar"))
    }

    /// What an interrupted repair leaves (review repro, 2026-09-15): the engine had moved the
    /// damaged part04 aside as `part04.rar.1` (10 blocks bad) and rewritten only the first 40
    /// blocks of a fresh part04. The engine counts blocks 0–39 in both files, so the naive sum
    /// (40 + 90) says nothing is needed; the truth is 10.
    static let interruptedRepair = ["movie.part04.rar": 10]

    func applyInterruptedRepairShape() throws {
        let original = try contents("movie.part04.rar")
        var backup = original
        let bad = Self.blockSize * 60..<Self.blockSize * 70
        backup.replaceSubrange(bad, with: Data(repeating: 0xA5, count: bad.count))
        try backup.write(to: url("movie.part04.rar.1"))
        var rewritten = Data(original.prefix(Self.blockSize * 40))
        rewritten.append(Data(count: original.count - rewritten.count))
        try rewritten.write(to: url("movie.part04.rar"))
    }

    /// Row ids by file name — the ids every engine event carries (native parser File IDs).
    func rowIDs() throws -> [String: UUID] {
        let set = try Par2Parser.loadSet(anchor: parFile)
        return Dictionary(
            uniqueKeysWithValues: set.descriptions.values.map { ($0.preferredName, $0.fileID.uuid) }
        )
    }

    /// Final blocks-needed count per file name from an event stream.
    func blocksNeeded(in events: [EngineEvent]) throws -> [String: Int] {
        let names = Dictionary(uniqueKeysWithValues: try rowIDs().map { ($1, $0) })
        var counts: [String: Int] = [:]
        for case .fileBlocksNeeded(let id, let blocks) in events {
            counts[names[id] ?? id.uuidString] = blocks
        }
        return counts
    }

    /// The engine's own set-level shortfall: S − A from "You have A out of S data blocks
    /// available." — the per-file counts must add up to it.
    static func missingDataBlocks(in events: [EngineEvent]) -> Int? {
        for case .logLine(let line) in events where line.hasPrefix("You have ") {
            let words = line.split(separator: " ")
            guard line.hasSuffix(" data blocks available."), words.count > 5,
                let available = Int(words[2]), let total = Int(words[5])
            else { continue }
            return total - available
        }
        return nil
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}
