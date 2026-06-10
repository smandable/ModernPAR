# Source Notes — MacPAR deLuxe 5.1.1 (ground truth from the installed bundle)

These notes were extracted directly from `/Applications/MacPAR deLuxe.app` (version 5.1.1,
© 2002–2018 Gerard Putter). They are the authoritative reference for what the original app does.
All other research should build on / not contradict this without explanation.

## What it is
A **document-based macOS GUI** (Cocoa, Intel x86_64, built with Xcode 10 / 10.14 SDK) that wraps
three command-line/native engines:

- `Contents/Helpers/par2SL` — PAR2 create/verify/repair. Banner: *"par2SL version 1.0,
  Copyright (C) 2003 Peter Brian Clements. Adapted for use with MacPar deLuxe by Gerard Putter…
  uses Grand Central Dispatch to optimize the speed and processor load."* → i.e. a **GCD-parallelized
  fork of par2cmdline**. Source published as `par2SL_Source.zip` on the author's site.
- `Contents/Helpers/par` — PAR1 check/recover/add (parchive-style). Has `c(heck)`, `r(ecover)`,
  `a(dd)`, `m(ix)` commands.
- `Contents/Frameworks/libUnrar.dylib` — RAR extraction (the unrar library, RAR 2.x/3.x/5.x).

Document classes (from Info.plist): `PAR1Document` (.par), `PAR2Document` (.par2),
`UnrarDocument` (.rar), `MyDocument` (any). NSPrincipalClass `ParApplication`. Bundle id
`nl.xs4all.gp.macpardeluxe`. Uses Crashlytics/Fabric for crash reporting.

## par2SL CLI (the PAR2 engine contract)
```
par2 c(reate) [options] <par2 file> [files]
par2 v(erify) [options] <par2 file> [files]
par2 r(epair) [options] <par2 file> [files]
  -b<n>  Block-Count          -s<n>  Block-Size (KB; not with -b)
  -r<n>  Redundancy %         -c<n>  Recovery block count (not with -r)
  -f<n>  First Recovery-Block-Number
  -u     Uniform recovery file sizes
  -l     Limit size of recovery files (not with -u)   -n<n> Number of recovery files (not with -l)
  -m<n>  Memory (MB) to use   -v/-q  verbosity
```
This is the standard par2cmdline option set — ModernPAR's engine must reproduce these semantics.

## par1 CLI
```
par c(heck) / r(ecover) / a(dd) / m(ix)
  -m move existing files aside   -r recover parity vols too   -f fix faulty filenames
  -p<n> files per parity vol  | -n<n> number of parity vols   -d find duplicates  -k keep broken
```

## Complete feature inventory (from Help + Localizable.strings)

### Verify / Repair (PAR2 and PAR1)
- Open a .par2 (or .par / .pNN) file → auto verify, then auto repair if needed.
- Reports per-file status with icons: OK / OK-after-rename / Missing / Missing-but-recoverable /
  Missing-not-recoverable / Bad-checksum / Bad-checksum-recoverable / Bad-checksum-not-recoverable /
  Recovered / Not-in-set / (PAR1) "did not contribute to parity data".
- Document-level status line: "All files checked out fine", "Cannot restore; need N more files",
  "Files restored successfully", "need %d more recovery blocks / data bytes", etc.
- **Retry recovery**: keep the window open; it remembers files already OK and skips them next run.
  Used after acquiring more recovery data.
- Scans *all* files in the folder for missing/renamed blocks (warns when folder has many unrelated
  files because that slows the scan — "ManyUnrelatedFilesWarning").
- Detects/handles files **renamed** vs the set.

### Create (PAR2 and PAR1)
- Add files via drag-from-Finder or "Add Files…"; all files must be in ONE folder; reject files
  with resource forks. Remove files from set.
- PAR2 create options: **redundancy %** (1–100), **block size** in KB (1–419430, or "Automatic"),
  **limit par2 file size** to largest data file, **uniform** vs **limited** recovery file sizes,
  number of recovery files. Limits: PAR2 ≤ 32768 files; PAR1 ≤ 255 files.
- PAR1 create options: number of pNN files (fixed, or derived from subject-file count).
- File naming convention surfaced to user: `Filename.volXXX+YY.par2` (XXX=first block, YY=count).

