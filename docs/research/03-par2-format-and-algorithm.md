# PAR2 (and PAR1) File Format + Recovery Algorithm

Research reference for **ModernPAR**. This document specifies the PAR2 and PAR1 on-disk
formats precisely enough to (a) parse/inspect them natively in Swift and (b) correctly
wrap or re-implement an engine. It then surveys engine options and gives a concrete
recommendation.

Authoritative spec sources (cite these in code comments):
- **PAR2 v2.0 spec** (Michael Nahas / Parchive): <https://parchive.sourceforge.net/docs/specifications/parity-volume-spec/article-spec.html>
- **PAR1 v1.0 spec** (Stefan Wehlus / Tobias Reckhard / Willem Monsuwe): <https://parchive.sourceforge.net/docs/specifications/parity-volume-spec-1.0/article-spec.html>
- **PAR3 v3.0 ALPHA** (for "what got fixed" context): <https://parchive.github.io/doc/Parity_Volume_Set_Specification_v3.0.html>
- Parchive overview: <https://en.wikipedia.org/wiki/Parchive>
- Format-archaeology cross-check: <http://fileformats.archiveteam.org/wiki/Parity_Volume_Set>
- Reference C++ implementation: <https://github.com/Parchive/par2cmdline>

> Ground-truth note: MacPAR deLuxe's PAR2 engine is `par2SL`, a GCD-parallelized fork of
> par2cmdline (Peter Clements' lineage). Its CLI is the standard par2cmdline option set
> (`-b`, `-s`, `-r`, `-c`, `-f`, `-u`, `-l`, `-n`, `-m`). See `00-source-notes.md`. Anything
> ModernPAR ships must reproduce those create/verify/repair semantics and produce/consume
> standard PAR2 files.

---

## 1. PAR2 at a glance

A `.par2` file is a flat, order-independent **sequence of packets**. There is no central
directory; a reader scans for the 8-byte magic, reads each packet's self-described length,
validates its MD5, and ignores anything it doesn't recognize or that fails the checksum.
This is what makes PAR2 robust: a packet can appear in *any* `.par2` file in the set, can be
duplicated across files (redundancy for the metadata itself), and a corrupt packet is simply
skipped.

Key design decisions vs PAR1 (<https://en.wikipedia.org/wiki/Parchive>):
- Recovery works on **fixed-size blocks ("slices")** of data, not whole files. So a 4 GB
  file and a 1 KB file can share one recovery set efficiently.
- Arithmetic moved from **GF(2^8)** (PAR1) to **GF(2^16)** (PAR2): up to **32,768 source
  blocks** and **65,535 recovery blocks** per set (vs PAR1's hard limit of 255 *files*).
- A **sliding window CRC** matcher can find data that has been renamed, shifted, or split
  across files — PAR1 could not.
- Metadata (filenames, hashes) is decoupled from recovery data, so you can verify without
  any recovery blocks present.

Everything is **little-endian** and **4-byte aligned**: "every field starts on an index in
the file which is congruent to zero, modulus 4" (spec). All packet bodies and the slice
size are multiples of 4 bytes; variable-length strings are zero-padded to the next multiple
of 4.

---

## 2. PAR2 packet structure

### 2.1 Packet header (64 bytes, fixed)

| Offset | Size | Field | Meaning |
|-------:|-----:|-------|---------|
| 0  | 8  | **Magic** | ASCII `PAR2\0PKT` = bytes `50 41 52 32 00 50 4B 54` |
| 8  | 8  | **Packet length** | Total bytes of header + body. Multiple of 4. (uint64 LE) |
| 16 | 16 | **Packet MD5** | MD5 over the packet *from offset 32 to end of body* |
| 32 | 16 | **Recovery Set ID** | 16-byte set identifier (a.k.a. "setid"); see §3 |
| 48 | 16 | **Packet type** | ASCII type tag, e.g. `PAR 2.0\0Main\0\0\0\0` |
| 64 | …  | **Body** | Type-specific, multiple of 4 bytes |

Critical detail for a correct parser: the **Packet MD5 covers exactly the bytes starting at
the Recovery Set ID (offset 32) through the last body byte** — it does *not* include the
magic, the length field, or the MD5 field itself. (Spec: "The MD5 Hash … starts at first
byte of Recovery Set ID and ends at last byte of body.")

To scan a file: find the magic, read `length`, slice out `[0, length)`, recompute MD5 over
`[32, length)`, compare to the stored MD5. If it matches, dispatch on the type tag; else skip
this candidate and resume scanning *after* the magic you found (packets can be back-to-back,
and garbage may sit between them).

### 2.2 The packet types

All type tags are exactly 16 ASCII bytes, null-padded:

| Type tag (16 bytes) | Packet | Required? | Purpose |
|---------------------|--------|-----------|---------|
| `PAR 2.0\0Main\0\0\0\0` | **Main** | Yes (defines the set) | Slice size + the list of file IDs in the recovery set and non-recovery set |
| `PAR 2.0\0FileDesc` | **File Description** | Yes, one per file | File ID, full-file MD5, MD5-of-first-16k, length, ASCII filename |
| `PAR 2.0\0IFSC\0\0\0\0` | **Input File Slice Checksum** | Yes, one per file | Per-slice MD5+CRC32 |
| `PAR 2.0\0RecvSlic` | **Recovery Slice** | Only in recovery vols | One recovery block + its GF(2^16) exponent |
| `PAR 2.0\0Creator\0` | **Creator** | Recommended | ASCII client identification string |
| `PAR 2.0\0UniFileN` | **Unicode Filename** | Optional | UTF-16 filename for a given file ID |
| `PAR 2.0\0CommASCI` | **ASCII Comment** | Optional | ASCII comment text |
| `PAR 2.0\0CommUni\0` | **Unicode Comment** | Optional | UTF-16 comment text |

> Forward-compat rule (from the spec and reiterated re par3): **an unrecognized packet type
> must be silently ignored**. par2cmdline does this. This is precisely the mechanism that lets
> newer tools add packets without breaking older readers — and the reason older readers
> "silently" can't use newer features. ModernPAR's parser must follow the same rule.

### 2.3 Main packet body

| Size | Field |
|-----:|-------|
| 8 | **Slice size** (block size, bytes; multiple of 4) |
| 4 | **Count of recovery-set file IDs** (uint32 LE) |
| 16×N | **Recovery-set File IDs**, sorted ascending as 16-byte values |
| 16×M | **Non-recovery-set File IDs** (files described but not protected), sorted ascending |

The **order of File IDs in the recovery-set array is canonical**: it fixes which input slice
gets which Reed-Solomon constant (see §5). "The first slice of the first file in the main
packet is assigned the first constant," then subsequent slices of that file, then the next
file, etc. Get this ordering wrong and you produce incompatible recovery data.

### 2.4 File Description packet body

| Size | Field |
|-----:|-------|
| 16 | **File ID** (see §3.2) |
| 16 | **MD5 of the entire file** |
| 16 | **MD5-16k** = MD5 of the first 16384 bytes (or the whole file if shorter) |
| 8 | **File length** (uint64 LE) |
| … | **Filename**, ASCII, *not* null-terminated, zero-padded to a multiple of 4 |

### 2.5 Input File Slice Checksum (IFSC) packet body

| Size | Field |
|-----:|-------|
| 16 | **File ID** |
| 20×K | **K entries**, one per slice of this file, in slice order |

Each 20-byte entry is **16-byte MD5 then 4-byte CRC32** of that slice (MD5 first, CRC second).
The last slice of a file is **zero-padded to the full slice size before hashing** ("if the
file would end mid-slice, the remainder of the slice is filled with 0-value bytes"). The CRC32
is the standard CCITT/Ethernet/PKZIP CRC32 (poly `0xEDB88320` reflected). Both checksums are
computed over the *padded* slice.

### 2.6 Recovery Slice packet body

| Size | Field |
|-----:|-------|
| 4 | **Exponent** (uint32 LE; the recovery slice's GF(2^16) exponent — see §5) |
| slice_size | **Recovery data** (one full recovery block) |

One Recovery Slice packet = one recovery block. A `.vol003+04.par2` file therefore contains
4 Recovery Slice packets (exponents 3,4,5,6) plus copies of the metadata packets.

### 2.7 Creator / Unicode filename / Comment packets

- **Creator**: body is a free-form ASCII string (not null-terminated, 4-byte padded), e.g.
  `Created by par2cmdline version 1.1.1.` ModernPAR should write its own identifying string.
- **Unicode Filename**: 16-byte File ID + UTF-16LE filename (4-byte padded). Companion to the
  ASCII filename in the File Description packet (which remains mandatory). par2cmdline largely
  ignores these on read; modern sets often omit them in favor of UTF-8 in par3.
- **ASCII Comment**: free ASCII text, 4-byte padded.
- **Unicode Comment**: 16-byte field (MD5 of the corresponding ASCII comment, or zeros) +
  UTF-16LE comment text, 4-byte padded.

---

## 3. Identifiers and hashes

### 3.1 Recovery Set ID ("setid")

**Recovery Set ID = MD5 of the *body* of the Main packet.** Because the Main packet body
contains the slice size and the full sorted list of file IDs, the setid uniquely binds a
specific set of files at a specific block size. Every packet in the set carries this same
16-byte ID at header offset 32, which is how a reader groups packets gathered from many
`.par2` files into one logical set (and rejects stray packets from a different set).

### 3.2 File ID

**File ID = MD5( MD5-16k ‖ file_length ‖ ASCII_filename )** — i.e. the MD5 over the *last three
fields of the File Description packet body*, concatenated in order: the 16-byte MD5-of-first-16k,
the 8-byte little-endian length, and the raw ASCII filename bytes. (Spec: "the File ID … is
calculated as the MD5 Hash of … MD5-16k, length, and ASCII file name.")

Consequence to keep in mind: the File ID depends on the **filename**. Renaming a file changes
its File ID, so the matcher relies on content hashes (full MD5, 16k MD5, per-slice MD5/CRC),
*not* the File ID, to recognize renamed files.

### 3.3 MD5 usage summary

| Hash | Where | Used for |
|------|-------|----------|
| Full-file MD5 | File Description packet | Final "is this file now correct?" check after repair; fast-path "file already OK" |
| MD5-16k (first 16 KiB) | File Description packet | Cheap candidate identification of a possibly-renamed file before hashing the whole thing; also feeds File ID |
| Per-slice MD5 (16 B) | IFSC packet | Definitive identification of an individual good block |
| Per-slice CRC32 (4 B) | IFSC packet | Fast sliding-window scan (see §4); cheap pre-filter before the MD5 check |
| Packet MD5 | Every packet header | Integrity of the metadata/recovery packets themselves |

### 3.4 The sliding-window CRC32 block matcher

This is the cleverest verify-side trick and the reason PAR2 finds data even when files are
renamed, concatenated, or have garbage prepended.

1. From the IFSC packets, build a hash map: `crc32 -> list of (fileID, sliceIndex, md5)`.
2. For every file in the working folder (including unknown/extra files), slide a window of
   `slice_size` bytes byte-by-byte and maintain a **rolling CRC32**. CRC32 supports O(1)
   incremental "roll out the leading byte, roll in the trailing byte" updates, so scanning an
   N-byte file is ~O(N) rather than O(N × slice_size).
3. On a CRC32 hit, compute the (relatively expensive) MD5 of that window and compare to the
   stored slice MD5 to confirm — CRC32 alone has collisions. A confirmed match means "this
   exact data block exists at this offset in this file," regardless of which file the spec
   *expected* it in.
4. Aligned matches at offset 0, slice_size, 2·slice_size … reconstruct intact/renamed files;
   unaligned matches recover blocks from shifted or concatenated data.

> UX implication for ModernPAR (and a documented behavior of MacPAR deLuxe): this scan runs
> over *all* files in the folder, so a folder full of unrelated files is slow — the original
> app warns the user ("ManyUnrelatedFilesWarning"). Worth surfacing a similar hint.

---

## 4. Block size, redundancy, and recovery-file sizing/naming

### 4.1 Slice (block) size

- Slice size is stored in the Main packet (8 bytes) and must be a **multiple of 4**.
- Number of source blocks = `ceil(total_input_bytes_per_file_summed_in_blocks)` — more
  precisely, each file independently contributes `ceil(file_size / slice_size)` slices (the
  last slice zero-padded), and the sum across files must be **≤ 32768** (GF(2^16) source-block
  limit; matches MacPAR deLuxe's stated "PAR2 ≤ 32768 files/blocks").
- The two ways to choose it (mirroring the `-b`/`-s` CLI split): specify **block count** (`-b<n>`,
  engine derives block size) or specify **block size in KB** (`-s<n>`, engine derives count).
  MacPAR deLuxe exposes block size in KB (range 1–419430) plus an "Automatic" mode.

### 4.2 Redundancy → recovery block count

- Redundancy can be specified as a **percentage** (`-r<n>`, 1–100 in MacPAR deLuxe) or as an
  explicit **recovery block count** (`-c<n>`). They are mutually exclusive.
- `recovery_blocks ≈ round(source_blocks × redundancy% / 100)`, capped at **65535**.
- You can recover any `k` lost source blocks given any `k` surviving recovery blocks (subject
  to the matrix caveat in §5.4). So "5% redundancy" ≈ "survive loss of ~5% of the blocks."
- `-f<n>` sets the **first recovery block exponent** (the "vol" number to start at), used when
  appending more recovery data to an existing set later.

### 4.3 Recovery-file naming and sizing

Convention surfaced to users (and in MacPAR deLuxe's help): `Filename.volXXX+YY.par2`

- `XXX` = exponent of the **first** recovery block in this file (zero-based).
- `YY`  = **number** of recovery blocks in this file.
- Example set: `data.par2` (index: metadata only, 0 recovery blocks), `data.vol000+01.par2`,
  `data.vol001+02.par2`, `data.vol003+04.par2`, `data.vol007+08.par2`, … Block counts commonly
  follow a **doubling / exponential** progression so a client can fetch close to the exact
  number of blocks it needs by grabbing the right files. (<https://en.wikipedia.org/wiki/Parchive>)
- The bare `Filename.par2` (the "index file") usually carries all metadata packets and **no**
  Recovery Slice packets, so verification needs only this one small file.
- Sizing modes (matching the CLI `-u`/`-l`/`-n`):
  - `-u` **uniform**: every recovery file holds the same number of blocks.
  - `-l` **limited**: cap each recovery file's size (e.g. to the largest input file) → variable
    block counts, exponential progression.
  - `-n<n>`: fix the **number** of recovery files.
  - MacPAR deLuxe also offers "limit par2 file size to largest data file."
- Metadata packets are duplicated across the recovery files for redundancy, so even if the
  index file is lost the set is still self-describing.

---

## 5. The Reed-Solomon coding (GF(2^16))

### 5.1 The field

PAR2 does all recovery arithmetic in **GF(2^16)** (16-bit words, little-endian within each
2-byte word of a slice). The field is defined by the generator polynomial
**`0x1100B`** (i.e. `x^16 + x^12 + x^3 + x + 1`); the spec gives the value as `0x0001100B`.
Addition is XOR; multiplication is carry-less polynomial multiply reduced modulo `0x1100B`,
normally implemented with log/antilog tables or (in fast engines) SIMD GF16 routines.

### 5.2 The per-slice "constants" (bases) and exponents

Each **input slice** is assigned a distinct 16-bit **constant** (base) `g_i`. The constants
are drawn, in order, from the sequence of powers of 2 **whose multiplicative order is the full
65535** — concretely, value `2^n` for increasing `n`, but **skipping any `n` divisible by
3, 5, 17, or 257** (the prime factors of 65535 = 3·5·17·257). The spec's condition:
`(n%3 != 0 && n%5 != 0 && n%17 != 0 && n%257 != 0)`. The first valid constants are therefore
`2, 4, 16, 128, 256, 2048, 8192, 16384, 4107, …` (the values jump once `n` would hit a
forbidden exponent). Skipping those `n` guarantees each base has order 65535, which is what the
spec is trying to ensure so that distinct bases raised to distinct exponents stay distinct.

Each **recovery slice** carries a 16-bit **exponent** `e_j` (stored in the Recovery Slice
packet header, 0,1,2,…).

The coding matrix entry coupling input slice `i` to recovery slice `j` is:
```
   M[j][i] = g_i ^ e_j          (g_i raised to the power e_j, in GF(2^16))
```
and each 2-byte word of recovery slice `j` is:
```
   R_j[word] = Σ_i  ( D_i[word] · (g_i ^ e_j) )      // all ops in GF(2^16)
```
(Spec: "the 2-byte word of the input slice multiplied by the input slice's constant raised to
the recovery slice's exponent … summed.") This is a **Vandermonde-style** generator matrix:
row `j` is `[g_0^{e_j}, g_1^{e_j}, …]`. The design follows James S. Plank's 1997 RAID tutorial,
deliberately diverging from it to avoid low-order constants.

### 5.3 Repair = solving a linear system

To repair, the engine:
1. Identifies which input slices are present (good) and which are missing.
2. Selects enough recovery slices to cover the missing count.
3. Builds the submatrix mapping **missing inputs → chosen recovery outputs**, moves the known
   (present-input) contributions to the right-hand side (subtract = XOR), and **inverts the
   submatrix via Gauss-Jordan elimination in GF(2^16)** to solve for the missing input slices.
4. Verifies each reconstructed slice's MD5/CRC and the final full-file MD5.

The math is exactly RS erasure decoding: `r` recovery blocks can restore up to `r` missing
source blocks **iff** the chosen `r×r` submatrix is invertible.

### 5.4 The (in)famous par2 RS matrix bug — and why it almost never bites

The historical issue (acknowledged on <https://en.wikipedia.org/wiki/Parchive> and the par3
design thread <https://github.com/Parchive/par3cmdline/issues/9>):

- **What's wrong**: PAR2's generator matrix is built Vandermonde-style from
  `g_i^{e_j}`. James Plank's *original* 1997 tutorial claimed this construction always yields
  invertible square submatrices; that claim was **incorrect**, and Plank issued a formal
  correction — *"Note: Correction to the 1997 Tutorial on Reed-Solomon Coding,"* Plank & Ding,
  UT tech report **CS-03-504**, April 2003
  (<https://web.eecs.utk.edu/~jplank/plank/papers/CS-03-504.pdf>). Because PAR2 inherited the
  construction, the matrix is **not guaranteed** to have all square submatrices invertible — it
  is, in effect, "invertible with very high probability" rather than provably MDS for every
  erasure pattern. A truly safe construction uses a **Cauchy** matrix (or a properly
  conditioned Vandermonde), which par3 adopts ("PAR3 … with James S. Plank's correction").
- **Practical impact**: in real-world block counts the probability that the specific set of
  surviving recovery blocks yields a singular submatrix is vanishingly small, so the bug almost
  never manifests. It is a *theoretical* MDS-property defect, not a routine failure. Most
  user-visible "enough blocks but repair fails" reports (e.g.
  <https://github.com/Parchive/par2cmdline/issues/156>, SABnzbd forum threads) trace to
  **block detection** problems — mispositioned/duplicate/null blocks the scanner didn't locate
  — and are fixed with the `-N` (skip-leading-data search) flag or by using a different
  matcher, **not** to matrix singularity.
- **Compatibility constraint for ModernPAR**: every interoperable PAR2 implementation
  (par2cmdline, QuickPar, **MultiPar/par2j**, ParPar, par2cmdline-turbo) must reproduce the
  **identical** constant sequence, slice-ordering, and `g_i^{e_j}` matrix, because the recovery
  data is only meaningful against that exact matrix. par2cmdline-turbo/ParPar change *how fast*
  the GF16 math runs (SIMD) but **not the matrix**, so their output is byte-compatible. You
  therefore **cannot "fix" the matrix and remain PAR2-compatible** — fixing it is precisely what
  makes par3 a new, incompatible format. ModernPAR must keep the legacy matrix for PAR2.

---

## 6. PAR1 (parchive 1.0) — brief, for completeness

Spec: <https://parchive.sourceforge.net/docs/specifications/parity-volume-spec-1.0/article-spec.html>.
MacPAR deLuxe handles PAR1 via its Intel `par` helper (`.par` / `.pNN`). PAR1 is legacy but
ModernPAR must still read/verify/recover it.

- **Signature**: `PAR` + 5 NUL bytes (`50 41 52 00 00 00 00 00`) at offset 0.
- **Header (little-endian)**: version (8 B; low dword `0x00010000` for v1.0, high dword =
  program id), **Control Hash** (16 B MD5 of bytes `0x20`..EOF), **Set Hash** (16 B), number of
  files (8 B), file-list offset (8 B), file-list size (8 B), data offset (8 B), data size (8 B).
- **File entry** (per file, in the file list): entry size (8 B), status flags (8 B; bit0 =
  "saved in parity set," bit1 = "verified"), file size (8 B), full-file MD5 (16 B), 16k MD5
  (16 B), then the **UTF-16** filename (no path; length = `(entry_size − 0x38)/2`).
- **Set Hash** = MD5 over the concatenation of the full-file MD5s of all files whose status
  bit0 is set.
- **Recovery**: whole-file, byte-parallel **Reed-Solomon over GF(2^8)**. For `n` files and `m`
  parity volumes, byte vectors `D1..Dn` (taken from the same offset across files, smaller files
  zero-padded to the largest) yield checksums `C1..Cm`; `C1` lives in `.p01`, `C2` in `.p02`, …
  Each parity volume is the size of the **largest** input file. Reference algorithm: Plank
  CS-96-332.
- **Naming**: index `.PAR`; parity volumes `.P00`,`.P01`,…,`.P99`, then `.Q00`… The `.PAR`
  data area holds a Unicode comment; each `.PXX` data area holds parity bytes.
- **Hard limit**: files + parity volumes < 256 (i.e. **≤ 255**), because GF(2^8) only has 256
  field elements. This is the core reason PAR2 exists.

---

## 7. Engine / library options (usable from a Swift macOS app)

| Option | Lang | License | Create | Verify | Repair | macOS arm64 | Maintenance | Notes |
|--------|------|---------|:--:|:--:|:--:|:--:|------------|-------|
| **par2cmdline-turbo** (animetosho) | C++11 | **GPL-2.0-or-later** | ✅ | ✅ | ✅ | ✅ prebuilt arm64 **and** universal | **Active** — v1.4.0, Feb 2026 | par2cmdline core + ParPar SIMD GF16/MD5/CRC backend; C++11 threads (no OpenMP) → static builds; fastest *full* engine |
| **par2cmdline** (Parchive, "official") | C++ | **GPL-2.0** | ✅ | ✅ | ✅ | ✅ (Homebrew ships arm64; local v1.1.1 confirmed) | Active — v1.1.1, Feb 2026 | The reference. Needs LLVM/OpenMP on mac for threads; slower than turbo |
| **libpar2** | C++ | **GPL-2.0** | ✅ | ✅ | ✅ | ✅ (built with par2cmdline) | Tied to par2cmdline | Same repo as par2cmdline; **not a clean documented public API** — it's the extracted internal lib. Linkable but you're coding against C++ internals |
| **ParPar** (animetosho) | JS + native C++ (node-gyp) | **Public Domain / CC0** | ✅ | ❌ | ❌ | ✅ NEON | **Active** | **Create-only.** Best-in-class create speed and the GF16 backend that turbo borrows. Fundamentally a Node.js tool; native modules aren't a standalone C lib |
| **gopar** (akalin) | Go | **BSD-3-Clause** | ✅ | ✅ | ✅ (PAR1 **and** PAR2) | ✅ (Go cross-compiles) | Low / hobby (no releases) | Clean, readable, permissive. Cgo-callable from Swift is awkward; treat as a *reference reading* of the algorithm, not a drop-in. Compatibility "best-effort," not battle-tested at par2cmdline's scale |
| **Pure-Swift RS engine** (build it) | Swift 6 | yours | DIY | DIY | DIY | ✅ native | n/a | Full control, native concurrency/SIMD via `simd`/Accelerate; but you must re-implement GF(2^16), the *exact* legacy matrix, the sliding-CRC matcher, and pass interop tests. High effort, high risk |
| (context) **par2j** / MultiPar | C++ | closed-ish | ✅ | ✅ | ✅ | Windows only | Active | Not usable on mac; relevant only as the de-facto compatibility yardstick |

Sources: turbo <https://github.com/animetosho/par2cmdline-turbo> + releases API (confirmed
assets `par2cmdline-turbo-1.4.0-macos-arm64.zip` and `-macos-universal.zip`); par2cmdline
<https://github.com/Parchive/par2cmdline> (v1.1.1, GPL-2.0); ParPar
<https://github.com/animetosho/ParPar> (CC0/PD, create-only, NEON/SVE); gopar
<https://github.com/akalin/gopar> (BSD-3-Clause).

### License implications for a shipped Mac app
- **GPL-2.0** (par2cmdline / turbo / libpar2): linking it into ModernPAR makes the linked
  binary GPL. *(Superseded 2026-06-09 — see `research/08` §2: the subprocess split is NOT
  "App-Store-safe"; it protects the app code's license but Apple's Usage Rules attach to any
  bundled GPL binary regardless of process boundary, and the MAS sandbox forbids spawning bundled
  CLIs. ModernPAR resolved this by itself going GPL-2.0-or-later and embedding the engine
  in-process.)* The subprocess pattern — **ship the engine as a separate executable and invoke it
  as a subprocess** (the original MacPAR deLuxe already shells out to `par2SL`/`par`) — keeps the
  GPL covering the bundled binary rather than your Swift UI as a derived work, provided you keep
  it at arm's length (separate process, documented CLI boundary, source/offer for the GPL binary
  included). *Not legal advice — confirm before release.*
- **CC0/PD** (ParPar) and **BSD-3** (gopar) are permissive and App-Store-friendly, but ParPar
  is create-only and gopar isn't a production engine.

---

## 8. Recommendation for ModernPAR

**Primary: wrap `par2cmdline-turbo` as a bundled subprocess.** Reasons:
1. It is the **fastest correct full engine** (SIMD GF16/MD5/CRC from ParPar) and is **actively
   maintained** (v1.4.0, Feb 2026), unlike the stagnant Intel `par2SL` MacPAR deLuxe shipped.
2. It already ships **prebuilt macOS arm64 and universal binaries**, and its C++11-threads /
   static-build design avoids the OpenMP/LLVM headache that plain par2cmdline has on macOS — so
   ModernPAR can bundle a self-contained, notarizable helper with no runtime dependency on
   Homebrew/Rosetta. This directly solves the "breaks when Rosetta retires" problem.
3. It speaks the **standard par2cmdline CLI** MacPAR deLuxe already relied on (`-b -s -r -c -f
   -u -l -n -m -t`), so ModernPAR's create/verify/repair option mapping is a near-direct port of
   the documented `par2SL` contract in `00-source-notes.md`. The `-t` thread flag replaces the
   old GCD parallelization and honors the "limit CPU cores" preference.
4. Wrapping a proven engine sidesteps the entire RS-matrix-compatibility minefield: you
   inherit byte-for-byte interop with every other PAR2 tool for free.

**Architecture**: bundle `par2cmdline-turbo` (and a PAR1 helper — see below) inside
`ModernPAR.app/Contents/Helpers/`, drive it with Swift `Foundation.Process` /
`AsyncProcess`, parse its stdout for progress and the per-file status taxonomy MacPAR deLuxe
surfaced (OK / renamed / missing-recoverable / bad-checksum / recovered / etc.). Keep the GPL
helper as a clearly-separated process with its source/offer in the bundle.

**Native parsing layer (do this in Swift regardless of engine):** implement a **read-only
PAR2/PAR1 parser in pure Swift** for the document model — packet scanning, header MD5
validation, Main/FileDesc/IFSC decoding, set/file IDs, block-size and redundancy display, and
recovery-file naming. This powers the document UI, the file-status list, and "need N more
blocks" math *without* shelling out, and it's low-risk because parsing has no compatibility
trap (only writing/repair does). Pure read parsing is the natural place to start.

**PAR1**: par2cmdline-turbo does **not** do PAR1. Options, in preference order: (a) a small
pure-Swift PAR1 verify/recover (GF(2^8) RS over ≤255 files is tractable and well-specified —
gopar's PAR1 code is a good reference and BSD-licensed); (b) port the legacy `par` helper to
build natively for arm64. Given PAR1 is rare and simple, **(a) a native Swift PAR1 path** is the
cleaner long-term choice and removes the last Intel binary.

**Reconsider a pure-Swift PAR2 engine only later**, if: GPL/App-Store distribution becomes a
hard blocker, or you want a single universal codebase. It's feasible (GF(2^16) + the legacy
Vandermonde matrix + Gauss-Jordan + sliding-CRC matcher are all documented above) but it is a
multi-month effort that must pass extensive cross-tool interop tests, and you'd be
re-implementing exactly the math turbo already does faster. **Don't start here.**

**Net**: subprocess-wrap par2cmdline-turbo for PAR2 create/verify/repair; pure-Swift for all
read/inspect and for PAR1; revisit a Swift PAR2 engine only if licensing forces it.
