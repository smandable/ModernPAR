import Foundation

/// Pure-Swift, read-only PAR2 packet parser. (ARCHITECTURE.md §1.3; docs/research/03 §2–§3;
/// spec: https://parchive.sourceforge.net/docs/specifications/parity-volume-spec/article-spec.html)
///
/// Reading PAR2 has no compatibility trap — only writing/repair does — so this layer powers the
/// whole document UI natively: scan for the packet magic, validate each packet's MD5, decode the
/// metadata packets, silently skip anything unrecognized or corrupt.
public enum Par2Parser {

    public enum ParseError: Error, Equatable {
        /// The file contained no packet that validated.
        case noValidPackets
        /// Packets validated but no Main packet was found, so no set can be assembled.
        case noMainPacket
    }

    // MARK: - Wire constants

    /// `PAR2\0PKT`
    static let packetMagic = Data([0x50, 0x41, 0x52, 0x32, 0x00, 0x50, 0x4B, 0x54])
    static let headerLength = 64

    /// 16-byte ASCII packet type tags, null-padded. (03 §2.2)
    enum PacketType {
        static let main = Data("PAR 2.0\0Main\0\0\0\0".utf8)
        static let fileDescription = Data("PAR 2.0\0FileDesc".utf8)
        static let inputFileSliceChecksum = Data("PAR 2.0\0IFSC\0\0\0\0".utf8)
        static let recoverySlice = Data("PAR 2.0\0RecvSlic".utf8)
        static let creator = Data("PAR 2.0\0Creator\0".utf8)
        static let unicodeFilename = Data("PAR 2.0\0UniFileN".utf8)
        static let asciiComment = Data("PAR 2.0\0CommASCI".utf8)
        static let unicodeComment = Data("PAR 2.0\0CommUni\0".utf8)
    }

    // MARK: - Single-file scan

    /// One validated packet. The body is copied out for metadata packets; for Recovery Slice
    /// packets only the 4-byte exponent is retained (the slice data itself is repair-phase work)
    /// while `bodyLength` records the true on-disk body size for validation.
    struct Packet {
        let setID: MD5Digest
        let packetMD5: MD5Digest
        let type: Data
        let body: Data
        let bodyLength: Int
    }

    struct ScanResult {
        var packets: [Packet] = []
        var corruptCandidates = 0
    }

    /// Scans raw bytes for valid packets: find the magic, read the self-described length,
    /// recompute MD5 over `[32, length)`, keep the packet if it matches, otherwise resume the
    /// search one byte past the magic (garbage may sit between packets). (03 §2.1)
    static func scan(_ data: Data) -> ScanResult {
        var result = ScanResult()
        var searchFrom = 0
        let total = data.count

        while searchFrom + headerLength <= total {
            guard
                let magicRange = data.firstRange(
                    of: packetMagic, in: (data.startIndex + searchFrom)..<data.endIndex)
            else { break }
            let offset = magicRange.lowerBound - data.startIndex
            guard offset + headerLength <= total else { break }

            guard let length64 = data.leUInt64(at: offset + 8),
                length64 >= UInt64(headerLength),
                length64 % 4 == 0,
                length64 <= UInt64(total - offset)
            else {
                result.corruptCandidates += 1
                searchFrom = offset + 1
                continue
            }
            let length = Int(length64)

            // Packet MD5 covers offset 32 (Recovery Set ID) through the end of the body —
            // not the magic, length, or the MD5 field itself. (03 §2.1)
            guard let hashed = data.hashSlice(at: offset + 32, count: length - 32),
                let stored = data.field(at: offset + 16, count: 16).flatMap(MD5Digest.init),
                MD5Digest.hash(hashed) == stored
            else {
                result.corruptCandidates += 1
                searchFrom = offset + 1
                continue
            }

            guard let setID = data.field(at: offset + 32, count: 16).flatMap(MD5Digest.init),
                let type = data.field(at: offset + 48, count: 16)
            else {
                result.corruptCandidates += 1
                searchFrom = offset + 1
                continue
            }

            let body: Data
            if type == PacketType.recoverySlice {
                // Keep just the exponent; recovery data can be huge and is not parse-phase work.
                body = data.field(at: offset + 64, count: min(4, length - 64)) ?? Data()
            } else {
                body = data.field(at: offset + 64, count: length - 64) ?? Data()
            }
            result.packets.append(
                Packet(
                    setID: setID, packetMD5: stored, type: type, body: body,
                    bodyLength: length - 64))
            searchFrom = offset + length
        }
        return result
    }

