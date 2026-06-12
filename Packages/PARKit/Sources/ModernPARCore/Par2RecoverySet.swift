import Foundation

/// Everything the read-only parser learned about one PAR2 recovery set, assembled from the
/// packets of one or more `.par2` files. Immutable; powers the document UI with zero engine
/// involvement. (ARCHITECTURE.md §1.3; docs/research/03 §2–§4)
public struct Par2RecoverySet: Sendable {
    /// Recovery Set ID = MD5 of the Main packet body. Groups packets across files.
    public let setID: MD5Digest
    /// True when MD5(Main body) reproduced the set ID carried in the packet headers.
    public let setIDVerified: Bool
    /// Slice (block) size in bytes; a multiple of 4. (03 §2.3)
    public let sliceSize: UInt64
    /// File IDs in the recovery set, in **canonical order** (fixes the RS constant assignment).
    public let recoveryFileIDs: [MD5Digest]
    /// Files described but not protected by recovery data.
    public let nonRecoveryFileIDs: [MD5Digest]
    public let descriptions: [MD5Digest: Par2FileDescription]
    /// Per-slice MD5+CRC32 checksum lists, keyed by File ID, in slice order. (03 §2.5)
    public let sliceChecksums: [MD5Digest: [Par2SliceChecksum]]
    /// Distinct recovery-slice exponents seen across all scanned files. Count = usable
    /// recovery blocks (duplicate exponents in different volumes are the same block).
    public let recoveryExponents: Set<UInt32>
    /// Client identification string from the Creator packet, if present.
    public let creator: String?
    /// Set comment from an ASCII/Unicode Comment packet, if present (Unicode preferred).
    public let comment: String?
    /// The `.par2` files that contributed at least one packet **of this set**.
    public let sourceFiles: [URL]
    /// Candidate packets dropped because their MD5 did not validate (corruption tolerance).
    public let corruptPacketCount: Int

    // MARK: Derived display facts (03 §4; ROADMAP Phase 1)

    /// Recovery-set File IDs whose File Description packet never survived — their names, sizes,
    /// and block counts are unknown, so every total below is a lower bound when this is
    /// non-empty. Surfaced in the UI rather than silently dropped.
    public var missingDescriptionIDs: [MD5Digest] {
        recoveryFileIDs.filter { descriptions[$0] == nil }
    }

    /// `ceil(size / sliceSize)` summed over recovery-set files; ≤ 32 768 in a valid set.
    /// Saturating: lengths are untrusted input.
    public var sourceBlockCount: Int {
        recoveryFileIDs.reduce(0) { sum, id in
            guard let d = descriptions[id] else { return sum }
            let blocks = RecoveryMath.sourceBlocks(fileSize: d.length, sliceSize: sliceSize)
            let (next, overflow) = sum.addingReportingOverflow(blocks)
            return overflow ? Int.max : next
        }
    }

    public var recoveryBlockCount: Int { recoveryExponents.count }

    /// Total bytes across recovery-set files. Saturating: lengths are untrusted input.
    public var totalDataBytes: UInt64 {
        recoveryFileIDs.reduce(UInt64(0)) { sum, id in
            let (next, overflow) = sum.addingReportingOverflow(descriptions[id]?.length ?? 0)
            return overflow ? UInt64.max : next
        }
    }

    public var redundancyPercent: Double {
        RecoveryMath.redundancyPercent(
            sourceBlocks: sourceBlockCount, recoveryBlocks: recoveryBlockCount)
    }
}

/// Decoded File Description packet (+ optional Unicode-filename companion). (03 §2.4, §2.7)
public struct Par2FileDescription: Sendable, Equatable {
    public let fileID: MD5Digest
    /// MD5 of the entire file — the final "is this file correct?" check.
    public let fileMD5: MD5Digest
    /// MD5 of the first 16 KiB (whole file if shorter); also an input to the File ID.
    public let md5of16k: MD5Digest
    public let length: UInt64
    /// Filename from the (mandatory) ASCII field — in practice tools store UTF-8 here.
    public let asciiName: String
    /// UTF-16 name from a Unicode Filename packet, when one was present.
    public var unicodeName: String?
    /// True when MD5(md5of16k ‖ length ‖ name bytes) reproduced the stored File ID. (03 §3.2)
    public let fileIDVerified: Bool

    /// The name to display: Unicode companion wins over the ASCII field.
    public var preferredName: String { unicodeName ?? asciiName }
}

/// One IFSC entry: 16-byte MD5 then 4-byte CRC32 of the zero-padded slice. (03 §2.5)
public struct Par2SliceChecksum: Sendable, Equatable {
    public let md5: MD5Digest
    public let crc32: UInt32

    public init(md5: MD5Digest, crc32: UInt32) {
        self.md5 = md5
        self.crc32 = crc32
    }
}

/// Pure helper math shared by the parser, the status model, and (later) the engines.
/// All inputs are untrusted (they come from packet bodies), so nothing here may trap.
public enum RecoveryMath {
    /// Each file contributes `ceil(size / sliceSize)` source blocks; the last is zero-padded.
    /// Computed division-first — `fileSize + sliceSize - 1` would overflow on hostile lengths.
    public static func sourceBlocks(fileSize: UInt64, sliceSize: UInt64) -> Int {
        guard sliceSize > 0, fileSize > 0 else { return 0 }
        let blocks = fileSize / sliceSize + (fileSize % sliceSize == 0 ? 0 : 1)
        return Int(clamping: blocks)
    }

