import CryptoKit
import Foundation

/// A 16-byte MD5 value as used throughout PAR1/PAR2: packet integrity, set IDs, File IDs, and
/// per-slice checksums. MD5 is used here as a fast non-cryptographic fingerprint — the formats
/// mandate it. (docs/research/03 §3)
public struct MD5Digest: Hashable, Sendable, CustomStringConvertible {
    /// Exactly 16 bytes, re-based so indexing always starts at 0.
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 16 else { return nil }
        self.bytes = Data(bytes)
    }

    public static func hash(_ data: Data) -> MD5Digest {
        MD5Digest(bytes: Data(Insecure.MD5.hash(data: data)))!
    }

    /// Incremental hashing for multi-part inputs (e.g. File ID = MD5(16k-hash ‖ length ‖ name)).
    public static func hash(parts: [Data]) -> MD5Digest {
        var hasher = Insecure.MD5()
        for part in parts { hasher.update(data: part) }
        return MD5Digest(bytes: Data(hasher.finalize()))!
    }

    /// The digest reinterpreted as a UUID — handy because a PAR2 File ID is exactly 16 bytes and
    /// `FileEntry.id` is a `UUID`.
    public var uuid: UUID {
        let b = [UInt8](bytes)
        return UUID(
            uuid: (
                b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
            ))
    }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    /// Bounds-checked little-endian UInt32 at `offset` relative to this value's first byte.
    func leUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, count - offset >= 4 else { return nil }
        let base = startIndex + offset
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(self[base + i]) << (8 * i) }
        return value
    }

    /// Bounds-checked little-endian UInt64 at `offset` relative to this value's first byte.
    func leUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, count - offset >= 8 else { return nil }
        let base = startIndex + offset
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(self[base + i]) << (8 * i) }
        return value
    }

    /// Bounds-checked sub-slice by offsets relative to this value's first byte. The result is
    /// re-based to index 0 so downstream code never trips over Data's index-preserving slices.
    func field(at offset: Int, count length: Int) -> Data? {
        guard offset >= 0, length >= 0, self.count - offset >= length else { return nil }
        let base = startIndex + offset
        return Data(self[base..<(base + length)])
    }

    /// A zero-copy slice for hashing (indices preserved — do not subscript with raw ints).
    func hashSlice(at offset: Int, count length: Int) -> Data? {
        guard offset >= 0, length >= 0, self.count - offset >= length else { return nil }
        let base = startIndex + offset
        return self[base..<(base + length)]
    }
}