### Unrar (RAR extraction)
- Supported first-file forms: `.rar` + `.r00/.r01…` (RAR2.x); `.partNN.rar` (RAR3+);
  `.exe`/`.partNN.exe` self-extracting; `.001/.002…`. RAR5 supported (since v5.0).
- Manual "Unrar Archive…" (Cmd-U) or drop first file on dock icon; or automatic after a par2 check
  of a set that contains rar files.
- **Password-protected** archives: prompt once, reuse password for whole archive.
- Multi-item archives → extracted into a new folder named after the archive; single item → no folder.
- "Destination already exists" policy: ask / overwrite / keep-both(rename) / cancel.
- "After successful unrar" policy for the rar segments: move-to-trash (default) / leave / delete-permanently.
- "Keep incorrectly expanded (broken) files" option.
- Notification-center notification on each finish (success/fail), click → Show in Finder.

### Post-processing rules (extensible automation)
- After successful verify/repair, run rules matched by **filename pattern**. Default rules:
  `.rar`→built-in Unrar, `.zip`→OS unzip, `.sit/.sitx/.sit.1/.part01.sitx`→Stuffit.
- Rules evaluated top→bottom; first match wins; only one fires per set. User can add/edit/reorder/delete
  (except the built-in Unrar rule). Three action types: **open in Finder**, **open with chosen app**,
  **run a Terminal command-line script** (with macros, e.g. "A").
- "Automatically post-process after repair" toggle (else trigger manually from Process menu).

### Preferences (full list)
- **Basic**: auto-delete par/par2/pNN files (to trash) after success; close window after auto
  post-processing; default document type at launch (PAR1/PAR2); **Run unattended** (no dialogs; safe
  defaults: keep-both, empty password).
- **Par1**: number of pNN files (count-based or fixed).
- **Par2**: redundancy %; limit par2 file size to largest data file; block size (KB or Automatic).
- **Unrar**: keep broken files; unrar destination (same folder / ask each time / fixed folder);
  destination-exists policy; after-unrar segment policy.
- **Post-processing**: auto-post-process toggle; rules list editor.
- **Other**: auto-check for updates on launch; multi-file open policy (one-by-one queue vs
  simultaneous); **limit CPU cores** used for par2 (default = all cores).

### App-level / UX
- Toolbar: New, Open+Repair, Repair again, Add, Remove, Create par1, Create par2, Cancel,
  Preferences, Help, Homepage, Support(email), Donation, Quit.
- Cancel any running operation (Cmd-.). Quit disabled while busy.
- "Show/Hide par Output" (raw engine log view).
- Drag files into list; drop rar on dock icon; double-click .par2 to open.
- Copy selected file names to clipboard; "select all erroneous files".
- Alternating row colors in the file list. Status line at window bottom.
- Localized English + Dutch. Shareware donation nags (NOT needed for ModernPAR).
- Auto-update check against an xml version list (NOT needed; replace with Sparkle or none).

## Engine source pointers
- par2 (par2cmdline lineage): https://sourceforge.net/projects/parchive/ and the author's
  macOS-optimized `par2SL_Source.zip`. Modern actively-maintained fork to evaluate:
  **par2cmdline-turbo** (animetosho) — SIMD/multi-thread accelerated.
- par1: parchive.sourceforge.net.
- unrar: the RARLAB UnRAR source (note its license restrictions); alternative extraction via
  macOS **libarchive** or XADMaster/The Unarchiver.

## Things ModernPAR should DROP or MODERNIZE
- Drop: shareware donation nags, Crashlytics/Fabric, custom xml auto-updater, Stuffit/StuffitExpander
  rules (dead tech), PowerPC notes.
- Modernize: SwiftUI document-based app; sandbox + security-scoped bookmarks; native progress &
  notifications (UserNotifications); universal arm64+x86_64; Swift concurrency instead of bare GCD;
  optional Sparkle for updates; drag-drop via SwiftUI; possibly a pure-Swift or SIMD C++ par2 engine.

## Local environment (verified 2026-06-09)
- macOS 26.6 arm64, Xcode 26.5, Swift 6.3.2. Homebrew `par2` present at /opt/homebrew/bin/par2.
- Rosetta 2 currently present (the Intel `par` helper executed) — but the whole point is to not
  depend on it; ModernPAR must be native arm64.
