# Changelog

All notable changes to ModernPAR are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Fixed a crash (and a related silent-non-repair) when verifying or repairing a PAR2 set that
  lists a file as a non-recovery member — an "other file" recorded in the set but not
  protected by it. A crafted or third-party `.par2` could make the in-process engine crash the
  whole app on any such file with content, and a set whose only intact recoverable member was
  reported alongside an intact non-recovery file could be declared repaired without actually
  repairing a damaged file. Non-recovery files are now handled correctly: shown as "not in
  set", never counted toward the recovery verdict, and never renamed or recreated as a repair
  target.
- When the recovery set is intact but a non-recovery ("other") file listed in the set is
  missing or unreadable, the status now reads "Only non-recoverable files are missing" instead
  of overstating "All files are correct", and the file's row stays "not in set" rather than
  showing a spinner that never resolves.
- The file list's "Blocks needed" column now shows how many recovery blocks each damaged
  or missing file needs; it always showed "—". PAR2 counts match par2cmdline's per-file report
  ("Found 91 of 100 data blocks" means 9 needed), take into account blocks found in other files
  (such as a partial copy under another name, or the backup an interrupted repair leaves
  behind), and clear once the file is repaired. A damaged or missing PAR1 file needs one block,
  since each PAR1 recovery volume restores one file.
- A PAR2 data file that is still present but holds none of its original data (overwritten or
  zero-filled) is now shown as damaged and reported as repaired afterwards. Before, its row
  kept a blank status and showed plain "OK" after the repair.
- Intact PAR2 files that can only be checked as a whole (empty files, or files whose block
  checksums are missing from the set) now show "OK" instead of a blank status.
- Creating a PAR2 set from files that included an empty (0-byte) file could record wrong
  checksums. Folders such as Documents and Downloads contain one (the hidden “.localized”
  file), as does any folder with a custom icon. The set then reported intact files as
  damaged, and repairing it rewrote them with shifted data, keeping the originals as
  “name.1”. Empty files are now left out of new PAR2 sets, as par2cmdline does, and the
  build window marks them before you create.
- If you made PAR2 sets with an earlier version from folders like these, turn off “Repair
  automatically after verifying” (Settings ▸ Basic) before opening them. If one reports
  damage you don't expect, delete that set's .par2 files and create the set again. If a
  repair already ran, each “.1” file is your intact original: delete the rewritten file and
  remove “.1” from the original's name.
- A file that changes size while a PAR2 set is being created, such as a download still in
  progress, now stops the create with a message. Before, the create finished with a set that
  could not verify or repair.
- A PAR2 create that failed because a set with the same name already existed deleted that
  existing set. It is now left untouched.

## [1.0.1] — 2026-09-15

Fixes for the sandbox folder-access flow, prompted by user reports on r/macapps: windows
stuck on "Waiting to start" with no folder picker, and a lock icon read as "unrar disabled".

### Fixed
- The one-time folder-access panel is now shown even when "Run unattended" is on. The grant
  is a one-time capability prompt (remembered across launches; a parent folder covers
  everything inside it), not a per-run dialog, and suppressing it left unattended users with
  a window that never started and a picker that never appeared.
- A declined or missing folder grant no longer leaves the window saying "Waiting to start".
  The status line now reads "Folder access needed", and a banner explains that Full Disk
  Access does not apply to a sandboxed app, with a **Grant Folder Access…** button. The same
  command is in the File menu.
- Extracting an archive (⌘U, drop, or Finder open) now asks for the folder grant *before* the
  destination panel, so two consecutive open panels no longer look like one dialog repeating.

### Changed
- The folder-access panel says why it is asking and that Full Disk Access does not apply, and
  the "Run unattended" caption notes that this one-time panel is still shown.
- The pinned "Built-in Unrar" rule now has a caption under the rule list explaining that the
  lock means "part of the app, always runs last" rather than "disabled".
- In-app Help has a "Folder access" section; the README has a matching FAQ.
- Added SECURITY.md with private vulnerability reporting instructions.

## [1.0.0] — 2026-06-13

ModernPAR 1.0 — the first stable release.

### Added
- The ModernPAR app icon, so the app finally has its own identity in the Dock, Finder,
  and the About window.

Everything from the 0.1.x line is here and stable: PAR2 and native PAR1 verify, repair,
and create; RAR and ZIP extraction; the automatic verify-repair-extract loop; and signed,
notarized Sparkle auto-updates.

## [0.1.2] — 2026-06-13

### Changed
- Software-update prompts now include a "What's New" summary: Sparkle's update dialog shows
  the release notes for each version, taken from this changelog and embedded in the signed
  appcast, so you can see what changed before installing.

## [0.1.1] — 2026-06-13

Cut to exercise the live Sparkle update channel end to end: an installed v0.1.0
detects this release, downloads the EdDSA-signed DMG, verifies the signature,
installs, and relaunches as 0.1.1. This is the final Phase 9 exit item — the
auto-update path validated against the production feed.

### Added
- This changelog.

There are no functional changes in this release; it exists to validate the
update channel.

## [0.1.0] — 2026-06-12

Initial public release — a native arm64 macOS rewrite of MacPAR deLuxe 5.1.1 in
Swift 6 + SwiftUI, no Rosetta required.

### Added
- PAR2 verify, repair, and create (par2cmdline-turbo 1.4.0 embedded in-process;
  `HelperProcessEngine` subprocess fallback behind the same protocol).
- Native PAR1 verify, repair, and create (pure-Swift GF(256) Reed–Solomon, every
  constant pinned against the original Intel `par`).
- RAR extraction (RARLAB UnRAR, extract-only) and ZIP extraction (system
  libarchive); legacy RAR filename-encoding recovery.
- The full MacPAR loop — open → auto-verify → auto-repair → post-process
  extraction — from drop, Open, ⌘O, and Finder double-click.
- Six preferences tabs with a rule editor; renamed-file detection; in-app Help.
- Sandboxed, Hardened-Runtime, notarized + stapled DMG with Sparkle 2 EdDSA
  auto-updates; Acknowledgements view carrying the GPL-2.0, UnRAR, and Sparkle
  license texts.

[1.0.1]: https://github.com/smandable/ModernPAR/releases/tag/v1.0.1
[1.0.0]: https://github.com/smandable/ModernPAR/releases/tag/v1.0.0
[0.1.2]: https://github.com/smandable/ModernPAR/releases/tag/v0.1.2
[0.1.1]: https://github.com/smandable/ModernPAR/releases/tag/v0.1.1
[0.1.0]: https://github.com/smandable/ModernPAR/releases/tag/v0.1.0
