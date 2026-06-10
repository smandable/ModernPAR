import Foundation

/// Pure-Swift, read-only PAR1 reader for `.par` index files and `.pXX` parity volumes.
/// Read/inspect only — PAR1 recovery is Phase 8. (ARCHITECTURE.md §1.2; docs/research/03 §6;
/// spec: https://parchive.sourceforge.net/docs/specifications/parity-volume-spec-1.0/article-spec.html)
public struct Par1Archive: Sendable {
    public let clientID: UInt32
    public let controlHash: MD5Digest
    /// True when MD5(bytes 0x20..EOF) reproduced the stored control hash.
    public let controlHashVerified: Bool
    /// MD5 over the concatenated full-file MD5s of all files with the in-parity-set bit.
    public let setHash: MD5Digest
    public let setHashVerified: Bool
    /// 0 for the `.par` index; 1, 2, … for `.p01`, `.p02`, … parity volumes.
    public let volumeNumber: UInt64
    public let files: [Par1FileEntry]
    /// The Unicode comment carried in the index file's data area, if any.
    public let comment: String?

    public var filesInParitySet: [Par1FileEntry] { files.filter(\.isInParitySet) }
}

public struct Par1FileEntry: Sendable, Equatable {
    public let statusFlags: UInt64
    public let fileSize: UInt64
    public let fileMD5: MD5Digest
    public let md5of16k: MD5Digest
    /// UTF-16LE filename, no path.
    public let name: String

    /// Status bit 0: the file contributes to the parity data.
    public var isInParitySet: Bool { statusFlags & 0b1 != 0 }
    /// Status bit 1: the file was verified OK when the set was created/checked.
    public var wasVerified: Bool { statusFlags & 0b10 != 0 }
}

public enum Par1Parser {

    public enum ParseError: Error, Equatable {
        case notPar1
        case truncatedHeader
        case unsupportedVersion(UInt32)
        case malformedFileList
    }

    /// `PAR` + five NUL bytes.
    static let magic = Data([0x50, 0x41, 0x52, 0x00, 0x00, 0x00, 0x00, 0x00])
    /// Fixed header: magic(8) version(4) client(4) controlHash(16) setHash(16) volume(8)
    /// numFiles(8) fileListOffset(8) fileListSize(8) dataOffset(8) dataSize(8) = 0x60 bytes.
    static let headerLength = 0x60
    /// 1.0 in the low dword of the version field.
    static let version1 = UInt32(0x0001_0000)

