# PAR1 golden fixture corpus

Ground truth generated with the original MacPAR deLuxe Intel `par` helper, run under Rosetta:

```
/Applications/MacPAR deLuxe.app/Contents/Helpers/par
```

- MacPAR deLuxe bundle version: **5.1.1** (binary md5 `37592e0caf2b789c080e65f0d703d076`, x86_64 Mach-O).
- The binary prints **no version banner** at all (no `--version`; running it bare prints usage only).
  It identifies itself solely through the client-id dword it writes into every PAR file (see below).
- All sets verified against the pinned PAR1 math (GF(2^8) poly 0x11D; volume `v` coefficient for
  1-based contributing file `j` = `j^(v-1)`; files zero-padded to the largest contributing size;
  volume 1 is plain XOR). Every volume of every set below byte-matches a Python recomputation.

## Verify-mode syntax (for cross-verifying sets our engine creates)

```
par c <file.par>          # "check" — exits 0 on success, prints per-file status
par a -n<N> <out.par> <files...>   # "add"/create — writes out.par + out.p01..p0N
```

`par c` output lines: `<name> - in PAR volume set` / `- not in PAR volume set`, then
`<name> - OK`, and a final `All files found`. Exit code 0 on a fully valid set.
There is no `par v`; `r(ecover)` and `m(ix)` also exist. Options can be negated with `+`
(e.g. `+i` = do NOT add following files to the parity volumes).

## Header facts observed (every file in this corpus)

- Magic `PAR\0\0\0\0\0`, version dword `0x00010000` at 0x08.
- **Client-id dword at 0x0C = `0x02000900`** (classic "par 0.9" client id). Write this to look native.
- File-entry md5 at +24 is the **full-file** md5; +40 is the **first-16KB** md5
  (identical for files ≤ 16 KB; for a 0-byte file both are the empty-input md5 `d41d8c...`).
- Volume files use **lowercase** extensions `.p01`, `.p02`, … (`.p06` is the highest generated here).
- File list is **sorted lexicographically by name** — NOT command-line order. (Probe: passing
  `zebra mango apple` and `zulu mike alfa echo` both produced sorted indexes.)
- The coefficient index `j` counts **contributing files only**, 1-based, in index (sorted) order;
  entries with status bit0 clear are skipped (confirmed by the `noncontrib/` set, where the
  non-contributing `extra.dat` sorts first yet the parity matches with `p.dat`=1, `q.dat`=2).

## Generation commands

Data files are deterministic. From inside each set directory (`$PAR` = path above):

### five-files/ — 5 sizes exercising zero-padding, 3 volumes
```python
specs = [("one.dat",17),("two.dat",50),("three.dat",100),("four.dat",150),("five.dat",230)]
for i,(name,size) in enumerate(specs):
    open(name,"wb").write(bytes((i*37 + k*11) % 256 for k in range(size)))
```
```
$PAR a -n3 fivefiles.par one.dat two.dat three.dat four.dat five.dat
```

### unicode/ — UTF-16 rosters: Cyrillic, NFC accents, non-BMP emoji
```python
open("Привет мир.dat","wb").write("привет мир\n".encode())
open("café-ümlaut.dat","wb").write("café ümlaut çédille\n".encode())
open("emoji-🎉.dat","wb").write("party 🎉 time\n".encode())
```
```
$PAR a -n2 unicode.par "Привет мир.dat" "café-ümlaut.dat" "emoji-🎉.dat"
```
The binary accepted the emoji name without mangling: stored in the roster as a UTF-16LE
**surrogate pair** (U+1F389 → D83C DF89). Accented names were passed in NFC and stored
**NFC** (APFS preserved the form; no NFD conversion happened). `par c` round-trips all three.

### single-volume/ — 2 files, 1 volume
```python
open("first.dat","wb").write(bytes((3*k+1) % 256 for k in range(40)))
open("second.dat","wb").write(bytes((5*k+2) % 256 for k in range(70)))
```
```
$PAR a -n1 single.par first.dat second.dat
```

