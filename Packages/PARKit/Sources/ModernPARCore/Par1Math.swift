import Foundation

/// GF(2⁸) arithmetic and the PAR1 Reed-Solomon scheme (Plank CS-96-332, as the PAR 1.0 spec
/// adopted it). Every constant here is pinned EMPIRICALLY against parity produced by the
/// original MacPAR deLuxe Intel `par` binary (the golden fixtures): field polynomial 0x11D,
/// volume `v`'s coefficient for the 1-based in-set file index `j` is `j^(v-1)`, files are
/// zero-padded to the largest, and volume 1 is therefore a plain XOR. Do not "fix" the
/// Vandermonde construction — compatibility means reproducing the spec's matrix exactly,
/// known flaws included. (ROADMAP Phase 8; docs/research/03 §6)
public enum GF256 {
    /// x⁸ + x⁴ + x³ + x² + 1 — the PAR1 spec polynomial (0x11B is AES's, NOT ours).
    static let polynomial: UInt32 = 0x11D

    /// exp[i] = α^i for α = 2; doubled so `exp[log a + log b]` never wraps.
    public static let exp: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 510)
        var x: UInt32 = 1
        for i in 0..<255 {
            table[i] = UInt8(x)
            table[i + 255] = UInt8(x)
            x <<= 1
            if x & 0x100 != 0 { x ^= polynomial }
        }
        return table
    }()

    /// log[a] for a ≠ 0; log[0] is unused (callers must guard zero).
    public static let log: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        var x: UInt32 = 1
        for i in 0..<255 {
            table[Int(x)] = UInt8(i)
            x <<= 1
            if x & 0x100 != 0 { x ^= polynomial }
        }
        return table
    }()

    @inlinable
    public static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return exp[Int(log[Int(a)]) + Int(log[Int(b)])]
    }

    /// a / b with b ≠ 0 (callers guard; division by zero is a programmer error in a field).
    @inlinable
    public static func div(_ a: UInt8, _ b: UInt8) -> UInt8 {
        precondition(b != 0, "GF(2^8) division by zero")
        if a == 0 { return 0 }
        return exp[Int(log[Int(a)]) + 255 - Int(log[Int(b)])]
    }

    /// base^power for base ≠ 0 (PAR1 file indices are 1-based, so 0 never appears).
    /// The exponent reduces mod 255 (the multiplicative group's order) BEFORE the table
    /// multiply — an unbounded caller-supplied power must never overflow the Int product.
    /// (Phase 8 review)
    @inlinable
    public static func pow(_ base: UInt8, _ power: Int) -> UInt8 {
        precondition(base != 0 && power >= 0, "GF(2^8) pow of zero base or negative power")
        let reduced = power % 255
        if reduced == 0 { return 1 }  // x^(255k) = 1 — the group's order is 255
        return exp[(Int(log[Int(base)]) * reduced) % 255]
    }

    /// dst[i] ^= coeff · src[i] — the byte-parallel accumulation every PAR1 operation is
    /// built from. coeff == 0 is a no-op; coeff == 1 is a plain XOR; otherwise a 256-entry
    /// product row keeps the inner loop to one lookup + one XOR.
    public static func accumulate(_ dst: inout [UInt8], src: [UInt8], coefficient: UInt8) {
        precondition(src.count <= dst.count, "source longer than accumulator")
        switch coefficient {
        case 0:
            return
        case 1:
            dst.withUnsafeMutableBufferPointer { d in
                src.withUnsafeBufferPointer { s in
                    for i in 0..<s.count { d[i] ^= s[i] }
                }
            }
        default:
            let logC = Int(log[Int(coefficient)])
            var row = [UInt8](repeating: 0, count: 256)
            for b in 1..<256 { row[b] = exp[logC + Int(log[b])] }
            dst.withUnsafeMutableBufferPointer { d in
                src.withUnsafeBufferPointer { s in
                    row.withUnsafeBufferPointer { r in
                        for i in 0..<s.count { d[i] ^= r[Int(s[i])] }
                    }
                }
            }
        }
    }
}

/// The PAR1 recovery scheme over GF(2⁸).
public enum Par1RS {
    /// PAR1's hard ceiling: files + parity volumes < 256 (GF(2⁸) has 255 usable indices).
    public static let maxEntities = 255

    /// Volume `v`'s coefficient for the 1-based in-set file index `j`: `j^(v-1)`.
    /// (Pinned against the Intel binary's parity — see GF256's doc comment.)
    public static func coefficient(volume: Int, fileIndex: Int) -> UInt8 {
        precondition(volume >= 1 && fileIndex >= 1 && fileIndex <= 255)
        return GF256.pow(UInt8(fileIndex), volume - 1)
    }

