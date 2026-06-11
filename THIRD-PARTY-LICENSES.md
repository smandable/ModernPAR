# Third-party components & licenses

ModernPAR bundles or links the following third-party components. This index is reproduced in the
app's About panel. See `docs/ARCHITECTURE.md` §0–§1 for the licensing posture and `COPYING` /
`docs/licenses/` for the full texts.

| Component | Version | License | How ModernPAR uses it | Distribution constraint |
|---|---|---|---|---|
| **par2cmdline-turbo** (animetosho) | 1.4.0 *(decided pin; vendored in Phase 2)* | GPL-2.0-or-later | PAR2 create/verify/repair, **embedded in-process** (vendored source behind an exception-catching C shim — primary, Phase 2), with a bundled-CLI subprocess engine as the designed-in fallback. In-process linking is license-clean because **ModernPAR is itself GPL-2.0-or-later**. | Developer-ID / notarized direct download only. **Not** Mac App Store (Apple's Usage Rules are GPLv2 §6 "further restrictions" — see `docs/research/08`). Corresponding source for the whole work is published per GPL §3. |
| **RARLAB UnRAR** | unrarsrc 7.2.4 *(decided pin; vendored in Phase 4)* | UnRAR license (free for *extraction*; forbids building a RAR-compatible **archiver**) | RAR decompression (RAR 2/3/5, multi-volume, SFX, password), linked in-process via a C shim. **ModernPAR never creates .rar archives.** | The verbatim UnRAR `license.txt` paragraph is reproduced below and in About. Non-OSI / field-of-use restricted. |
| **libarchive** | system (macOS) | BSD-2-Clause | zip extraction (and optional 7z read). System library; not redistributed. | None. |

> **Legal review is required before any public release.** This file records engineering intent,
> not legal advice (see `docs/research/07-verification.md`, Claim 1 & 2).

## Corresponding source (GPL §3)
The exact `par2cmdline-turbo` source revision bundled with each ModernPAR release, plus any patches,
will be published alongside the release (tag) so recipients can obtain the corresponding source.

## UnRAR attribution (mandatory, verbatim)

Per the UnRAR license, the following paragraph is reproduced verbatim (it also appears in the
app's Settings → Unrar acknowledgements and in the source comments of `CUnrar`):

> UnRAR source code may be used in any software to handle
> RAR archives without limitations free of charge, but cannot be
> used to develop RAR (WinRAR) compatible archiver and to
> re-create RAR compression algorithm, which is proprietary.
> Distribution of modified UnRAR source code in separate form
> or as a part of other software is permitted, provided that
> full text of this paragraph, starting from "UnRAR source code"
> words, is included in license, or in documentation if license
> is not available, and in source code comments of resulting package.

## Notes
- `COPYING` in the repo root is **ModernPAR's own license** (GPL-2.0-or-later) and also covers the
  vendored par2cmdline-turbo engine.
- RARLAB UnRAR is **GPL-incompatible** (non-OSI field-of-use restriction); it is kept in its own
  component/translation units (`Packages/PARKit/Sources/CUnrar/`, vendored in Phase 4 with two
  documented local patches — see `CUnrar/vendor/VENDORED.txt`), documented as a
  separately-licensed part, and never combined into the GPL engine's link unit. This coexistence
  is the top pre-release legal-review item.
- The full RARLAB UnRAR license ships verbatim at
  `Packages/PARKit/Sources/CUnrar/vendor/unrar/license.txt` (and `docs/licenses/UnRAR-license.txt`).