### empty-file/ — zero-byte member among normal files
```python
open("empty.dat","wb").write(b"")
open("full.dat","wb").write(bytes((7*k+3) % 256 for k in range(64)))
open("tail.dat","wb").write(bytes((9*k+4) % 256 for k in range(33)))
```
```
$PAR a -n2 emptyset.par empty.dat full.dat tail.dat
```
The binary accepts empty files without complaint: status=0x1 (contributing), size=0,
both md5 fields = `d41d8cd98f00b204e9800998ecf8427e`. An all-zero column contributes
nothing to any volume, so parity equals the other files' combination.

### bigger/ — ~100KB pseudo-random largest file (chunking test), 2 volumes
```python
import random
rng = random.Random(42)                      # seed pinned; draw order matters
open("big.dat","wb").write(rng.randbytes(100000))
open("mid.dat","wb").write(rng.randbytes(5000))
open("small.dat","wb").write(rng.randbytes(1000))
```
```
$PAR a -n2 bigger.par big.dat mid.dat small.dat
```

### many-volumes/ — 4 files, 6 volumes (.p01–.p06, higher Vandermonde rows)
```python
open("zulu.dat","wb").write(bytes((k+1) % 256 for k in range(120)))
open("mike.dat","wb").write(bytes((2*k+1) % 256 for k in range(75)))
open("alfa.dat","wb").write(bytes((3*k+1) % 256 for k in range(48)))
open("echo.dat","wb").write(bytes((4*k+1) % 256 for k in range(200)))
```
```
$PAR a -n6 manyvol.par zulu.dat mike.dat alfa.dat echo.dat
```
(Passed in non-alphabetical order on purpose; index came out sorted: alfa, echo, mike, zulu.)

### noncontrib/ — file entry with status bit0 CLEAR (non-contributing)
```python
for n,s in [("p.dat",30),("q.dat",45),("extra.dat",20)]:
    open(n,"wb").write(bytes((6*k+5) % 256 for k in range(s)))
```
```
$PAR a -n2 noncontrib.par p.dat q.dat +i extra.dat
```
**The CLI can author non-contributing entries** via `+i`: `extra.dat` is written with
status = **0x0** (bit0 clear, no other bits set), full md5s and size still present.
`par c` reports it `not in PAR volume set` but still hash-checks it and exits 0.
Parity covers only `p.dat` (j=1) and `q.dat` (j=2). Here the volume dataSize is 45
(largest file = largest contributing file); see `noncontrib-large/` for the case
where the non-contributing file is the largest.

### noncontrib-large/ — non-contributing file is the LARGEST in the roster
```python
open("s1.dat","wb").write(bytes(range(25)))
open("s2.dat","wb").write(bytes(range(40)))
open("huge.dat","wb").write(bytes((k*13+7)%256 for k in range(500)))
```
```
$PAR a -n2 pad.par s1.dat s2.dat +i huge.dat
```
**Quirk pinned by this set:** the volume data area is sized to the largest file in the
roster **including non-contributing entries** (dataSize = 500 here), but the parity
content is computed over contributing files only — the first 40 bytes equal the
s1/s2 parity, the remaining 460 bytes are zero fill. Verified byte-exact for both
volumes. A create implementation that sizes volumes by the largest *contributing*
file will NOT be byte-identical to the original on such sets.

## Status-bit summary

- Contributing file: status dword64 = `0x1`.
- Non-contributing (`+i`): status = `0x0`. No other status bits were ever observed.

## Quirks

- No version banner anywhere; rely on client id `0x02000900`.
- Volumes are created highest-first (`.p03` before `.p01` in output) — irrelevant on disk.
- `par` re-sorts the roster; argv order is never preserved.
- `--` forces remaining args to be treated as files; `+i` applies to all following files.
- The original top-level set (`archive.par` + `alpha.dat`/`beta.dat`) predates this corpus
  and must remain byte-identical; new sets live in subdirectories.