    // MARK: - Set assembly

    /// Parses the anchor `.par2` and every sibling `*.par2` in the same folder, then assembles
    /// the recovery set the anchor belongs to. Sibling enumeration failing (e.g. sandbox grants
    /// only the single file) degrades gracefully to the anchor alone.
    public static func loadSet(anchor: URL) throws -> Par2RecoverySet {
        var urls = [anchor]
        let folder = anchor.deletingLastPathComponent()
        if let siblings = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)
        {
            let others = siblings.filter {
                $0.pathExtension.lowercased() == "par2"
                    && $0.standardizedFileURL != anchor.standardizedFileURL
            }
            urls.append(contentsOf: others.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
        return try assembleSet(from: urls)
    }

    /// Assembles one recovery set from the given `.par2` files. The set is chosen by a
    /// **decodable** Main packet, preferring one whose Recovery Set ID matches packets seen in
    /// the FIRST file (the anchor) — so a foreign set sitting in the same folder can never
    /// hijack assembly, and a corrupt anchor Main is still recovered from volume copies.
    /// Packets carrying a different Recovery Set ID are ignored; metadata packets duplicated
    /// across volumes are deduplicated by their packet MD5. (03 §1, §3.1)
    public static func assembleSet(from urls: [URL]) throws -> Par2RecoverySet {
        var fileScans: [(url: URL, packets: [Packet])] = []
        var corrupt = 0
        var seenPacketMD5s = Set<MD5Digest>()

        for url in urls {
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            let scan = Self.scan(data)
            corrupt += scan.corruptCandidates
            var kept: [Packet] = []
            for packet in scan.packets {
                // Recovery slices repeat exponents, not packet content; everything else is
                // dedup-able by packet MD5 (identical copies across volume files).
                if packet.type != PacketType.recoverySlice {
                    guard seenPacketMD5s.insert(packet.packetMD5).inserted else { continue }
                }
                kept.append(packet)
            }
            fileScans.append((url, kept))
        }

        let packets = fileScans.flatMap(\.packets)
        guard !packets.isEmpty else { throw ParseError.noValidPackets }

        // Candidate Mains must decode (an MD5-valid but semantically broken Main must not
        // abort assembly when a good copy exists in another file).
        let decodableMains: [(packet: Packet, main: MainBody)] =
            packets
            .filter { $0.type == PacketType.main }
            .compactMap { p in decodeMain(p.body).map { (p, $0) } }
        let anchorSetIDs = Set(fileScans.first?.packets.map(\.setID) ?? [])
        guard
            let chosen = decodableMains.first(where: { anchorSetIDs.contains($0.packet.setID) })
                ?? decodableMains.first
        else { throw ParseError.noMainPacket }

        let mainPacket = chosen.packet
        let main = chosen.main
        let setID = mainPacket.setID
        let setPackets = packets.filter { $0.setID == setID }
        let contributing = fileScans.filter { scan in
            scan.packets.contains { $0.setID == setID }
        }.map(\.url)

        var descriptions: [MD5Digest: Par2FileDescription] = [:]
        var checksums: [MD5Digest: [Par2SliceChecksum]] = [:]
        var exponents: Set<UInt32> = []
        var creator: String?
        var asciiComment: String?
        var unicodeComment: String?
        // Unicode Filename packets that arrive before their File Description (any order is legal).
        var pendingUnicodeNames: [MD5Digest: String] = [:]

        for packet in setPackets {
            switch packet.type {
            case PacketType.fileDescription:
                if let d = decodeFileDescription(packet.body) {
                    descriptions[d.fileID] = merge(existing: descriptions[d.fileID], with: d)
                }
            case PacketType.inputFileSliceChecksum:
                if let (fileID, entries) = decodeIFSC(packet.body) {
                    checksums[fileID] = entries
                }
            case PacketType.recoverySlice:
                // Count a recovery block only if the packet is shaped like one: a 4-byte
                // exponent in the GF(2¹⁶) range plus exactly one slice of data. (03 §2.6)
                if let exponent = packet.body.leUInt32(at: 0),
                    exponent <= 65535,
                    packet.bodyLength >= 4,
                    UInt64(packet.bodyLength - 4) == main.sliceSize
                {
                    exponents.insert(exponent)
                }
            case PacketType.creator:
                creator = decodePaddedASCII(packet.body)
            case PacketType.asciiComment:
                if asciiComment == nil { asciiComment = decodePaddedASCII(packet.body) }
            case PacketType.unicodeComment:
                // Body: 16-byte MD5-of-ASCII-comment (or zeros) ‖ UTF-16LE text. (03 §2.7)
                if unicodeComment == nil, packet.body.count > 16,
                    let (_, text) = decodeUnicodeFilename(packet.body)
                {
                    unicodeComment = text
                }
            case PacketType.unicodeFilename:
                if let (fileID, name) = decodeUnicodeFilename(packet.body) {
                    if var d = descriptions[fileID] {
                        d.unicodeName = name
                        descriptions[fileID] = d
                    } else {
                        // Companion arrived before its File Description; retry below.
                        pendingUnicodeNames[fileID] = name
                    }
                }
            default:
                break  // Unrecognized packet types are silently ignored (forward compat).
            }
        }
        // Late-binding for Unicode names that preceded their File Description packet.
        for (fileID, name) in pendingUnicodeNames {
            if var d = descriptions[fileID], d.unicodeName == nil {
                d.unicodeName = name
                descriptions[fileID] = d
            }
        }

        return Par2RecoverySet(
            setID: setID,
            setIDVerified: MD5Digest.hash(mainPacket.body) == setID,
            sliceSize: main.sliceSize,
            recoveryFileIDs: main.recoveryFileIDs,
            nonRecoveryFileIDs: main.nonRecoveryFileIDs,
            descriptions: descriptions,
            sliceChecksums: checksums,
            recoveryExponents: exponents,
            creator: creator,
            comment: unicodeComment ?? asciiComment,
            sourceFiles: contributing,
            corruptPacketCount: corrupt
        )
    }

    // MARK: - Packet body decoding

    private struct MainBody {
        let sliceSize: UInt64
        let recoveryFileIDs: [MD5Digest]
        let nonRecoveryFileIDs: [MD5Digest]
    }

    /// Main body: slice size (8) ‖ recovery-set count (4) ‖ recovery File IDs (16×N, sorted)
    /// ‖ non-recovery File IDs (16×M, sorted). (03 §2.3)
    private static func decodeMain(_ body: Data) -> MainBody? {
        guard let sliceSize = body.leUInt64(at: 0), sliceSize > 0, sliceSize % 4 == 0,
            let count = body.leUInt32(at: 8)
        else { return nil }
        let n = Int(count)
        let idsStart = 12
        guard body.count >= idsStart + 16 * n, (body.count - idsStart) % 16 == 0 else {
            return nil
        }
        let m = (body.count - idsStart - 16 * n) / 16
        func ids(at start: Int, count: Int) -> [MD5Digest]? {
            var out: [MD5Digest] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                guard let id = body.field(at: start + 16 * i, count: 16).flatMap(MD5Digest.init)
                else { return nil }
                out.append(id)
            }
            return out
        }
        guard let recovery = ids(at: idsStart, count: n),
            let nonRecovery = ids(at: idsStart + 16 * n, count: m)
        else { return nil }
        return MainBody(
            sliceSize: sliceSize, recoveryFileIDs: recovery, nonRecoveryFileIDs: nonRecovery)
    }

