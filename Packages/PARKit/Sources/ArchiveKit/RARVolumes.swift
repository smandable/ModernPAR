import Foundation

/// Pure logic for RAR volume naming and output placement — no engine, fully unit-testable.
///
/// First-file forms (ROADMAP Phase 4, completed in Phase 8): `name.rar` (+ old-style
/// `name.rNN` continuations), `name.partNN.rar`, numeric splits `name.001`/`name.002`…
/// (the engine advances trailing digits itself), and SFX `name.exe` (the engine scans past
/// the stub).
enum RARVolumes {

    /// `archive.003` → 3. Three numeric digits, any value (`.000` exists in the wild).
    static func numericSplitNumber(_ filename: String) -> Int? {
        let ext = (filename as NSString).pathExtension
        guard ext.count == 3, ext.allSatisfy(\.isNumber) else { return nil }
        return Int(ext)
    }

    /// `archive.part02.rar` → (stem `archive`, part 2). Case-insensitive.
    static func parsePartName(_ filename: String) -> (stem: String, part: Int)? {
        let lower = filename.lowercased()
        guard lower.hasSuffix(".rar") else { return nil }
        let withoutRar = String(filename.dropLast(4))
        let lowerNoRar = lower.dropLast(4)
        guard let dot = lowerNoRar.range(of: ".part", options: .backwards) else { return nil }
        let digits = lowerNoRar[dot.upperBound...]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let part = Int(digits) else {
            return nil
        }
        let stemLength = lowerNoRar.distance(from: lowerNoRar.startIndex, to: dot.lowerBound)
        return (String(withoutRar.prefix(stemLength)), part)
    }

    /// Old-style continuation volumes: `archive.r00` … `archive.r99`, spilling into `.s00` …
    /// after a hundred volumes (the first volume of such a set is `archive.rar` itself).
    static func isOldStyleContinuation(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard ext.count == 3 else { return false }
        guard let first = ext.first, first >= "r", first <= "z" else { return false }
        return ext.dropFirst().allSatisfy(\.isNumber)
    }

    /// Normalizes any opened volume to the set's FIRST volume by scanning siblings — matching
    /// the original's behavior of accepting a double-click on any volume of a set.
    static func firstVolume(for url: URL) -> URL {
        let filename = url.lastPathComponent
        let folder = url.deletingLastPathComponent()

        if let part = parsePartName(filename) {
            guard part.part != 1 else { return url }
            // Find the sibling with the same stem and the LOWEST part number (usually 1, but
            // sets renumbered or partially downloaded may start higher).
            guard
                let siblings = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil,
                    options: [])
            else { return url }
            var best: (part: Int, url: URL)?
            for sibling in siblings {
                guard let candidate = parsePartName(sibling.lastPathComponent),
                    candidate.stem.lowercased() == part.stem.lowercased()
                else { continue }
                if best == nil || candidate.part < best!.part {
                    best = (candidate.part, sibling)
                }
            }
            return best?.url ?? url
        }

        if isOldStyleContinuation(filename) {
            // `archive.r05` → `archive.rar` beside it holds the set's start.
            let stem = (filename as NSString).deletingPathExtension
            let candidate = folder.appendingPathComponent(stem + ".rar")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            // Case-insensitive fallback (volumes that crossed a Windows filesystem).
            if let siblings = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [])
            {
                let wanted = (stem + ".rar").lowercased()
                if let match = siblings.first(where: { $0.lastPathComponent.lowercased() == wanted }
                ) {
                    return match
                }
            }
        }
        if let number = numericSplitNumber(filename), number != 1 {
            // `archive.005` → the sibling with the LOWEST split number starts the set.
            let stem = ((filename as NSString).deletingPathExtension).lowercased()
            guard
                let siblings = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil, options: [])
            else { return url }
            var best: (number: Int, url: URL)?
            for sibling in siblings {
                guard let n = numericSplitNumber(sibling.lastPathComponent),
                    ((sibling.lastPathComponent as NSString).deletingPathExtension).lowercased()
                        == stem
                else { continue }
                if best == nil || n < best!.number { best = (n, sibling) }
            }
            return best?.url ?? url
        }
        return url
    }

    /// The expected-but-absent first volume's filename, when the best available anchor is
    /// demonstrably NOT the set's start — extraction from mid-set would silently drop every
    /// file beginning in the missing volume and then report success, so callers fail fast.
    /// Returns nil when the anchor is a plausible first volume.
    static func missingFirstVolumeName(for url: URL) -> String? {
        let filename = url.lastPathComponent
        if isOldStyleContinuation(filename) {
            // firstVolume(for:) already searched for the `.rar` sibling and found none.
            return (filename as NSString).deletingPathExtension + ".rar"
        }
        if let part = parsePartName(filename), part.part > 1 {
            // Lowest part on disk is still > 1 — part 1 is missing. Mirror the anchor's
            // digit width so the named file matches the set's naming.
            let width = filename.dropLast(4).reversed().prefix(while: \.isNumber).count
            let partOne = String(repeating: "0", count: max(0, width - 1)) + "1"
            return "\(part.stem).part\(partOne).rar"
        }
        if let number = numericSplitNumber(filename), number > 1 {
            // firstVolume(for:) found no lower-numbered sibling — `.001` is missing.
            return (filename as NSString).deletingPathExtension + ".001"
        }
        return nil
    }

    /// Whether `candidate` is the given set's own archive volume (the first volume itself or
    /// a sibling volume of the same set) — used to refuse trashing the source on overwrite.
    static func belongsToSet(_ candidate: URL, firstVolume: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path.lowercased()
        if candidatePath == firstVolume.standardizedFileURL.path.lowercased() { return true }
        guard
            candidate.standardizedFileURL.deletingLastPathComponent().path.lowercased()
                == firstVolume.standardizedFileURL.deletingLastPathComponent().path.lowercased()
        else { return false }
        let name = candidate.lastPathComponent
        let setStem = baseName(for: firstVolume).lowercased()
        if let part = parsePartName(name) { return part.stem.lowercased() == setStem }
        if numericSplitNumber(name) != nil, numericSplitNumber(firstVolume.lastPathComponent) != nil
        {
            return ((name as NSString).deletingPathExtension).lowercased() == setStem
        }
        if isOldStyleContinuation(name) || name.lowercased().hasSuffix(".rar") {
            return ((name as NSString).deletingPathExtension).lowercased() == setStem
        }
        return false
    }

    /// The set's display / output-folder name: `archive.part01.rar` → `archive`,
    /// `archive.rar` → `archive`, `archive.r00` → `archive`.
    static func baseName(for url: URL) -> String {
        let filename = url.lastPathComponent
        if let part = parsePartName(filename), !part.stem.isEmpty { return part.stem }
        let stripped = (filename as NSString).deletingPathExtension
        return stripped.isEmpty ? filename : stripped
    }

    /// First non-existing variant of `proposed`: `Photos` → `Photos 2` → `Photos 3` …
    /// (file extensions are preserved: `report.pdf` → `report 2.pdf`).
    static func uniqueDestination(for proposed: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: proposed.path) else { return proposed }
        let folder = proposed.deletingLastPathComponent()
        let filename = proposed.lastPathComponent
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var counter = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