    /// Solves for the missing in-set files. `present` maps each INTACT 1-based file index to
    /// its (padded) chunk bytes; `volumes` maps each available volume number to its parity
    /// chunk. Returns the recovered chunks for `missing` (same order), or nil when the
    /// equation system is singular — which the PAR1/Plank construction permits for some
    /// index combinations; callers surface that as unrecoverable, never as a crash.
    ///
    /// All chunks must share one length (the caller pads). Whole files are processed as a
    /// sequence of chunks against ONE inverted matrix (the matrix depends only on WHICH
    /// files are missing, not on the data).
    public struct Decoder {
        /// rows[k] = the GF coefficients producing missing file k from
        /// (intact files ++ used volumes) in the order given to `init`.
        let rows: [[UInt8]]
        let intactIndices: [Int]
        let usedVolumes: [Int]

        /// Builds the decode matrix for `missing` (1-based file indices) given `intact`
        /// (the remaining 1-based file indices) and the available volume numbers, of which
        /// the first `missing.count` are used. nil when there aren't enough volumes or the
        /// submatrix is singular.
        public init?(
            missing: [Int], intact: [Int], availableVolumes: [Int], fileCount: Int
        ) {
            guard !missing.isEmpty, missing.count <= availableVolumes.count else { return nil }
            let used = Array(availableVolumes.prefix(missing.count))
            let n = fileCount

            // Build the n×n system: identity rows for intact files, Vandermonde rows for the
            // used volumes, then invert. Column order = 1-based file index. (Plank decode.)
            var matrix = [[UInt8]]()
            matrix.reserveCapacity(n)
            var rowSources: [(isVolume: Bool, id: Int)] = []
            for j in intact {
                var row = [UInt8](repeating: 0, count: n)
                row[j - 1] = 1
                matrix.append(row)
                rowSources.append((false, j))
            }
            for v in used {
                var row = [UInt8](repeating: 0, count: n)
                for j in 1...n { row[j - 1] = Par1RS.coefficient(volume: v, fileIndex: j) }
                matrix.append(row)
                rowSources.append((true, v))
            }
            guard matrix.count == n, let inverse = Par1RS.invert(matrix) else { return nil }

            // Recovered file j's chunk = Σ over sources s of inverse[j-1][s] · source s.
            self.rows = missing.map { inverse[$0 - 1] }
            self.intactIndices = rowSources.filter { !$0.isVolume }.map(\.id)
            self.usedVolumes = used
        }

        /// Recovers one chunk per missing file. `intactChunks` keyed by 1-based file index,
        /// `volumeChunks` keyed by volume number; every chunk `chunkSize` bytes (padded).
        public func recoverChunk(
            intactChunks: [Int: [UInt8]], volumeChunks: [Int: [UInt8]], chunkSize: Int
        ) -> [[UInt8]]? {
            var sources: [[UInt8]] = []
            for j in intactIndices {
                guard let chunk = intactChunks[j], chunk.count == chunkSize else { return nil }
                sources.append(chunk)
            }
            for v in usedVolumes {
                guard let chunk = volumeChunks[v], chunk.count == chunkSize else { return nil }
                sources.append(chunk)
            }
            return rows.map { row in
                var out = [UInt8](repeating: 0, count: chunkSize)
                for (s, source) in sources.enumerated() {
                    GF256.accumulate(&out, src: source, coefficient: row[s])
                }
                return out
            }
        }
    }

    /// Gauss-Jordan inversion over GF(2⁸); nil for a singular matrix (the spec's Vandermonde
    /// construction does not guarantee invertibility for every index combination).
    static func invert(_ matrix: [[UInt8]]) -> [[UInt8]]? {
        let n = matrix.count
        guard n > 0, matrix.allSatisfy({ $0.count == n }) else { return nil }
        var a = matrix
        var inv = (0..<n).map { i -> [UInt8] in
            var row = [UInt8](repeating: 0, count: n)
            row[i] = 1
            return row
        }
        for col in 0..<n {
            // Pivot: any row at/below with a nonzero in this column.
            guard let pivot = (col..<n).first(where: { a[$0][col] != 0 }) else { return nil }
            a.swapAt(col, pivot)
            inv.swapAt(col, pivot)
            let scale = a[col][col]
            if scale != 1 {
                for k in 0..<n {
                    a[col][k] = GF256.div(a[col][k], scale)
                    inv[col][k] = GF256.div(inv[col][k], scale)
                }
            }
            for r in 0..<n where r != col && a[r][col] != 0 {
                let factor = a[r][col]
                for k in 0..<n {
                    a[r][k] ^= GF256.mul(factor, a[col][k])
                    inv[r][k] ^= GF256.mul(factor, inv[col][k])
                }
            }
        }
        return inv
    }
}