    /// FileDesc body: File ID (16) ‖ file MD5 (16) ‖ MD5-16k (16) ‖ length (8) ‖ ASCII name
    /// (zero-padded to ×4). File ID must equal MD5(MD5-16k ‖ length ‖ name). (03 §2.4, §3.2)
    private static func decodeFileDescription(_ body: Data) -> Par2FileDescription? {
        guard body.count > 56,
            let fileID = body.field(at: 0, count: 16).flatMap(MD5Digest.init),
            let fileMD5 = body.field(at: 16, count: 16).flatMap(MD5Digest.init),
            let md5of16k = body.field(at: 32, count: 16).flatMap(MD5Digest.init),
            let length = body.leUInt64(at: 48),
            let paddedName = body.field(at: 56, count: body.count - 56)
        else { return nil }
        let nameBytes = trimTrailingZeros(paddedName)
        guard !nameBytes.isEmpty else { return nil }
        let name =
            String(data: nameBytes, encoding: .utf8)
            ?? String(data: nameBytes, encoding: .isoLatin1)
            ?? "<undecodable name>"

        var lengthLE = Data(count: 8)
        for i in 0..<8 { lengthLE[i] = UInt8(truncatingIfNeeded: length >> (8 * UInt64(i))) }
        let computedID = MD5Digest.hash(parts: [md5of16k.bytes, lengthLE, nameBytes])

        return Par2FileDescription(
            fileID: fileID,
            fileMD5: fileMD5,
            md5of16k: md5of16k,
            length: length,
            asciiName: name,
            unicodeName: nil,
            fileIDVerified: computedID == fileID
        )
    }

