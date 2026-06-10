# Competitive / Comparison Analysis — PAR/Recovery + Extraction Landscape

> Research doc for **ModernPAR** (native arm64 macOS, Swift 6.3 / SwiftUI, Xcode 26), a modern
> reimplementation of **MacPAR deLuxe 5.1.1**. This surveys the cross-platform PAR/recovery and
> archive-extraction landscape and distills the UX patterns, engine choices, and capabilities that
> ModernPAR should adopt, skip, or improve on. Ground truth for the original app's feature set lives
> in [`00-source-notes.md`](./00-source-notes.md); this doc does not restate that inventory, only
> compares it against the wider field.
>
> Date of research: **2026-06-09**. Version/maintenance facts are accurate as of this date and
> should be re-checked before locking architectural decisions.

---

## TL;DR for the design agent

- **The reference modern GUI is MultiPar (Windows).** ModernPAR's GUI feature bar should be measured
  against MultiPar, not against the 2018 MacPAR deLuxe. MultiPar is still actively maintained
  (v1.3.3.6, March 2026) and defines the "good par2 GUI" expectation: verification levels,
  misnamed/relocated file detection via SFV/MD5, recursive scan with subfolder controls, GPU offload.
- **The reference modern engine is `par2cmdline-turbo` (animetosho).** It is the same lineage as the
  original `par2SL` (both fork Peter Clements' par2cmdline) but adds SIMD across x86/ARM/RISC-V,
  C++11 threads, and — critically for us — an **Apple-Silicon-optimized CLMul GF16 kernel**. GPL-2.0.
  This is the single most important "learn from / reuse" target for ModernPAR's engine layer.
- **The dominant real-world workflow is Usenet post-processing** (SABnzbd / NZBGet): download →
  par2 QuickCheck → selective par2 repair → unrar → move. ModernPAR's "verify→repair→auto-unrar→
  post-process" pipeline (inherited from MacPAR deLuxe) mirrors this exactly and is the right model.
- **Extraction-app UX bar is set by Keka / The Unarchiver / BetterZip.** Native Apple Silicon,
  dark mode, drag-drop, password reuse, encoding detection, destination-conflict policies. ModernPAR
  already has these semantics in spec; it should match their *polish*.
- **unrar licensing is a real constraint.** The unRAR source can decode RAR freely but its license
  forbids using it to build a RAR *creator* and requires a notice. ModernPAR only extracts, so it is
  compliant, but the notice obligation and the "no re-creating RAR compression" clause must be honored.

---

## 1. MacPAR deLuxe — the thing we are replacing

| | |
|---|---|
| Platform | macOS, **Intel x86_64 only** (built Xcode 10 / 10.14 SDK) |
| Latest version | **5.1.1** (© 2002–2018 Gerard Putter); no Apple Silicon build ever shipped |
| Price | Freeware + optional donation (shareware nags) |
| Engine(s) | `par2SL` (GCD-parallelized par2cmdline fork), `par` (PAR1 helper), `libUnrar.dylib` |
| Status | Effectively abandoned; runs only under Rosetta 2 today |

**History & why it's stuck on Intel.** Gerard Putter has shipped MacPAR deLuxe for ~18 years; it
evolved from an AppleScript Studio app into a Cocoa app and was, for a long stretch, *the* macOS PAR2
GUI — free, notarized, and "runs well on Catalina."
([Eclectic Light Co.](https://eclecticlight.co/2020/04/16/file-integrity-4-error-correcting-code-is-available-for-macos/)).
The last release (5.1.1, 2018) predates Apple Silicon and the Xcode toolchains that emit arm64. With
no source-level modernization since, it is a pure Intel binary; it still launches today only because
**Rosetta 2** translates it. Apple has signaled Rosetta 2 will be removed (broadly expected around the
macOS 28 / 2028 timeframe), at which point the app stops launching entirely
([RosettaCheck listing](https://rosettacheck.com/apps/j2kh3889);
[MacUpdate](https://macpar-deluxe.macupdate.com/)). That deadline is ModernPAR's reason to exist.

**Lessons:** The feature *model* (auto verify→repair→post-process, document-based, per-file status
icons, retry-recovery, rule-based extraction) is genuinely good and worth preserving wholesale. What's
dead: the Intel binary, the custom XML auto-updater, Crashlytics/Fabric, StuffIt rules, donation nags,
PAR1 emphasis. The biggest *missed* modernization is the engine: `par2SL` was a GCD fork of an old
par2cmdline and never got the SIMD/Apple-Silicon work that `par2cmdline-turbo` now provides for free.

---

## 2. MultiPar (Windows) — the modern reference par2 GUI

| | |
|---|---|
| Repo / home | https://github.com/Yutaka-Sawada/MultiPar (migrated from Vector.co.jp Dec 2024) |
| Latest version | **1.3.3.6**, released **2026-03-01** (author calls v1.3.3 near-final) |
| Platform | Windows only |
| License | Freeware; engine `par2j` is closed-ish but free; GUI included |
| Formats | **PAR1, PAR2, and (experimental) PAR3** |

MultiPar is the de-facto "best par2 GUI" and the right yardstick for ModernPAR's feature surface
([GitHub](https://github.com/Yutaka-Sawada/MultiPar);
[release listing / MajorGeeks](https://www.majorgeeks.com/files/details/multipar.html)). Notable
capabilities that ModernPAR should consider matching:

- **Configurable verification levels** — quick vs. full vs. "additional verification" that hunts for
  *misnamed or relocated* files using sidecar `.SFV` and `.MD5` checksums. (MacPAR deLuxe already does
  rename detection; the SFV/MD5 cross-check is an extra ModernPAR could add.)
- **Recursive directory scan** with an option to *exclude* subfolders for speed — directly addresses
  MacPAR deLuxe's "many unrelated files slows the scan" warning, but as a user-tunable knob.
- **GPU acceleration** in the engine (`par2j64.exe`), though recent NVIDIA driver issues pushed the
  author to recommend the 64-bit path; GPU offload remains finicky (mirrors ParPar's OpenCL caveats).
- **Batch processing** of multiple sets, rich parameter customization, detailed in-app help manual.
- Niche additions like **FLAC fingerprint (ffp)** support — evidence the author keeps extending it.

**Lessons for ModernPAR:** Adopt verification levels and the recursive-scan-with-exclusions control.
Treat GPU as *optional and off-by-default* (everyone who ships it warns about driver instability).
The closed engine and Windows-only nature are the gap ModernPAR fills on the Mac side.

---

## 3. QuickPar (Windows) — the classic, now abandonware

| | |
|---|---|
| Home | http://www.quickpar.org.uk/ |
| Status | **Unmaintained since 2004** (~21 years); superseded by MultiPar; effectively abandonware |
| Formats | PAR1 + PAR2; Reed-Solomon ECC |

QuickPar defined the original Usenet-era PAR2 GUI workflow (create parity, verify, auto-repair from
damaged files + PAR volumes) and was the tool MacPAR deLuxe emulated on the Mac side. It is now a
historical reference only ([Wikipedia](https://en.wikipedia.org/wiki/QuickPar)). **Lesson:** the core
interaction model it pioneered (drop files → status grid → one-click repair) is still the right one;
nothing new to learn beyond confirming the established mental model.

---

## 4. Engines: par2cmdline, par2cmdline-turbo, ParPar

### 4a. par2cmdline (official Parchive) — the baseline CLI

- Repo: https://github.com/Parchive/par2cmdline ; **license GPL-2.0**; current line **1.x (≈1.1.0)**.
- The reference implementation and the option vocabulary the whole ecosystem speaks (`c/v/r`,
  `-b`, `-s`, `-r`, `-c`, `-n`, `-m`, etc.) — exactly the contract `par2SL` exposes in MacPAR deLuxe.
- **Maintenance:** revived from a stalled SourceForge project, now on GitHub with PR/issue activity
  through 2025, though a "migration to GitHub not complete" issue is still open
  ([Parchive/par2cmdline](https://github.com/Parchive/par2cmdline)). Solid but *not* speed-optimized.

### 4b. par2cmdline-turbo (animetosho) — the engine ModernPAR should target ⭐

| | |
|---|---|
| Repo | https://github.com/animetosho/par2cmdline-turbo |
| License | **GPL-2.0** |
| Latest release | **v1.4.0 (2026-02-09)**; 8 releases, ~940 commits; actively maintained |
| Scope | Drop-in par2cmdline replacement (create **and** verify/repair), CLI-compatible |

This is the single most important engine for ModernPAR. It keeps close to upstream par2cmdline and
diverges *only* on performance, folding in the ParPar computational backend
([GitHub](https://github.com/animetosho/par2cmdline-turbo)):

- **SIMD GF16 / MD5 / CRC32** with automatic CPU dispatch across x86 (SSE2, SSSE3, AVX2, AVX512BW,
  **GFNI**), ARM (**NEON, SVE, SVE2**), and RISC-V Vector.
- **Apple-Silicon-specific path:** v1.1.0 added an **M1-optimized CLMul GF16 kernel** — i.e. the work
  to make par2 fast on arm64 Macs is already done and maintained upstream
  ([release notes](https://github.com/animetosho/par2cmdline-turbo/releases)).
- **C++11 threads** replacing OpenMP (enables fully static builds; no libgomp dependency).
- **RAM error checksumming during GF16**, stitched MD5+CRC32 hashing, accelerated matrix inversion
  (v1.1.0 added SIMD/multi-thread matrix inversion).
- Distributes prebuilt binaries for macOS/Windows/Linux; SABnzbd ships and documents it as the
  recommended engine ([SABnzbd wiki](https://sabnzbd.org/wiki/installation/par2cmdline-turbo)).

**Implication:** ModernPAR's "DROP/MODERNIZE" note about possibly writing a SIMD C++ par2 engine is
mostly already solved. The pragmatic path is to **embed/wrap par2cmdline-turbo** (statically linked,
arm64-native) rather than ship the stale `par2SL`. The GPL-2.0 license must be reconciled with App
Store distribution (see Risks).

### 4c. ParPar (animetosho) — fastest creator, create-only

| | |
|---|---|
| Repo | https://github.com/animetosho/ParPar ; **license Public Domain / CC0** |
| Language | C++/C core + Node.js API/CLI |
| Latest | actively developed (~1,400 commits); ParParGUI front-end **v0.4.5 (2025-01-21)** |
| Scope | **Creation only** — "consider par2cmdline-turbo if you need verify/repair" |

ParPar is the fastest known PAR2 *creator* and the source of par2cmdline-turbo's backend. It adds
experimental **OpenCL GPU offload** (`--opencl-process`, disabled by default, explicitly "unstable" —
static CPU/GPU partitioning, buggy drivers, at-your-own-risk)
([README](https://github.com/animetosho/ParPar/blob/master/README.md)). Its **public-domain/CC0**
license is far friendlier than GPL if ModernPAR ever wants to vendor *creation* code without GPL
obligations — but it does not verify or repair, so it cannot stand alone. ParParGUI exists but is a
thin Node front-end, not a UX reference.

> **Engine takeaway:** par2cmdline-turbo for verify/repair (and it can create too); ParPar only if a
> license-clean, max-speed *creator* fast path is wanted. The benchmark page exists
> ([ParPar benchmarks](https://github.com/animetosho/ParPar/blob/master/benchmarks/info.md)) but
> publishes results as chart images (4570S, 12700K) rather than text; the consistent claim across all
> sources is ParPar > par2cmdline-turbo > MultiPar's par2j > stock par2cmdline on creation throughput.
> Treat exact ratios as un-cited; the *ordering* and the Apple-Silicon SIMD advantage are well
> established.

---

## 5. Other PAR tools (smaller / niche)

| Tool | Lang / Platform | License | Scope & status | Relevance to ModernPAR |
|---|---|---|---|---|
| **par2deep** | Python (PyPI), Tk GUI (was PyQt5) | GPL-ish | Recursive create/verify/repair; **v1.10 dropped its own libpar2 and now bundles `par2cmdline-turbo`** (Win/Linux/macOS, x86_64 **and arm64**) | Confirms turbo is the community-standard cross-platform engine; the "one par2 per file, move files freely" model is a nice power-user feature idea |
| **gopar** | Go | — | Pure-Go par2; **broken UTF-8 filename support**, sidelined to a branch in par2deep | Cautionary: pure reimplementations lag on correctness (Unicode filenames) — argues for reusing turbo, not rolling our own |
| **pyParchive** | Python | — | Scripting-oriented par2/par wrapper | Low; scripting niche only |
| **phpar2** | PHP/C | — | Appears in ParPar benchmarks as a comparator | None beyond benchmark context |
| **rust-par2** | Rust | — | Experimental reimplementation | Watch-only; not production |
| **par3cmdline** | C | GPL | Official PAR3 prototype; spec still **ALPHA DRAFT (2022-01-28)**, not finalized as of 2025 | Future format target — see §8 |

Sources: [par2deep](https://github.com/brenthuisman/par2deep) /
[PyPI](https://pypi.org/project/par2deep/);
[par3cmdline](https://github.com/Parchive/par3cmdline).

**No maintained native-macOS/SwiftUI PAR2 GUI exists.** Despite searching, there is no current
Apple-Silicon-native SwiftUI par2 app (no "Mala" PAR tool surfaced; the only Mac GUI is the Intel
MacPAR deLuxe). The Mac options today are CLI-only: Homebrew/MacPorts `par2` (stock par2cmdline) or a
manually built par2cmdline-turbo. **This is ModernPAR's open market gap.**

---

## 6. The dominant real-world workflow: NZB / Usenet automation

SABnzbd and NZBGet are where par2 + unrar are used most heavily today, and they validate ModernPAR's
pipeline design:

- **SABnzbd** (Python, GPL, cross-platform incl. macOS) only downloads the PAR files it *needs*: it
  fetches the data + the smallest par2, runs a fast **QuickCheck**, and only if that fails does it run
  a full par2 verification, then selectively downloads *just enough* recovery blocks to repair, then
  unrars ([SABnzbd FAQ](https://sabnzbd.org/wiki/faq)). It ships **par2cmdline-turbo** as its engine.
- **NZBGet** (C++, GPL; community-maintained at nzbgetcom) follows the same shape: download to an
  intermediate dir → combine/verify (par2) → unpack RAR/7z → move to destination
  ([NZBGet folder guide](https://nzbget.com/documentation/nzbget-path-and-folder-structure-guide/)).
- **Operational gotcha worth designing around:** both communities report that throwing *more*
  par2 verification threads at the problem (`-t+`) can *hurt*, because verification is **disk-bound,
  not CPU-bound**, and threads fight over disk I/O
  ([SABnzbd forum](https://forums.sabnzbd.org/viewtopic.php?t=25678)). MacPAR deLuxe already exposes a
  "limit CPU cores" pref; ModernPAR should keep that and default sensibly (verify ≈ I/O-bound, repair/
  create ≈ CPU-bound — they want different concurrency).

**Lessons:**
1. The **QuickCheck-then-full-verify-then-selective-repair** progression is the gold-standard UX. The
   original's "remembers which files are OK, skip on retry" maps onto this; ModernPAR can present a
   fast pre-check before a full scan.
2. **par2 and unrar belong together** — every serious Usenet tool bundles both. ModernPAR's
   par2→auto-unrar coupling is exactly right and is the differentiator vs. a plain extraction app.
3. Don't over-thread verification; tie concurrency to operation type and let the user cap it.

---

## 7. Extraction apps — the modern macOS UX bar

ModernPAR's RAR/extraction half should match the polish of these mainstream Mac archivers
([Compresto roundup](https://compresto.app/blog/best-archive-tools-for-mac);
[MacPaw roundup](https://macpaw.com/reviews/best-unarchivers-mac)):

| App | Price | Notable for | Apple Silicon |
|---|---|---|---|
| **The Unarchiver** (XADMaster engine) | Free | Extraction-only; best-in-class **encoding detection for non-UTF-8 filenames**; broad/legacy format support; password-protected RAR/ZIP | Native ([theunarchiver.com](https://theunarchiver.com/)) |
| **Keka** | Free (site) / $4.99 MAS | Modern, sleek UI, dark mode; create *and* extract; benchmark-leading speed on M3/M4 | Fully Apple-Silicon-optimized |
| **BetterZip** | $24.95 | Power-user: **inspect/edit archives in place** without extracting; AES-256; broad formats | Native |

**Patterns ModernPAR should adopt:**
- **Native arm64, dark-mode-first, drag-drop everywhere** — table stakes in 2026.
- **Robust filename-encoding detection** (The Unarchiver's strength) — multi-volume RAR sets from
  Usenet/old archives often have non-UTF-8 names; libUnrar/the original handles RAR2/3/5 but encoding
  UX matters.
- **Password prompt once, reuse for the whole archive** — the original already does this; keep it.
- **Destination-conflict policy** (ask / overwrite / keep-both-rename / cancel) and **single-item =
  no wrapper folder, multi-item = named folder** — the original already does this; it matches Keka/
  Unarchiver behavior, so keep it as-is.
- **Preview-before-extract** (BetterZip) is a *nice-to-have*, lower priority for a recovery-first app.

**Engine/license note for RAR (critical):** The **unRAR** source may be used freely to *decode* RAR in
any software, **but** its license forbids using it to "develop a RAR (WinRAR) compatible archiver"
(i.e. no RAR *creation*, no reverse-engineering the compression), and requires a clear notice in docs
and source comments ([Fedora Licensing:Unrar](https://fedoraproject.org/wiki/Licensing:Unrar);
[7-Zip discussion of unRAR + LGPL](https://sourceforge.net/p/sevenzip/discussion/45798/thread/3464743ff8/)).
Because ModernPAR only *extracts* RAR (inheriting `libUnrar.dylib`'s role), it is compliant — but it
**must ship the required unRAR notice** and must not add RAR creation. Alternatives if a different
engine is wanted: **XADMaster** (LGPL, powers The Unarchiver) or **libarchive/bsdtar** (BSD; newer
`bsdtar` handles RAR5 decode but lacks filters/encryption support) — both arm64-native and avoid the
unRAR-source notice mechanics, though XADMaster has its own per-format provenance to track.

---

## 8. PAR3 — the future format (watch, don't block on it)

PAR3 (Parity Volume Set Spec 3.0) is authored by Michael Nahas (PAR2 spec author) with Yutaka Sawada
(MultiPar), animetosho (ParPar/turbo), and malaire. It removes PAR2's ceilings — **>2^16 files and
>2^16 blocks**, **packing small files into one block**, and **deduplication** when a block recurs
across files. As of the latest sources it remains an **ALPHA DRAFT dated 2022-01-28**, "near-final"
but not ratified, pending working code
([Wikipedia: Parchive](https://en.wikipedia.org/wiki/Parchive);
[Spec v3.0 draft](https://parchive.github.io/doc/Parity_Volume_Set_Specification_v3.0.html);
[par3cmdline discussion](https://github.com/Parchive/par3cmdline/issues/1)).

**Recommendation:** ModernPAR ships **PAR2-first** (matching MacPAR deLuxe and the entire installed
base). Architect the engine layer behind a protocol so a PAR3 backend can slot in later, but do **not**
gate v1 on PAR3 — the format isn't finalized and almost no files exist in the wild. MultiPar's
experimental PAR3 support is the canary to watch.

---

## 9. Feature comparison matrix

Legend: ● full / ◐ partial-or-experimental / ○ none / — n/a

| Capability | MacPAR deLuxe 5.1.1 | MultiPar | QuickPar | par2cmdline | par2cmdline-turbo | ParPar | SABnzbd/NZBGet | Keka/Unarchiver | **ModernPAR (target)** |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Platform | macOS Intel | Windows | Windows | x-plat CLI | x-plat CLI | x-plat CLI | x-plat | macOS | **macOS arm64** |
| GUI | ● (Cocoa) | ● (Win32) | ● | ○ | ○ | ◐ (ParParGUI) | ● (web) | ● | **● SwiftUI** |
| PAR2 create | ● | ● | ● | ● | ● | ● | ○ | — | **●** |
| PAR2 verify/repair | ● | ● | ● | ● | ● | ○ | ● | — | **●** |
| PAR1 | ● | ● | ● | ○ | ○ | ○ | ○ | — | ◐ (legacy, optional) |
| PAR3 | ○ | ◐ | ○ | ○ | ○ | ○ | ○ | — | ○ (future-proof slot) |
| SIMD / arm64 accel | ○ (GCD only) | ◐ (x86) | ○ | ○ | ● (NEON/SVE, **M1 kernel**) | ● | via turbo | — | **● (via turbo)** |
| GPU offload | ○ | ◐ | ○ | ○ | ○ | ◐ (OpenCL, unstable) | ○ | — | ○ (skip v1) |
| Rename/relocate detect | ● | ● (SFV/MD5) | ◐ | ◐ | ◐ | — | ◐ | — | **● (+ SFV/MD5?)** |
| Retry / incremental verify | ● | ● | ◐ | ○ | ○ | — | ● (QuickCheck) | — | **●** |
| RAR extraction | ● (libUnrar) | ○ | ○ | ○ | ○ | ○ | ● | ● | **●** |
| Multi-volume / SFX RAR | ● | ○ | ○ | ○ | ○ | ○ | ● | ● | **●** |
| Password-protected RAR | ● | ○ | ○ | ○ | ○ | ○ | ● | ● | **●** |
| Post-process rules/automation | ● | ◐ | ○ | ○ | ○ | ○ | ● (scripts) | ○ | **● (modernized)** |
| Notifications | ● (NC) | ◐ | ○ | ○ | ○ | ○ | ● | ◐ | **● (UserNotifications)** |
| Active maintenance (2026) | ○ | ● | ○ | ● | ● | ● | ● | ● | **● (new)** |
| License | freeware | freeware | freeware | GPL-2.0 | GPL-2.0 | CC0/PD | GPL | mixed | TBD (see Risks) |

---

## 10. What to adopt, improve, and skip

### Adopt (proven, expected)
- **Wrap `par2cmdline-turbo`** as the PAR2 engine (arm64-native, SIMD, M1 GF16 kernel, actively
  maintained) instead of resurrecting the stale `par2SL`.
- The MacPAR deLuxe **pipeline** — auto verify→repair→auto-unrar→rule-based post-process — is the same
  shape SABnzbd/NZBGet use and should be preserved.
- **QuickCheck-then-full-verify** progression for fast feedback; keep the "remembers OK files, skip on
  retry" behavior.
- Extraction UX from Keka/Unarchiver: native arm64, dark mode, drag-drop, **password-once reuse**,
  destination-conflict policy, single-vs-multi-item folder logic, **strong filename-encoding detection**.
- MultiPar's **verification levels** and **recursive scan with subfolder exclusion** control.
- Native **UserNotifications** with click-to-reveal-in-Finder (the original already does NC).

### Improve / modernize
- Replace the custom XML auto-updater with **Sparkle** (decided — MAS was later ruled out; see `research/08`).
- **Swift Concurrency** (async/await, actors) over bare GCD; tie verify concurrency (I/O-bound) vs.
  create/repair concurrency (CPU-bound) to operation type, with a user core cap (keep the original's
  "limit CPU cores" pref — it matters because over-threading verify hurts on spinning/network disks).
- **Sandbox + security-scoped bookmarks** for the "all files in one folder" model and post-process
  scripts; this is the hardest part of modernizing the rules engine (sandbox vs. arbitrary Terminal
  scripts).
- Surface PAR2 sizing (redundancy %, block size, recovery-file layout) with **live previews** of
  resulting .par2 file count/sizes — the original exposes the knobs but not the consequences.

### Skip / drop
- **GPU offload** for v1 — every implementation (MultiPar, ParPar) warns it's unstable and
  driver-dependent; not worth the support burden.
- **RAR creation** — legally blocked by the unRAR license; ModernPAR is extract-only by design.
- **PAR3** gating — track it, slot for it, don't ship-block on an unratified alpha spec.
- Crashlytics/Fabric, StuffIt rules, donation nags, PAR1-first defaults (keep PAR1 read support only
  for legacy, deprioritize create).

---

## Sources

- MacPAR deLuxe / macOS context: [Eclectic Light Co. — File Integrity 4](https://eclecticlight.co/2020/04/16/file-integrity-4-error-correcting-code-is-available-for-macos/), [RosettaCheck](https://rosettacheck.com/apps/j2kh3889), [MacUpdate](https://macpar-deluxe.macupdate.com/)
- MultiPar: [GitHub](https://github.com/Yutaka-Sawada/MultiPar), [MajorGeeks](https://www.majorgeeks.com/files/details/multipar.html)
- QuickPar: [Wikipedia](https://en.wikipedia.org/wiki/QuickPar), [quickpar.org.uk](http://www.quickpar.org.uk/)
- par2cmdline: [Parchive/par2cmdline](https://github.com/Parchive/par2cmdline)
- par2cmdline-turbo: [GitHub](https://github.com/animetosho/par2cmdline-turbo), [releases](https://github.com/animetosho/par2cmdline-turbo/releases), [SABnzbd install wiki](https://sabnzbd.org/wiki/installation/par2cmdline-turbo)
- ParPar: [GitHub](https://github.com/animetosho/ParPar), [README](https://github.com/animetosho/ParPar/blob/master/README.md), [benchmarks](https://github.com/animetosho/ParPar/blob/master/benchmarks/info.md)
- par2deep: [GitHub](https://github.com/brenthuisman/par2deep), [PyPI](https://pypi.org/project/par2deep/)
- PAR3: [Wikipedia: Parchive](https://en.wikipedia.org/wiki/Parchive), [Spec v3.0 draft](https://parchive.github.io/doc/Parity_Volume_Set_Specification_v3.0.html), [par3cmdline](https://github.com/Parchive/par3cmdline)
- Usenet workflow: [SABnzbd FAQ](https://sabnzbd.org/wiki/faq), [SABnzbd forum on par2 threads](https://forums.sabnzbd.org/viewtopic.php?t=25678), [NZBGet folder guide](https://nzbget.com/documentation/nzbget-path-and-folder-structure-guide/)
- Extraction apps: [Compresto roundup](https://compresto.app/blog/best-archive-tools-for-mac), [MacPaw roundup](https://macpaw.com/reviews/best-unarchivers-mac), [The Unarchiver](https://theunarchiver.com/)
- unRAR license: [Fedora Licensing:Unrar](https://fedoraproject.org/wiki/Licensing:Unrar), [7-Zip / unRAR discussion](https://sourceforge.net/p/sevenzip/discussion/45798/thread/3464743ff8/)
