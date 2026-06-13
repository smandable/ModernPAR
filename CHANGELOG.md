# Changelog

All notable changes to ModernPAR are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.1]: https://github.com/smandable/ModernPAR/releases/tag/v0.1.1
[0.1.0]: https://github.com/smandable/ModernPAR/releases/tag/v0.1.0