    /// IFSC body: File ID (16) ‖ K × (slice MD5 (16) ‖ slice CRC32 (4)), in slice order. (03 §2.5)
    private static func decodeIFSC(_ body: Data) -> (MD5Digest, [Par2SliceChecksum])? {
        guard body.count >= 16 + 20, (body.count - 16) % 20 == 0,
            let fileID = body.field(at: 0, count: 16).flatMap(MD5Digest.init)
        else { return nil }
        let k = (body.count - 16) / 20
        var entries: [Par2SliceChecksum] = []
        entries.reserveCapacity(k)
        for i in 0..<k {
            let base = 16 + 20 * i
            guard let md5 = body.field(at: base, count: 16).flatMap(MD5Digest.init),
                let crc = body.leUInt32(at: base + 16)
            else { return nil }
            entries.append(Par2SliceChecksum(md5: md5, crc32: crc))
        }
        return (fileID, entries)
    }

    /// Unicode Filename body: File ID (16) ‖ UTF-16LE name (zero-padded to ×4). (03 §2.7)
    private static func decodeUnicodeFilename(_ body: Data) -> (MD5Digest, String)? {
        guard body.count > 16,
            let fileID = body.field(at: 0, count: 16).flatMap(MD5Digest.init),
            let raw = body.field(at: 16, count: body.count - 16)
        else { return nil }
        var nameBytes = trimTrailingZeros(raw)
        if nameBytes.count % 2 == 1 { nameBytes.append(0) }  // re-align UTF-16 code units
        guard let name = String(data: nameBytes, encoding: .utf16LittleEndian), !name.isEmpty
        else { return nil }
        return (fileID, name)
    }

    private static func decodePaddedASCII(_ body: Data) -> String? {
        let trimmed = trimTrailingZeros(body)
        guard !trimmed.isEmpty else { return nil }
        return String(data: trimmed, encoding: .utf8)
            ?? String(data: trimmed, encoding: .isoLatin1)
    }

    private static func trimTrailingZeros(_ data: Data) -> Data {
        var end = data.count
        let base = data.startIndex
        while end > 0, data[base + end - 1] == 0 { end -= 1 }
        return Data(data[base..<(base + end)])
    }

    /// Keeps a Unicode name only when the existing description lacks one (packets arrive in any
    /// order and duplicates are possible).
    private static func merge(existing: Par2FileDescription?, with new: Par2FileDescription)
        -> Par2FileDescription
    {
        guard var merged = existing else { return new }
        if merged.unicodeName == nil { merged.unicodeName = new.unicodeName }
        return merged
    }
}
