# RAR extraction fixtures

Real-world RAR archives spanning the format generations ModernPAR must
extract (ROADMAP Phase 4): RAR 1.5 / 2.02 / 3.x / 5.x, old-style (`.rNN`) and
new-style (`.partNN.rar`) multi-volume sets, password-protected data
(`-psw`), encrypted headers (`-hpsw`), solid archives, subdirectories, and
Unicode filenames.

## Provenance

All `*.rar` / `*.r00` / `*.r01` archives (except the three synthesized ones
below) come from the test corpus of the `rarfile` Python library by
Marko Kreen, pinned to commit `db1df339574e76dafb8457e848a09c3c074b03a0`:

  https://github.com/markokr/rarfile/tree/db1df339574e76dafb8457e848a09c3c074b03a0/test/files

License: ISC (see the rarfile repository's LICENSE). Redistribution of these
test files with this notice is permitted.

Every archive's matching `*.exp` file is rarfile's `dumparc` dump of the
expected entry metadata (names, sizes, CRC32, mtimes) — the ground truth the
ArchiveKit tests assert against. The password for every protected archive in
the corpus is `password`.

## Synthesized hostile fixtures (created here, 2026-06-11)

- `corrupt-data.rar` — `rar5-crc.rar` with 16 bytes XOR-flipped at offset
  1000 (inside packed data): headers list fine, extraction must fail the CRC
  check (bad data), not crash.
- `truncated.rar` — first 1200 bytes of `rar5-crc.rar`: archive cut mid-data.
- `not-a-rar.rar` — plain text with no RAR signature: must be rejected as not
  an archive.

Added after the Phase 4 adversarial review (regressions for confirmed findings):

- `corrupt-middle.rar` — `rar5-subdirs.rar` with bytes 144–151 XOR-flipped:
  the SECOND of four files is damaged; the two intact files AFTER it must
  still extract (the unrar.dll sticky-error bug aborted the loop there).
- `corrupt-encrypted.rar` — `rar5-psw.rar` with 16 bytes XOR-flipped at
  offset 1024 (inside encrypted stored data): with the CORRECT password this
  is data damage and must NOT be diagnosed as a wrong password (RAR5 has a
  password check value).
- `corrupt-header3.rar` — `rar3-comment-plain.rar` with one byte of
  file1.txt's header name flipped: genuine RAR 1.5–4.x header corruption must
  surface as damaged data (vendor patch 1 must not mask it).
- `truncated-header.rar` — first 240 bytes of `rar5-crc.rar` (cut inside the
  second file's header): must be reported as damage, never as a clean
  end-of-archive (vendor patch 2 regression).

`rar5-symlink-unix.rar` (from the rarfile corpus, same pin) regression-tests
the warning-skip path: its `random_link` entry targets `../random123`, which
the engine refuses as unsafe — the skip must not fail the whole extraction.