    /// The "need N more blocks" report: how many recovery blocks are still missing to cover
    /// the damage. ≤ 0 means repair is possible. (ROADMAP Phase 1/3)
    public static func additionalBlocksNeeded(
        missingSourceBlocks: Int, availableRecoveryBlocks: Int
    )
        -> Int
    {
        max(0, missingSourceBlocks - availableRecoveryBlocks)
    }

    public static func redundancyPercent(sourceBlocks: Int, recoveryBlocks: Int) -> Double {
        guard sourceBlocks > 0 else { return 0 }
        return Double(recoveryBlocks) / Double(sourceBlocks) * 100
    }

    // MARK: - Create-side math (ROADMAP Phase 6)

    /// Total source blocks across a file set at a given block size (each file rounds up
    /// independently; the last block is zero-padded — this is NOT `ceil(total/blockSize)`).
    public static func sourceBlockCount(fileSizes: [UInt64], blockSize: UInt64) -> Int {
        guard blockSize > 0 else { return 0 }
        return fileSizes.reduce(0) { $0 + sourceBlocks(fileSize: $1, sliceSize: blockSize) }
    }

    /// Recovery blocks for a redundancy percentage (rounded; at least 1 when any redundancy is
    /// requested over a non-empty set), clamped to PAR2's 65535 ceiling.
    public static func recoveryBlockCount(sourceBlocks: Int, redundancyPercent: Int) -> Int {
        guard sourceBlocks > 0, redundancyPercent > 0 else { return 0 }
        let raw = (Double(sourceBlocks) * Double(redundancyPercent) / 100).rounded()
        return min(65_535, max(1, Int(raw)))
    }

    /// An automatic block size (positive multiple of 4) targeting ~2000 source blocks — the
    /// sweet spot par2 tools aim for: enough granularity to repair, not so many packets that
    /// overhead dominates. Tiny sets floor at 4.
    public static func automaticBlockSize(totalBytes: UInt64) -> UInt64 {
        guard totalBytes > 0 else { return 4 }
        let target: UInt64 = 2000
        let raw = max(4, totalBytes / target)
        return roundUpToMultipleOfFour(raw)
    }

    /// Raises `preferred` (rounded to a multiple of 4) until the source block count fits
    /// `maxSourceBlocks` — PAR2 cannot represent more than 32768 source blocks. Doubles the
    /// candidate each step, which converges in a handful of iterations even for huge sets.
    public static func blockSizeFitting(
        fileSizes: [UInt64], preferred: UInt64, maxSourceBlocks: Int
    ) -> UInt64 {
        var size = max(4, roundUpToMultipleOfFour(preferred))
        // Guard against pathological loops: block size can't exceed the largest file.
        let ceiling = roundUpToMultipleOfFour(max(4, fileSizes.max() ?? 4))
        while sourceBlockCount(fileSizes: fileSizes, blockSize: size) > maxSourceBlocks
            && size < ceiling
        {
            size = roundUpToMultipleOfFour(size &* 2)
        }
        return size
    }

    private static func roundUpToMultipleOfFour(_ value: UInt64) -> UInt64 {
        guard value > 0 else { return 4 }
        let (sum, overflow) = value.addingReportingOverflow(3)
        return overflow ? (UInt64.max / 4 * 4) : (sum / 4 * 4)
    }
}

extension ParSet {
    /// Bridge the detailed parse result into the UI-facing document model. File IDs become the
    /// stable row ids (a PAR2 File ID is exactly 16 bytes — a UUID). Hostile Mains can repeat a
    /// File ID, so duplicates are skipped (row ids must stay unique); files whose File
    /// Description never survived still get a placeholder row instead of vanishing.
    public init(par2 set: Par2RecoverySet) {
        var entries: [FileEntry] = []
        var seenIDs = Set<MD5Digest>()
        entries.reserveCapacity(set.recoveryFileIDs.count + set.nonRecoveryFileIDs.count)
        for (ids, inSetStatus) in [
            (set.recoveryFileIDs, FileStatus.pending),
            (set.nonRecoveryFileIDs, FileStatus.notInSet),
        ] {
            for id in ids {
                guard seenIDs.insert(id).inserted else { continue }
                if let d = set.descriptions[id] {
                    entries.append(
                        FileEntry(
                            id: id.uuid, name: d.preferredName, sizeBytes: d.length,
                            status: inSetStatus))
                } else {
                    entries.append(
                        FileEntry(
                            id: id.uuid,
                            name: "Unknown file ⟨\(String(id.description.prefix(8)))…⟩",
                            sizeBytes: 0,
                            status: .possibleError))
                }
            }
        }
        self.init(
            kind: .par2,
            sliceSizeBytes: set.sliceSize,
            sourceBlockCount: set.sourceBlockCount,
            recoveryBlocksAvailable: set.recoveryBlockCount,
            files: entries
        )
    }
}
