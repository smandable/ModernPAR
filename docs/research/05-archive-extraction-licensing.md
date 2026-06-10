# Archive Extraction (RAR / zip / 7z) Options + Licensing — for ModernPAR

**Scope:** Native-macOS (arm64, Swift 6.3 / SwiftUI, Xcode 26) options to replace MacPAR deLuxe 5.1.1's
`libUnrar.dylib` (RAR) + OS `unzip` (zip) extraction, with **exact license terms** and what each forbids.
Authoritative feature baseline: `docs/research/00-source-notes.md`.

> **Ground-truth recap (what we must reproduce):** RAR extraction across **RAR 2.x / 3.x / 5.x**,
> **multi-volume** (`.rar`+`.r00/.r01…`, `.partNN.rar`, `.001/.002…`), **self-extracting** (`.exe` /
> `.partNN.exe`), and **password-protected** archives (prompt once, reuse for the whole archive). Plus
> `.zip` via OS unzip. Stuffit/`.sit*` is explicitly **dropped** (dead tech) per source notes §"Things to DROP".

---

## TL;DR / Recommendation

| Format | Recommended engine | License | Covers the matrix? |
|---|---|---|---|
| **zip** | macOS **libarchive** (`/usr/lib/libarchive`, linked via `libarchive.2.tbd`) OR shell `ditto -x -k` / `unzip` via `Process` | BSD-2-Clause (libarchive) / Apple OS tools | Yes — incl. deflate, LZMA, AES/ZipCrypto, Zip64 |
| **RAR (extraction)** | **RARLAB UnRAR** source/library, bundled extraction-only, with mandatory attribution | UnRAR license (free, **non-OSI**, decompress-only) | **Yes** — only engine that does RAR5 + multi-volume + password reliably |
| **7z** (optional, not in original) | macOS **libarchive** | BSD-2-Clause | Yes (read) — but **not a MacPAR feature**, treat as bonus |

