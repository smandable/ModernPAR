import Foundation

/// File-type routing knowledge for archives — lets Core/UI route an opened URL to the
/// extraction flow without naming any extractor module. (ROADMAP Phase 4–5; `.001` splits
/// and SFX `.exe` forms in Phase 8.)
public enum ArchiveFileTypes {
    /// "Rar!\x1A\x07" — shared prefix of the RAR4 and RAR5 signatures.
    static let rarMagic: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]

    /// `.rar`, an old-style continuation volume (`.r00` … `.z99`), a numeric split whose
    /// bytes actually start with the RAR signature (`.001`), or an SFX `.exe` carrying the
    /// signature in its head. Extension checks stay cheap; only the ambiguous forms read.
    public static func isRARArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "rar" { return true }
        if ext.count == 3, let first = ext.first, first >= "r", first <= "z",
            ext.dropFirst().allSatisfy(\.isNumber)
        {
            return true
        }
        // name.001 splits: only when the piece IS the start of a RAR archive — any file
        // splitter can produce .001 of anything.
        if ext.count == 3, ext.allSatisfy(\.isNumber) {
            return sniffsAsRAR(url, scanLimit: rarMagic.count)
        }
        // SFX: an executable stub precedes the archive; the signature sits past the stub.
        if ext == "exe" {
            return sniffsAsRAR(url, scanLimit: 1 << 20)
        }
        return false
    }

    public static func isZipArchive(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    /// Anything one of the built-in extractors handles.
    public static func isArchive(_ url: URL) -> Bool {
        isRARArchive(url) || isZipArchive(url)
    }

    /// Whether the RAR signature appears within the file's first `scanLimit` bytes.
    static func sniffsAsRAR(_ url: URL, scanLimit: Int) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: scanLimit), data.count >= rarMagic.count
        else { return false }
        if scanLimit == rarMagic.count {
            return [UInt8](data.prefix(rarMagic.count)) == rarMagic
        }
        return data.firstRange(of: Data(rarMagic)) != nil
    }
}