    public static func parse(fileURL url: URL) throws -> Par1Archive {
        // Plain read, not .mappedIfSafe: PAR1 headers/lists are small, and a mapped file that
        // shrinks mid-parse (e.g. a downloader still writing) would SIGBUS instead of throwing.
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    /// Every header integer below is untrusted input. They are validated against the actual
    /// byte count BEFORE any `Int(_:)` conversion — a trap here would crash the app on exactly
    /// the damaged files it exists to inspect.
    public static func parse(_ data: Data) throws -> Par1Archive {
        guard data.count >= 8, data.field(at: 0, count: 8) == magic else {
            throw ParseError.notPar1
        }
        guard data.count >= headerLength else { throw ParseError.truncatedHeader }
        guard let version = data.leUInt32(at: 0x08) else { throw ParseError.truncatedHeader }
        guard version == version1 else { throw ParseError.unsupportedVersion(version) }
        guard let clientID = data.leUInt32(at: 0x0C),
            let controlHash = data.field(at: 0x10, count: 16).flatMap(MD5Digest.init),
            let setHash = data.field(at: 0x20, count: 16).flatMap(MD5Digest.init),
            let volumeNumber = data.leUInt64(at: 0x30),
            let numFiles = data.leUInt64(at: 0x38),
            let fileListOffset = data.leUInt64(at: 0x40),
            let fileListSize = data.leUInt64(at: 0x48),
            let dataOffset = data.leUInt64(at: 0x50),
            let dataSize = data.leUInt64(at: 0x58)
        else { throw ParseError.truncatedHeader }

        // Control hash covers everything from the set hash (0x20) to EOF. (03 §6)
        let controlVerified =
            data.hashSlice(at: 0x20, count: data.count - 0x20).map {
                MD5Digest.hash($0) == controlHash
            } ?? false

        // File list: consecutive entries, each self-sized. Bound every untrusted integer by the
        // real byte count before converting to Int (a minimum entry is 0x38 bytes, so numFiles
        // can never legitimately exceed fileListSize / 0x38).
        guard fileListOffset <= UInt64(data.count), fileListSize <= UInt64(data.count),
            fileListOffset + fileListSize <= UInt64(data.count),
            numFiles <= fileListSize / 0x38
        else { throw ParseError.malformedFileList }
        let expectedFiles = Int(numFiles)
        var files: [Par1FileEntry] = []
        files.reserveCapacity(expectedFiles)
        var cursor = Int(fileListOffset)
        let listEnd = Int(fileListOffset + fileListSize)
        while files.count < expectedFiles, cursor + 0x38 <= listEnd {
            guard let entrySize64 = data.leUInt64(at: cursor),
                entrySize64 >= 0x38, entrySize64 <= UInt64(listEnd - cursor),
                let status = data.leUInt64(at: cursor + 0x08),
                let fileSize = data.leUInt64(at: cursor + 0x10),
                let fileMD5 = data.field(at: cursor + 0x18, count: 16).flatMap(MD5Digest.init),
                let md5of16k = data.field(at: cursor + 0x28, count: 16).flatMap(MD5Digest.init)
            else { throw ParseError.malformedFileList }
            let entrySize = Int(entrySize64)
            let nameBytes = data.field(at: cursor + 0x38, count: entrySize - 0x38) ?? Data()
            let decoded =
                String(data: trimTrailingZeroPairs(nameBytes), encoding: .utf16LittleEndian) ?? ""
            // Spec says the name carries no path; never trust that on disk-bound input. Strip any
            // path components here so Phase 2 verify can't be steered outside the set folder.
            let name = decoded.split(separator: "/").last.map(String.init) ?? decoded
            files.append(
                Par1FileEntry(
                    statusFlags: status,
                    fileSize: fileSize,
                    fileMD5: fileMD5,
                    md5of16k: md5of16k,
                    name: name
                ))
            cursor += entrySize
        }
        guard files.count == expectedFiles else { throw ParseError.malformedFileList }

        // Set hash = MD5 of the concatenated full-file MD5s of in-set files. (03 §6)
        let inSetHashes = files.filter(\.isInParitySet).map(\.fileMD5.bytes)
        let setVerified = MD5Digest.hash(parts: inSetHashes) == setHash

        // The index file's data area holds a UTF-16 comment; parity volumes hold parity bytes.
        // Bounds-check the untrusted offsets before any Int conversion.
        var comment: String?
        if volumeNumber == 0, dataSize > 0, dataSize < 1 << 20,
            dataOffset <= UInt64(data.count), dataSize <= UInt64(data.count) - dataOffset,
            let raw = data.field(at: Int(dataOffset), count: Int(dataSize))
        {
            comment = String(data: trimTrailingZeroPairs(raw), encoding: .utf16LittleEndian)
            if comment?.isEmpty == true { comment = nil }
        }

        return Par1Archive(
            clientID: clientID,
            controlHash: controlHash,
            controlHashVerified: controlVerified,
            setHash: setHash,
            setHashVerified: setVerified,
            volumeNumber: volumeNumber,
            files: files,
            comment: comment
        )
    }

    private static func trimTrailingZeroPairs(_ data: Data) -> Data {
        var end = data.count - (data.count % 2)
        let base = data.startIndex
        while end >= 2, data[base + end - 1] == 0, data[base + end - 2] == 0 { end -= 2 }
        return Data(data[base..<(base + end)])
    }
}

extension ParSet {
    /// Bridge a parsed PAR1 archive into the UI-facing document model. The row id mixes the
    /// entry index into the hash — two identical-content files share a file MD5, and duplicate
    /// row ids would both trap `Dictionary(uniqueKeysWithValues:)` and confuse `Table` diffing.
    public init(par1 archive: Par1Archive) {
        let entries = archive.files.enumerated().map { index, file in
            var indexLE = Data(count: 8)
            for i in 0..<8 {
                indexLE[i] = UInt8(truncatingIfNeeded: UInt64(index) >> (8 * UInt64(i)))
            }
            let rowID = MD5Digest.hash(
                parts: [file.fileMD5.bytes, Data(file.name.utf8), indexLE])
            return FileEntry(
                id: rowID.uuid,
                name: file.name,
                sizeBytes: file.fileSize,
                status: file.isInParitySet ? FileStatus.pending : .notInSet
            )
        }
        self.init(kind: .par1, files: entries)
    }
}
