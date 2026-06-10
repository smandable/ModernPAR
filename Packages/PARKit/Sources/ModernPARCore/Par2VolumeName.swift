import Foundation

/// The `Filename.volXXX+YY.par2` recovery-file naming convention: `XXX` = exponent of the first
/// recovery block in the file, `YY` = number of recovery blocks it holds. The bare
/// `Filename.par2` is the index file (metadata only, no recovery slices). (docs/research/03 §4.3)
public struct Par2VolumeName: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        /// `name.par2` — metadata only.
        case index
        /// `name.volXXX+YY.par2`.
        case volume(firstExponent: Int, blockCount: Int)
    }

    /// The set's base name with the `.volXXX+YY.par2` / `.par2` suffix removed.
    public let baseName: String
    public let role: Role

    /// Parses a filename (not a path). Returns nil when it is not a `.par2` name at all.
    public static func parse(filename: String) -> Par2VolumeName? {
        let lower = filename.lowercased()
        guard lower.hasSuffix(".par2") else { return nil }
        let stem = String(filename.dropLast(".par2".count))

        // name.volXXX+YY  (case-insensitive "vol", digits on both sides of '+')
        if let volRange = stem.range(of: #"\.[vV][oO][lL]\d+\+\d+$"#, options: .regularExpression) {
            let base = String(stem[..<volRange.lowerBound])
            let suffix = stem[volRange.lowerBound...].dropFirst(4)  // drop ".vol"
            let parts = suffix.split(separator: "+")
            if parts.count == 2, let first = Int(parts[0]), let count = Int(parts[1]) {
                return Par2VolumeName(
                    baseName: base, role: .volume(firstExponent: first, blockCount: count))
            }
        }
        return Par2VolumeName(baseName: stem, role: .index)
    }
}