**Bottom line:** **Ship RARLAB UnRAR (extraction-only) for RAR, and macOS libarchive for zip.** This is
legally clean (the UnRAR license *explicitly permits* extraction-only use, including in commercial closed
apps, as long as you don't build a RAR-*compatible archiver* and you reproduce the attribution), native
arm64, and is the **only** route that covers RAR5 + multi-volume + password — which `libarchive`'s built-in
RAR reader cannot do. Do **not** rely on libarchive or XADMaster for RAR password/RAR5, and **drop** any
notion of *creating* RAR archives (legally forbidden, and not a MacPAR feature anyway).

---

## 1. RARLAB UnRAR source / library  ← the format-critical choice

### What it is
The official decompression-only RAR engine published by RARLAB (Alexander Roshal, author of WinRAR). It is
the same code MacPAR deLuxe wrapped as `libUnrar.dylib`. It is the **reference implementation** and the only
one that correctly handles every RAR variant including **RAR5**, **multi-volume**, **self-extracting (SFX)**,
and **password / encrypted-header** archives. Current version is **UnRAR 7.x** (7.13 as of Sep 2025).
Source mirror: <https://github.com/aawc/unrar> · upstream: <https://www.rarlab.com/rar_add.htm>.

### The license — exact key clauses (verbatim)
The decompression-only UnRAR license (the one that ships in `license.txt`) reads, in its operative part:

> **"The UnRAR sources may be used in any software to handle RAR archives without limitations free of
> charge, but cannot be used to re-create the RAR compression algorithm, which is proprietary. Distribution
> of modified UnRAR sources in separate form or as a part of other software is permitted, provided that it
> is clearly stated in the documentation and source comments that the code may not be used to develop a RAR
> (WinRAR) compatible archiver."**

Sources (consistent across all):
- 7-Zip canonical license text: <https://7-zip.org/license.txt>
- Oracle/TimesTen attribution copy: <https://docs.oracle.com/en/database/other-databases/timesten/22.1/licensing/7-zip.html>
- Fedora's analysis (quotes + classification): <https://fedoraproject.org/wiki/Licensing:Unrar>
- 7-Zip forum discussion of the clause: <https://sourceforge.net/p/sevenzip/discussion/45798/thread/3464743ff8/>

The full license has six short clauses (per Fedora's reproduction):
1. All copyrights to UnRAR are owned by Alexander Roshal (RARLAB).
2. The permitted-use + restriction clause quoted above.
3. Free distribution is permitted.
4. Software is provided **"AS IS"**, no warranty, author accepts no liability.
5. Installing/using UnRAR signifies acceptance of the license.
6. If you don't agree, you must remove all UnRAR files from your storage devices.

### What it permits vs forbids (decision-relevant reading)
- **PERMITTED:** Use the code in *any* software (including commercial, closed-source, App Store apps) to
  **extract/handle** RAR archives, free of charge, with no royalty. ModernPAR's use (decompress + list +
  extract, with password) is squarely inside this.
- **FORBIDDEN:** (a) Using the code to **re-create the RAR compression algorithm**, and (b) developing a
  **"RAR (WinRAR) compatible archiver"** — i.e. you may **not** ship the ability to *create* `.rar` files.
  This does not affect ModernPAR: MacPAR deLuxe never created RAR; it only ever extracted (the source notes
  list only an "Unrar" feature, never "create RAR").
- **Mandatory attribution:** If you distribute (modified or not) UnRAR sources as part of your app, you must
  state in your docs and source comments that the code may not be used to develop a RAR-compatible archiver.
  Practically: include the UnRAR `license.txt` in your app bundle's acknowledgements / "About" and keep the
  upstream comments. The library itself can be linked as a binary; ship the notice regardless.

### Licensing nuance — non-free but not copyleft
- The OSI/FSF/Fedora consider UnRAR **non-free** *only because of the field-of-use restriction* (can't build
  a compatible compressor). Fedora classifies it "BAD"/non-free and won't ship it — **but that is a free-
  software-distro policy concern, NOT a barrier to a proprietary/commercial macOS app.** For a closed-source
  Mac app the field-of-use restriction is irrelevant (you don't want to build a RAR compressor anyway).
  Source: <https://fedoraproject.org/wiki/Licensing:Unrar>.
- It is **not GPL-compatible**. *(Update 2026-06-09: this now IS our situation — ModernPAR itself
  is GPL-2.0-or-later, so UnRAR must be kept in its own separately-licensed component/translation
  units, never combined into the GPL engine's link unit — ARCHITECTURE.md §1.4. This coexistence
  is the top pre-release legal-review item.)* UnRAR sits beside the app code under its own terms.
- There is a **separate, more restrictive "UnRAR binary" EULA** for the prebuilt `unrar` command-line tool
  ("freeware… personal use" wording in some packagings). **Avoid that path.** Use the **source code**
  (`UnRARSrc`/`unrarsrc`) license above (the decompress-only library license), which is the permissive one.
  Build the dylib yourself from source so you're unambiguously under the source license.

### Notarization / distribution implications
- **No special notarization problem.** UnRAR is a normal C++ library; compiled into a `.dylib` (or static
  lib) and embedded in `Contents/Frameworks`, it is code-signed and notarized like any embedded binary.
  Hardened Runtime is fine (no JIT, no special entitlements needed).
- **Sandbox / App Store:** A *library* (preferred) is fine in the App Store sandbox. The pitfall is shipping
  the **`unrar` executable** and `Process`-spawning it — sandboxed apps cannot exec arbitrary helper binaries
  without an `com.apple.security.inherit`-style XPC/helper arrangement, and an embedded executable adds
  signing friction. Keka hit exactly this class of problem when un-sandboxing to call CLI unrar:
  <https://github.com/aonez/Keka/issues/1389>. **Link the library, don't spawn a CLI.**
- **Precedent:** Keka (free, Mac App Store + Developer ID) bundles RARLAB UnRAR and explicitly credits it
  ("Updated UNRAR … Thanks to rarlab"). This is the standard, accepted pattern for a shipping Mac app.
- **arm64:** Builds cleanly for Apple Silicon from source (it's portable C++; just compile with
  `-arch arm64`, or universal). No Intel/Rosetta dependency — this is the whole point of ModernPAR.

### How to integrate (Swift)
- Build UnRAR from `unrarsrc` as a static lib or `.dylib` (`make lib` produces `libunrar`).
- Expose the C API (`dll.hpp` — `RAROpenArchiveEx`, `RARProcessFileW`, `RARSetPassword`,
  `RARSetCallback`, etc.) via a small C/Obj-C++ shim, then a Swift wrapper. The callback mechanism is how you
  feed the password (`UCM_NEEDPASSWORDW`) and drive volume-change prompts (`UCM_CHANGEVOLUMEW`) — this is how
  multi-volume + password "prompt once, reuse" is implemented.
- Wrap in an SPM target with a module map, or an XCFramework. (`aawc/unrar` is a convenient source mirror.)

---

## 2. libarchive — built into macOS

### Availability on this machine (verified 2026-06-09)
- macOS ships libarchive; `bsdtar` reports **`libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8`**.
- The runtime dylib lives only in the dyld shared cache (no standalone `/usr/lib/libarchive.dylib` file
  visible — expected on modern macOS). **Link against the SDK stub**:
  `…/MacOSX.sdk/usr/lib/libarchive.2.tbd` (→ `libarchive.tbd` symlink). Confirmed present in the Xcode 26.5
  SDK and Command Line Tools SDK on this box.
- Apple does not ship the `archive.h` header in the SDK by default; **vendor the headers** (`archive.h`,
  `archive_entry.h` from libarchive 3.7.x) in your project and link `-larchive`. (Apple's own `bsdtar`/`tar`
  is the public consumer.) This is a well-trodden path but note Apple's build may lag upstream.

### Format support (libarchive 3.7.x)
- **zip (read+write):** uncompressed, **deflate, LZMA, XZ, BZIP2, ZSTD**; read-only **PPMd**; **Zip64**;
  **traditional PKZIP (ZipCrypto) encryption AND WinZip AES encryption** (read); Unix extra fields.
  → **zip extraction incl. encrypted is fully covered.**
  Source: <https://manpages.debian.org/unstable/libarchive-dev/libarchive-formats.5.en.html>
- **7-Zip (read+write):** supported.
- **RAR — the catch.** libarchive has **two** RAR readers:
  - `rar` (RARv3 / "rar4"): reads RARv3 archives that are uncompressed or use RARv3 compression methods, and
    SFX. (manpage above).
  - `rar5` (`archive_read_support_format_rar5.c`): reads RAR5. Source:
    <https://github.com/libarchive/libarchive/blob/master/libarchive/archive_read_support_format_rar5.c>
- **RAR limitations that disqualify it for our matrix:**
  - **NO decryption.** The rar5 reader *detects* encrypted entries (sets `has_encrypted_entries`, sees
    `EX_CRYPT`) but **does not implement decryption** — `archive_read_data_block` returns an
    "encryption not supported" error. Password-protected RAR is **not extractable**. The rar4 reader
    likewise does not handle passwords; bsdtar "does not support password-protected archives."
    Sources: <https://github.com/libarchive/libarchive/issues/151>,
    <https://github.com/libarchive/libarchive/issues/1374>,
    <https://github.com/libarchive/libarchive/issues/1662>.
  - **Multi-volume is fragile.** rar5 has a `multivolume` struct + volume-switch/block-merge logic, but
    libarchive's general posture is "does not support multi-volume archives," and multi-volume support is
    incomplete/buggy across formats. Source:
    <https://github.com/libarchive/libarchive/issues/277>.
  - **Reed-Solomon recovery records** are not supported by the rar5 unpacker (noted in source comments).
  - **No RAR writing** (irrelevant — we don't want it).
- **License: BSD-2-Clause** ("new"/simplified BSD). Permissive, **commercially redistributable, no copyleft,
  App-Store-clean**, no field-of-use restriction. Source: <https://github.com/libarchive/libarchive>.

### How to call from Swift
Streaming C API — wrap once and reuse:
```c
struct archive *a = archive_read_new();
archive_read_support_format_all(a);      // or _zip / _rar5 specifically
archive_read_support_filter_all(a);
archive_read_open_filename(a, path, 10240);
while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
    // archive_entry_pathname(entry); archive_read_data_block(...) -> write to disk
}
archive_read_free(a);
```
Expose via a C shim + Swift wrapper, or an SPM target with a module map that links `libarchive.2.tbd`.
**Recommended role: zip (and optional 7z) only — NOT RAR.**

---

## 3. XADMaster / The Unarchiver, and Keka's approach

### XADMaster (The Unarchiver's engine)
- Repo: <https://github.com/MacPaw/XADMaster> (Objective-C; latest tag ~1.10.8, Oct 2023; ~1044 commits;
  some 2024–2025 issue activity, but **low maintenance velocity**). Swift wrapper exists:
  <https://github.com/kumamotone/XADMasterSwift>.
- **License: LGPL-2.1.** Source: <https://directory.fsf.org/wiki/The_Unarchiver>,
  <https://en.wikipedia.org/wiki/The_Unarchiver>.
- **Formats:** Zip, Tar, Gzip, Bzip2, 7-Zip, **RAR (incl. split/multi-volume, and RAR5 per The Unarchiver
  3.11.1)**, LhA, StuffIt, CAB, LZX, etc. It is an independent clean-room-ish RAR reader (not RARLAB UnRAR),
  which is why it can be LGPL.
- **Caveats for ModernPAR:**
  - **LGPL friction on macOS:** LGPL requires that users be able to *relink* against a modified version of
    the library. For a **statically-linked** closed app this is a problem; you must either dynamically link
    (ship XADMaster as a separate, replaceable `.framework`/`.dylib` and provide your object files or a
    relink mechanism) or open-source the linkage. **App Store** distribution + LGPL **dynamic** framework is
    workable (the framework is a separate signed bundle) but adds compliance overhead and is a known gray
    area many vendors avoid. If ModernPAR itself is open-source (e.g. GPL/MIT), LGPL is trivial; if it's a
    closed commercial app, this is real friction.
  - **RAR5 / password fidelity:** XADMaster's RAR support is good but is a third-party reimplementation; edge
    cases (newest RAR5 features, certain encryption modes, exotic multi-volume splits) historically lag
    RARLAB's reference. For a tool whose *whole job* is reliable recovery+extraction, fidelity matters.
  - **Obj-C, modest maintenance**, but it does build for arm64.
- **Verdict:** Viable **only if ModernPAR is itself open-source** (then it's the cleanest "all-formats, no
  field-of-use restriction" engine). For a closed/commercial app, the LGPL relink obligation makes it less
  attractive than UnRAR's simple attribution requirement.

### Keka's approach (the relevant precedent)
- Keka (popular Mac archiver) **bundles RARLAB UnRAR** for RAR (credits "rarlab"), and uses 7-Zip/p7zip-
  derived code for 7z/zip/etc. It ships on both the Mac App Store and via Developer ID. This confirms the
  recommended pattern: **UnRAR (library) for RAR + a permissive engine for everything else.**
- Keka's un-sandbox + CLI-unrar experiment shows the failure mode to avoid (spawning the unrar *binary* under
  sandbox/codesigning): <https://github.com/aonez/Keka/issues/1389>. **Use the library API, not a CLI exec.**

---

## 4. p7zip / 7-Zip and RAR support

- **p7zip is obsolete/unmaintained** (last real release ~2016; the official line is "p7zip is an obsolete
  port of 7-Zip to POSIX"). Source: <https://sourceforge.net/projects/p7zip/>. Prefer upstream **7-Zip**
  (which now has official Linux/macOS builds and can compile arm64 for macOS) if you ever need it.
- **License:** 7-Zip is mostly **LGPL-2.1-or-later**, parts **BSD-3-Clause**, and the **RAR codec carries the
  UnRAR field-of-use restriction** (same clause as §1). So 7-Zip does **not** escape the UnRAR restriction
  for RAR — it embeds UnRAR-derived code. Source: <https://7-zip.org/license.txt>,
  <https://en.wikipedia.org/wiki/7-Zip>.
- **RAR via 7-Zip:** Reads RAR incl. RAR5 and (with the bundled codec) decompression + password. But there's
  a build switch `DISABLE_RAR_COMPRESS=1` to exclude "not-fully-free" RAR code; with it, 7-Zip can only list /
  extract *stored* (uncompressed) RAR entries. So you're back to needing the UnRAR-restricted codec for real
  RAR. Source: <https://7-zip.org/license.txt> discussion.
- **Verdict:** No license advantage over directly bundling RARLAB UnRAR (you inherit the *same* UnRAR
  restriction), plus LGPL relink obligations and an obsolete POSIX port. **Don't use p7zip for RAR.** If you
  ever want 7z *extraction*, prefer macOS **libarchive** (BSD, already on the system) over p7zip.

---

## 5. zip extraction — the easy part

All options are license-clean. In priority order:

1. **macOS libarchive** (BSD, §2). One engine for both zip and (optional) 7z; full deflate/LZMA/AES/ZipCrypto
   + Zip64 read support; programmatic, no subprocess, sandbox-friendly. **Recommended.**
2. **`ditto -x -k <zip> <dest>`** via `Process`. This is what Finder uses; preserves macOS metadata and
   avoids `__MACOSX` cruft better than `unzip`. Source: <https://ss64.com/mac/ditto.html>. Good fallback /
   matches MacPAR's "OS unzip" behavior closely. Sandboxing: spawning `/usr/bin/ditto` from a sandboxed app
   needs care (same exec caveat as unrar CLI) — prefer the library for App Store builds.
3. **`/usr/bin/unzip`** via `Process` — exactly what MacPAR did. Simplest, but legacy Info-ZIP, weaker
   metadata handling; only as a literal-compat fallback.
4. **Apple `AppleArchive`/`Compression` framework** — **NOT suitable for `.zip`.** AppleArchive produces/reads
   Apple's own `.aar` format (LZFSE/LZMA/LZ4/zlib), and the Compression framework operates on raw byte
   streams with **no knowledge of the zip container**. Apple's own docs/forums say to use libarchive for real
   zip. Sources: <https://developer.apple.com/documentation/applearchive/>,
   <https://developer.apple.com/forums/thread/681770>,
   <https://developer.apple.com/forums/thread/694893>.
5. Third-party Swift zip libs (ZIPFoundation — MIT; ZipArchive/SSZipArchive — MIT) are fine if you want a
   pure-Swift/SPM dependency, but redundant given libarchive is already on the system.

`NSFileCoordinator` is **not** an unzip API — it's a read/write coordination primitive; irrelevant to
extraction itself (you'd use it only to coordinate file access while writing output, optional).

---

## 6. Recommended extraction strategy for ModernPAR

**(a) legally clean · (b) native arm64 · (c) covers RAR 2/3/5 + multi-volume + SFX + password + zip**

1. **RAR → RARLAB UnRAR, built from `unrarsrc`, linked as a static lib / XCFramework, extraction-only.**
   - Covers RAR 2.x/3.x/5.x, multi-volume (`.rNN`, `.partNN.rar`, `.001…`), self-extracting `.exe`, and
     password (via `UCM_NEEDPASSWORDW` callback → "prompt once, reuse").
   - Legal: UnRAR source license explicitly allows extraction in any software free of charge; we never create
     RAR, so the field-of-use restriction is moot. **Bundle the `license.txt` notice** in About/acknowledgements
     and keep source comments — this satisfies the only obligation.
   - arm64: compiles natively; no Rosetta.
   - Distribution: link as a **library** (do not exec a CLI) → notarizes and sandboxes cleanly; matches Keka's
     shipping pattern.

2. **zip (and optional 7z) → macOS libarchive** (BSD), linked via the SDK `libarchive.2.tbd`, headers
   vendored. Programmatic, sandbox-friendly, supports encrypted zip too. Fallback: `ditto -x -k` for a
   Finder-identical behavior in non-sandboxed Developer-ID builds.

3. **One-time password prompt + volume-change handling** lives in the UnRAR callback; surface SwiftUI dialogs
   from there. Implement MacPAR's destination policies (ask / overwrite / keep-both / cancel) and the
   "keep broken files" / after-unrar segment policy in the Swift layer around the engine.

### Features to DROP or flag infeasible
- **Creating RAR archives** — **legally forbidden** by the UnRAR license and **not a MacPAR feature**. Drop
  entirely. (ModernPAR creates PAR1/PAR2 only; it never created RAR.)
- **Stuffit / `.sit` / `.sitx` post-processing rule** — dead tech; source notes already say drop it. (If ever
  needed, only XADMaster reads StuffIt — but skip it.)
- **RAR via libarchive/XADMaster/p7zip for the password+RAR5 path** — technically unreliable (libarchive can't
  decrypt; XADMaster/p7zip lag the reference). Don't use them for RAR; reserve libarchive for zip/7z.
- **Apple Compression/AppleArchive for zip** — infeasible (wrong container). Don't attempt.
- If ModernPAR must be **fully OSI-open-source with zero non-free deps**, then RAR support is the conflict
  point: you'd have to either (i) accept UnRAR as a non-free optional component (like VLC/many distros do via
  a separate download), or (ii) use LGPL XADMaster with dynamic linking. *(Decided 2026-06-09: ModernPAR is
  GPL-2.0-or-later open source but does not demand OSI-purity of bundled components — it **bundles UnRAR**
  as an isolated, separately-licensed extraction-only part, kept out of the GPL engine's link unit;
  ARCHITECTURE.md §1.4.)*

---

## Source list
- UnRAR license (canonical): <https://7-zip.org/license.txt> · Oracle copy: <https://docs.oracle.com/en/database/other-databases/timesten/22.1/licensing/7-zip.html>
- Fedora UnRAR classification + clauses: <https://fedoraproject.org/wiki/Licensing:Unrar>
- UnRAR source mirror (v7.x): <https://github.com/aawc/unrar>
- 7-Zip LGPL + UnRAR restriction discussion: <https://sourceforge.net/p/sevenzip/discussion/45798/thread/3464743ff8/> · <https://en.wikipedia.org/wiki/7-Zip> · <https://sourceforge.net/projects/p7zip/>
- libarchive formats manpage: <https://manpages.debian.org/unstable/libarchive-dev/libarchive-formats.5.en.html>
- libarchive repo / license (BSD-2): <https://github.com/libarchive/libarchive>
- libarchive RAR5 source: <https://github.com/libarchive/libarchive/blob/master/libarchive/archive_read_support_format_rar5.c>
- libarchive RAR/encryption gaps: <https://github.com/libarchive/libarchive/issues/151> · <https://github.com/libarchive/libarchive/issues/1374> · <https://github.com/libarchive/libarchive/issues/1662> · multi-volume: <https://github.com/libarchive/libarchive/issues/277>
- XADMaster / The Unarchiver (LGPL): <https://github.com/MacPaw/XADMaster> · <https://directory.fsf.org/wiki/The_Unarchiver> · <https://en.wikipedia.org/wiki/The_Unarchiver> · Swift wrapper: <https://github.com/kumamotone/XADMasterSwift>
- Keka UnRAR usage + sandbox/CLI pitfall: <https://github.com/aonez/Keka/issues/1389>
- Apple zip/AppleArchive: <https://developer.apple.com/documentation/applearchive/> · <https://developer.apple.com/forums/thread/681770> · <https://developer.apple.com/forums/thread/694893> · ditto: <https://ss64.com/mac/ditto.html>
- Local verification (2026-06-09): macOS ships `libarchive 3.7.4` (via `bsdtar`); SDK stub `…/MacOSX.sdk/usr/lib/libarchive.2.tbd` present in Xcode 26.5 + CLT SDK; `/usr/bin/{ditto,unzip,bsdtar,tar}` present.
