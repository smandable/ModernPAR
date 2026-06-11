import Foundation

/// File-type routing knowledge for archives — lets Core/UI route an opened URL to the
/// extraction flow without naming any extractor module. (ROADMAP Phase 4–5)
public enum ArchiveFileTypes {
    /// `.rar`, or an old-style continuation volume (`.r00` … `.z99`, used after `.r99`).
    public static func isRARArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "rar" { return true }
        guard ext.count == 3, let first = ext.first, first >= "r", first <= "z" else {
            return false
        }
        return ext.dropFirst().allSatisfy(\.isNumber)
    }

    public static func isZipArchive(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    /// Anything one of the built-in extractors handles.
    public static func isArchive(_ url: URL) -> Bool {
        isRARArchive(url) || isZipArchive(url)
    }
}
