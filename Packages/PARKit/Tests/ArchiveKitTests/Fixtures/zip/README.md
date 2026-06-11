# Zip extraction fixtures

Coverage for the Phase 5 `ZipExtractor` (system libarchive): plain/stored/
deflate zips, nested + unicode names, single-top-level placement, both zip
encryption schemes, and hostile inputs.

## Built locally (2026-06-11, macOS `/usr/bin/zip` + `python3 zipfile`)

- `plain.zip` — `file1.txt` (20 B) + `file2.txt` (84 B), deflate; two
  top-level items → wrapper-folder placement.
- `subdirs.zip` — single top-level `sub/` containing `dir with space/
  nested.txt` and `üñïçødé/файл.txt` → direct placement, no wrapper.
- `stored.zip` — `file1.txt`, method=store.
- `zipcrypto.zip` — `secret.txt` (15 B) + `file1.txt`, traditional PKZIP
  (ZipCrypto) encryption, password `password`.
- `traversal.zip` — crafted: `good.txt` plus entries named `../escape.txt`
  and `nested/../../escape2.txt`; extraction must deliver `good.txt` and
  refuse to write outside the staging root.
- `absolute.zip` — crafted: an entry named `/tmp/abs-escape.txt` plus
  `ok.txt`; the absolute path must not be honored.
- `truncated.zip` — first 130 bytes of `plain.zip` (cut inside the second
  entry's local data; a central-directory-only cut is invisible to a
  streaming reader).
- `not-a-zip.zip` — plain text, no zip signature.

## Added after the Phase 5 adversarial review (regressions for confirmed findings)

- `streaming-unset-size.zip` — data-descriptor (bit-3) entries written to an
  unseekable stream, then the EOCD signature corrupted so libarchive uses its
  STREAMING reader (sizes unset at header time). Must extract the real bytes,
  not write 0-byte files and report success.
- `lying-size.zip` — STORED `liar.txt` whose declared uncompressed size (10)
  is smaller than its real data (40 bytes) → `archive_write_data_block`
  returns ARCHIVE_WARN. Must be a per-file failure, not a whole-run abort;
  `honest.txt` after it must still extract.
- `symlinks.zip` — `good.txt` plus an absolute symlink (`abs_link →
  /etc/passwd`) and an escaping symlink (`escape_link → ../../../../tmp/evil`);
  both unsafe links must be skipped (like the RAR engine), `good.txt`
  extracted, run successful.
- `staging-name.zip` — a single entry under `.ModernPAR-extract-evil/`; the
  staging-prefix top-level component must be refused so it cannot be reaped by
  a later run's stale-staging sweep.

## From the libarchive test corpus (BSD-2-Clause)

`aes128.zip` / `aes256.zip` are `test_read_format_zip_winzip_aes{128,256}.zip`
from libarchive v3.7.4 (`libarchive/test/*.uu`, uudecoded; password
`password`, single `README` entry of 6818 bytes):
https://github.com/libarchive/libarchive/tree/v3.7.4/libarchive/test
