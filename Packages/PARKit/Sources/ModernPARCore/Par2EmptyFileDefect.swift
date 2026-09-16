import Foundation

/// A recovery set whose recorded checksums are shifted out of step by an empty member — the
/// defect ModernPAR 1.0.1 and earlier wrote into every PAR2 set whose file list included a
/// 0-byte file.
///
/// libpar2's creator walks its source files and its block iterator in lockstep, but a 0-byte
/// file owns no blocks. Every member sorting after one therefore had its slice checksums and
/// its File Description's whole-file MD5 written one block late, and the slots at the end of
/// the last member were never written at all. The result reports intact data as damaged, and
/// repairing against it renames the intact originals to `name.1` and writes shifted copies in
/// their place before ending "Repair Failed." — so a flagged set is never repaired
/// automatically, and the app offers to re-make it instead.
///
/// Creation was fixed by turbo patch 6 (`Par2Cxx/vendor/VENDORED.txt`), and `EmbeddedCreate`
/// now leaves empty files out the way the par2 CLI does. Neither helps a set that already
/// exists on disk, which is why the read-only parser recognizes one.
public struct Par2EmptyFileDefect: Sendable, Equatable {
    /// The 0-byte members that pushed the checksums out of step, in Main-packet order.
    public let emptyMemberNames: [String]
    /// The members whose recorded checksums are shifted — every non-empty member sorting
    /// after an empty one, in Main-packet order. Members before the first empty one were
    /// written correctly and still verify.
    public let shiftedMemberNames: [String]
    /// Trailing all-zero slice-checksum entries on the last non-empty member: the slots the
    /// creator ran out of blocks to fill. One per preceding empty member, capped by the
    /// member's own block count.
    public let unwrittenSliceCount: Int

    public init(
        emptyMemberNames: [String], shiftedMemberNames: [String], unwrittenSliceCount: Int
    ) {
        self.emptyMemberNames = emptyMemberNames
        self.shiftedMemberNames = shiftedMemberNames
        self.unwrittenSliceCount = unwrittenSliceCount
    }

    /// What to tell the user. The set itself cannot be salvaged — only made again.
    public var explanation: String {
        "This recovery set was made by ModernPAR 1.0.1 or earlier, which recorded wrong checksums when a set included an empty file. Your files are most likely intact — make the set again."
    }

    /// The supporting detail for the log pane: which member broke the set and what it cost.
    public var detail: String {
        let empties = Self.list(emptyMemberNames)
        let shifted = Self.list(shiftedMemberNames)
        let subject = emptyMemberNames.count == 1 ? "The empty file" : "The empty files"
        let verb = emptyMemberNames.count == 1 ? "was" : "were"
        return
            "\(subject) \(empties) \(verb) recorded with no data, which shifted the stored checksums of \(shifted) by one block each. Verifying will report those files as damaged even when they are byte-for-byte correct, and repairing would overwrite them."
    }

    private static func list(_ names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }
        switch quoted.count {
        case 0: return "no files"
        case 1: return quoted[0]
        case 2: return "\(quoted[0]) and \(quoted[1])"
        default:
            return quoted.dropLast().joined(separator: ", ") + ", and \(quoted[quoted.count - 1])"
        }
    }
}

extension Par2RecoverySet {
    /// Recognizes the empty-file checksum defect, or nil when the set is sound.
    ///
    /// The signature, pinned empirically against sets built by the pre-fix engine:
    ///
    /// 1. a 0-byte member comes before a non-empty one in **Main-packet order** — the order
    ///    the creator iterated. An empty member sorting after every non-empty one shifts
    ///    nothing and produces a perfectly good set, so order is not optional here; and
    /// 2. the last non-empty member's slice-checksum list ends in at least one all-zero
    ///    entry (MD5 all zeros *and* CRC 0), one per preceding empty member but never more
    ///    than the member has blocks. Those are the slots the creator never wrote.
    ///
    /// Requirement 2 is what keeps this free of false positives. A real slice can never hash
    /// to an all-zero MD5, and a set written on the engine's multi-pass path (blocks over
    /// 32 MiB) carries correct checksums and no zero entries even with an empty member. The
    /// Creator packet of every affected set reads "par2cmdline-turbo version 1.4.0", but
    /// matching on it would go stale at the next engine bump while the defect did not, and a
    /// set carrying zero entries is unusable whoever wrote it.
    ///
    /// A member whose File Description did not survive is skipped rather than guessed at: its
    /// length is unknown, so it can neither prove nor disprove the defect. That can only cost
    /// a detection, never invent one.
    public var emptyFileDefect: Par2EmptyFileDefect? {
        var emptyNames: [String] = []
        var shiftedNames: [String] = []
        var emptiesSoFar = 0
        var lastData: (id: MD5Digest, precedingEmpties: Int)?

        for id in recoveryFileIDs {
            guard let description = descriptions[id] else { continue }
            if description.length == 0 {
                emptyNames.append(description.preferredName)
                emptiesSoFar += 1
            } else {
                if emptiesSoFar > 0 { shiftedNames.append(description.preferredName) }
                lastData = (id, emptiesSoFar)
            }
        }

        guard let lastData, lastData.precedingEmpties > 0,
            let entries = sliceChecksums[lastData.id]
        else { return nil }
        let unwritten = entries.reversed().prefix(while: \.isUnwritten).count
        guard unwritten > 0, unwritten <= lastData.precedingEmpties else { return nil }

        return Par2EmptyFileDefect(
            emptyMemberNames: emptyNames,
            shiftedMemberNames: shiftedNames,
            unwrittenSliceCount: unwritten)
    }
}

extension Par2SliceChecksum {
    /// An entry the creator never filled in. No real slice hashes to an all-zero MD5, so this
    /// only ever matches a slot that was left as the zeroed packet body.
    var isUnwritten: Bool { crc32 == 0 && md5.bytes.allSatisfy { $0 == 0 } }
}
