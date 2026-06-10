# 08 — Mac App Store Eligibility & Engine Alternatives (Decision Doc)

Decision research for **ModernPAR** (native arm64 macOS, Swift 6.3 / SwiftUI / Xcode 26). This
document answers two questions the project keeps circling back to:

1. **Can ModernPAR ship on the Mac App Store (MAS) today?**
2. **If not, can the PAR2 engine be replaced — does a permissive engine exist, or must we
   clean-room a Swift one — and is that worth doing?**

It is decisive and cited. It builds on, and is consistent with, the *decided* posture in
[`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) §0/§10 and [`docs/ROADMAP.md`](../ROADMAP.md)
Decision 1/2/6, and on the format/engine detail in
[`03-par2-format-and-algorithm.md`](./03-par2-format-and-algorithm.md),
[`05-archive-extraction-licensing.md`](./05-archive-extraction-licensing.md),
[`06-build-distribution.md`](./06-build-distribution.md), and the adversarial checks in
[`07-verification.md`](./07-verification.md).

> **DECIDED (2026-06-09, project owner):** **Option A adopted** — ModernPAR ships Developer-ID /
> notarized only; **no MAS edition is planned**. (Option B is shelved, not rejected — this document
> remains the playbook if MAS ever becomes a business priority.) The owner also confirmed
> **ModernPAR itself is licensed GPL-2.0-or-later**, which resolved §6's "either way GPL" fork in
> favor of the **in-process embed** as the primary engine integration (ROADMAP Decision 2;
> ARCHITECTURE.md §0). Per the §6 recommendation, the native Swift parser + VERIFY layer (Phase 1)
> lands regardless; the clean-room REPAIR/CREATE engine and XADMaster swap are unscheduled.

> **Legal caveat, stated once and meant throughout:** this is engineering research, not legal
> advice. Every license/compatibility conclusion below (GPL-vs-MAS, the UnRAR field-of-use
> reading, LGPL relink obligations, CC0/public-domain reuse) must be confirmed by counsel before
> any release decision is acted on. The action item from doc 07 — "obtain a real legal review
> before release" — stands and is amplified here.

---

## 1. TL;DR — can ModernPAR be on the Mac App Store today?

**No.** As currently architected, ModernPAR is blocked from MAS by **two components — one
structural and imposed, one softer and chosen**: (1) the **GPL-2.0-or-later PAR2 engine**
(par2cmdline-turbo) — Apple's Mac App Store distribution terms impose "further restrictions"
that GPLv2 §6 forbids, the exact conflict that got GNU Go and VLC pulled; and (2) **RARLAB
UnRAR's non-OSI field-of-use license**, which muddies a clean MAS licensing posture. The PAR2
engine is the **structural, gating blocker**; RAR is the *softer* one (RAR *extraction* is
provably shippable on MAS — The Unarchiver and Keka both ship it today — so RAR is solvable by
choosing a different engine). The single highest-leverage change for MAS eligibility is therefore
a **clean-room, non-copyleft PAR2 engine linked in-process**; that one change clears the GPL
conflict and (because it removes any spawned/aggregated GPL binary) the sandbox/bundled-helper
problem at the same time.

---

## 2. The two blockers

### Blocker B1 — GPL (the par2 engine). Structural and fatal.

par2cmdline-turbo is **GPL-2.0-or-later** (07 Claim 1; verified at the source: the repo `COPYING`
is GPLv2 text but every source header — e.g. `src/par2cmdline.cpp` — grants "either version 2 …
or (at your option) any later version," so the accurate SPDX id is `GPL-2.0-or-later`). The
conflict with MAS is precise and primary-sourced:

- **GPLv2 §6 (verbatim):** "Each time you redistribute the Program … the recipient automatically
  receives a license from the original licensor to copy, distribute or modify the Program subject
  to these terms and conditions. **You may not impose any further restrictions** on the
  recipients' exercise of the rights granted herein."
  (<https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>)
- **Apple imposes exactly such further restrictions.** Every MAS app ships under the Licensed
  Application EULA + Apple Media Services "Usage Rules": a non-transferable license usable only
  "on any Apple-branded products that you own or control," a per-Apple-Account device cap (up to
  10 devices / max 5 computers), a personal-noncommercial-use limitation, and a
  no-copy/no-reverse-engineer clause. (Apple EULA
  <https://www.apple.com/legal/internet-services/itunes/dev/stdeula/>; Usage Rules
  <https://www.apple.com/legal/internet-services/itunes/us/terms.html>.)
- **The FSF's position is explicit and on-point.** The 2010 GNU Go action: "Apple imposes
  numerous legal restrictions on use and distribution … through the iTunes Store Terms of
  Service, which is forbidden by section 6 of GPLv2."
  (<https://www.fsf.org/news/2010-05-app-store-compliance>) The follow-up names the concrete
  forbidden restrictions — the device-count Usage Rule and the DRM "security technology that
  limits your usage" — and stresses the Usage Rules attach to App Store software "no matter how
  the software is licensed."
  (<https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement>) **VLC**
  (GPL-2.0-or-later) was pulled from the App Store in Jan 2011 over the same conflict; the only
  route back was **relicensing** (engine → LGPL-2.1-or-later in Oct 2011; iOS app under MPL-2.0 in
  2013) — **not** process isolation.
  (<https://www.fsf.org/blogs/licensing/vlc-enforcement>)

**The subprocess-firewall nuance (the part the team most often gets wrong).** The GPL "license
firewall" — running the GPL engine over a `Foundation.Process` boundary so that an app's *own*
code is "mere aggregation" rather than a GPL-derived combined work (the interim posture of earlier
ARCHITECTURE.md §0 drafts; now the standby fallback) — **protects a code license, but does not
confer MAS eligibility.** These are two orthogonal questions:

- The process boundary is a **copyright-scope device**: it keeps our Swift code from becoming a
  GPL derivative work (avoids the static-linking combined-work problem).
- MAS eligibility turns on a **different** thing: the *distribution terms imposed on the package
  Apple ships*. The Usage Rules attach to **any** GPL binary inside the `.app` Apple distributes,
  "no matter how the software is licensed" — regardless of process or link boundary. So if the
  GPL `par2` binary is inside the bundle Apple redistributes, Apple is redistributing a GPL work
  under prohibited further restrictions, and the §6 violation stands. (In short: the firewall
  solves copyright scope, not Store eligibility — they are orthogonal. Cf. 07 Claim 1.)

> Stated as a slogan so the team stops conflating them: **"Protects our code's license" and
> "allowed to ship via MAS" are different questions. The subprocess split answers only the
> first.** This holds *whichever* GPL integration ModernPAR adopts — the in-process embed of
> ROADMAP Decision 2 (now the decided primary) makes the whole app GPL (more obviously blocked),
> and the subprocess firewall (now the standby fallback in ARCHITECTURE.md §0) would keep an app's
> own code out of GPL scope but *still* ships a GPL binary in the MAS package. Both are
> MAS-blocked; the firewall just changes *which* concern it answers.

**Two independent, additive sub-blockers even if you ignored the §6 conflict:**

- **Sandbox / bundled-helper rules.** App Review Guideline 2.4.5 (verbatim): macOS apps "must …
  be self-contained, single app installation bundles and cannot install code or resources in
  shared locations" (2.4.5(ii)); "may not … spawn processes that continue to run without consent
  after a user has quit the app" (2.4.5(iii)); "may not download or install standalone apps,
  kexts, additional code, or resources" (2.4.5(iv)). And 2.5.2: apps "should be self-contained in
  their bundles, and may not … download, install, or execute code which introduces or changes
  features or functionality." (<https://developer.apple.com/app-store/review/guidelines/>) A
  sandboxed MAS app **cannot `exec` an arbitrary bundled CLI** at all — the very
  "`Foundation.Process` driving a `par2` helper" design is non-conforming on the Store on
  *sandbox/exec grounds before the GPL question is even reached* (07 Claim 1, independent repo
  corroboration; doc 06 §3a). This is the often-stronger, license-independent blocker.
- **The takedown risk is live and asymmetric.** The GPL-vs-MAS conflict has never been litigated
  to judgment, and Apple does in practice tolerate some GPL-adjacent apps. But enforcement is the
  *copyright holder's takedown right* — and that right ended GNU Go and VLC. Any par2cmdline-turbo
  copyright holder (animetosho, or upstream Clements-lineage authors) could file a takedown and
  Apple would pull the app. "Apple might not notice" is not a defensible distribution strategy for
  a shipping product. Treat B1 as a true blocker, not a gray area.

> **The one escape that does not apply to us:** because turbo is GPL-2.0-**or-later**, a copyright
> holder *could* grant a GPLv3 §7 "App Store exception" (the additional-permission mechanism real
> projects use). The reason ModernPAR cannot use it is simply that **we are not the copyright
> holder** and cannot grant that permission for turbo (cf. 07 Claim 1). So the practical
> conclusion ("no MAS") is right; the precise reason is "we can't obtain the permission," not "the
> GPL forbids it, full stop."

### Blocker B2 — UnRAR (the RAR engine). Softer, and solvable by engine choice.

The RAR engine ModernPAR has selected — **RARLAB UnRAR source (`unrarsrc` 7.2.4), linked
in-process** (ARCHITECTURE.md §1.4; 05) — carries a **non-OSI field-of-use restriction**: the
code "cannot be used to re-create the RAR compression algorithm" and "may not be used to develop a
RAR (WinRAR) compatible archiver," with mandatory attribution. Fedora classifies it **non-free**
*solely* on that field-of-use clause. (<https://fedoraproject.org/wiki/Licensing:Unrar>; 05 §1;
07 Claim 2.)

The important honesty here: UnRAR is **not the same kind of blocker as GPL.** It is **not
copyleft** and imposes **no redistribution/usage restriction on end users** — so it does not
collide with Apple's Usage Rules the way the GPL does. In fact **Keka ships on MAS today with
RARLAB UnRAR linked**, which is direct proof Apple's review accepts it
(<https://apps.apple.com/us/app/keka/id470158793>;
<https://github.com/aonez/Keka/wiki/Rar-compression>; 07 Claim 2). The project's earlier docs
(doc 06 §3; ROADMAP Decision 6 before its 2026-06-09 update, which now records this corrected
framing) listed UnRAR as MAS-disqualifying, and that is the right *posture*
for a clean licensing story — but the *mechanism* is "non-OSI field-of-use muddies a clean MAS
license + GPL-incompatibility with the par2 engine," not "Apple bans it." The accurate framing:
**UnRAR is a blocker we have chosen to treat as one, and it is removable by switching RAR engines;
GPL par2 is a blocker imposed on us that we cannot remove without replacing the engine.**

> **Do not misread Keka's sandbox limitation.** Keka's wiki notes the sandboxed MAS build has "no
> RAR *compression* support" because of "restrictions in access to external binaries." That
> concerns RAR **creation** (which needs a separate `rar` binary the sandbox can't reach) — **not
> extraction.** ModernPAR never creates RAR (MacPAR deLuxe only ever extracted; ARCHITECTURE.md
> §1.4), so this never affects us. It *does* reinforce that the sandbox forbids spawning external
> binaries — the same fact that kills the par2 subprocess design for MAS (B1). (07 Claim 2 risk;
> 05.)

---

## 3. What MAS would require — the checklist to clear both blockers

A re-architected ModernPAR *could* go on MAS. Nothing about the PAR2 or RAR problem domains is
inherently MAS-incompatible once the GPL engine is gone. To get there, all of the following must
hold (the first is the gate; the rest follow from it):

- [ ] **B1 — Replace the GPL par2 engine with a permissive / own engine, linked in-process.**
      A **clean-room MIT/BSD/Apache PAR2 implementation** written *from the public spec* (no
      par2cmdline/turbo source lineage) — see §4–§5. This simultaneously clears the §6 conflict
      *and* the sandbox/bundled-helper conflict (no spawned/aggregated GPL binary), *and* removes
      the GPL source-disclosure obligation. **This is the gating prerequisite; everything else is
      downstream of it.**
- [ ] **B2 — Replace RARLAB UnRAR with a MAS-clean RAR reader, linked in-process.**
      Two proven routes (both live on MAS today, both in-process libraries — *not* spawned
      binaries):
      - **XADMaster (LGPL-2.1)** — The Unarchiver's engine; an *independent clean-room* RAR reader
        with **zero RARLAB UnRAR code** (07 Claim 2). Handles RAR up to v5, multi-volume, and
        **AES data-encrypted** archives (but **not header-encrypted** RAR — issue #148). MAS-clean
        only if linked as a **separately-relinkable dynamic framework** (LGPL relink obligation; a
        known gray area). (<https://apps.apple.com/us/app/the-unarchiver/id425424353>;
        <https://github.com/MacPaw/XADMaster>.)
      - **libarchive (BSD-2-Clause)** — ships with macOS, fully permissive. But its RAR readers
        **cannot decrypt** ("Encryption is not supported" returns `ARCHIVE_FATAL` in
        `archive_read_support_format_rar5.c`), are fragile on multi-volume, and ignore RAR
        Reed-Solomon recovery records. (<https://github.com/libarchive/libarchive>.)
      - *Note:* Keka's UnRAR-on-MAS precedent shows UnRAR **could** also clear review — but it
        keeps the non-OSI field-of-use dependency in the tree, which is exactly the "clean
        licensing" property a MAS rewrite is trying to buy. For a MAS build, prefer XADMaster (or
        libarchive) and accept the RAR-fidelity regression (§6, Option B).
- [ ] **B3 — App Sandbox ON** (already specced and feasible *once the engine is in-process*):
      `app-sandbox` + `files.user-selected.read-write` + `files.bookmarks.app-scope` + the
      security-scoped-bookmark round-trip for dropped/dock URLs. **ModernPAR already does this** for
      the Developer-ID build (ARCHITECTURE.md §5; doc 06 §4c) — it is not new work, it just becomes
      *possible to satisfy without a helper-spawn exception* once nothing is spawned.
- [ ] **B4 — Drop Sparkle.** MAS handles updates; Sparkle is neither allowed nor needed. Remove it
      for the MAS build (doc 06 §6).
- [ ] **B5 — MAS hygiene.** Replace Developer-ID signing with Apple Distribution / App Store
      provisioning; submit through App Store Connect; pass Apple review. Accept the 15–30%
      commission and review latency/rejection risk.

**RAR extraction on MAS is a solved, demonstrated problem** — The Unarchiver and Keka are existence
proofs (07 Claim 2). So B2/B3/B4/B5 are routine. **The entire difficulty of MAS is B1.**

---

## 4. PAR2 engine alternatives — does a mature permissive engine exist?

**Plainly: no.** There is **no mature, permissively-licensed, embeddable, full create+verify+repair
PAR2 engine.** Every battle-tested full engine is copyleft; the only permissive *full* engine is an
unmaintained hobby project; the rest are partial. The table:

| Engine | Language | License | Create | Verify | Repair | Maintained? | Usable as a permissive in-process lib? | macOS arm64 |
|---|---|---|:--:|:--:|:--:|---|---|:--:|
| **par2cmdline** (Parchive, reference) | C++ | **GPL-2.0(-or-later)** | ✅ | ✅ | ✅ | Yes (v1.1.1, Feb 2026) | ❌ copyleft — in-process linking makes the whole app GPL | ✅ |
| **par2cmdline-turbo** (animetosho) | C++11 | **GPL-2.0-or-later** | ✅ | ✅ | ✅ | Yes (v1.4.0, Feb 2026) | ❌ copyleft | ✅ prebuilt arm64 + universal |
| **par2cmdline-tbb** (ifsnop fork) | C++ | **GPL-2.0-or-later** | ✅ | ✅ | ✅ | Largely superseded by turbo | ❌ copyleft | (Intel-oriented) |
| **libpar2** (Parchive standalone) | C++ | **GPL-2.0** | ✅ | ✅ | ✅ | **Dead** (archived 2015, last commit 2006) | ❌ copyleft + no clean public API | n/a |
| **MultiPar / par2j** (Y. Sawada) | C++ | **GPL** | ✅ | ✅ | ✅ | Yes (beta) | ❌ copyleft + Windows-only | ❌ |
| **ParPar** (animetosho) | JS + native C/C++ | **CC0-1.0 / Public Domain** | ✅ | ❌ | ❌ | Yes (May 2026) | ⚠️ **create-only**; a Node tool, not a C lib — but its **GF16 SIMD math is reusable permissively** | ✅ NEON |
| **gopar** (akalin) | Go | **BSD-3-Clause** | ✅ | ✅ | ✅ (PAR1+PAR2) | **No** (last commit 2021, 0 releases, hobby) | ⚠️ permissive but **unproven**; Go ↔ Swift cgo awkward → use as **reference**, not dependency | ✅ (cross-compiles) |
| **rust-par2** (AusAgentSmith-org) | Rust | **MIT OR Apache-2.0** | ❌ | ✅ | ✅ | Brand-new (v0.1.x, Mar 2026, 1 author) | ⚠️ permissive but **immature**: verify+repair only, x86-only SIMD, single-recovery-set assumption | (x86-only SIMD) |
| **par3cmdline / par3lib** (Y. Sawada) | C/C++ | **LGPL-2.1-or-later** | ✅ | ✅ | ✅ | Yes, but **alpha**, **PAR3-only** | ⚠️ LGPL (relinkable in principle) but **no mature PAR2 path**; PAR3 spec still draft | builds Linux/Windows |
| **Pure-Swift engine** (build it) | Swift 6 | **yours (permissive)** | DIY | DIY | DIY | n/a | ✅ **the only solid permissive in-process path** | ✅ native |

Sources: par2cmdline <https://github.com/Parchive/par2cmdline>; turbo
<https://github.com/animetosho/par2cmdline-turbo>; tbb
<https://github.com/ifsnop/par2cmdline-tbb>; libpar2 <https://github.com/Parchive/libpar2>;
MultiPar <https://github.com/Yutaka-Sawada/MultiPar>; ParPar <https://github.com/animetosho/ParPar>;
gopar <https://github.com/akalin/gopar>; rust-par2 <https://github.com/AusAgentSmith-org/rust-par2>
and <https://crates.io/crates/rust-par2>; par3cmdline <https://github.com/Parchive/par3cmdline>.

**The honest summary (07 Claim 3 correction included):** it is *too strong* to say "no permissively
licensed engine exists" — gopar (BSD, full PAR1+PAR2) and rust-par2 (MIT/Apache, verify+repair) do
exist. The accurate, decision-grade statement is: **no *mature, embeddable, Swift-native* permissive
PAR2 engine exists, and the permissive options that do exist are partial or unproven and do not add
up to one shippable create+verify+repair engine.** What *is* available — and valuable — is a body of
**permissive scaffolding** for a rewrite: gopar (BSD) as a correct readable PAR1+PAR2 reference;
**ParPar's CC0 SIMD GF16 math** (the same backend turbo borrows) for speed; par3cmdline's bundled
BSD/CC0 Galois + BLAKE3 libraries; and rust-par2 (MIT/Apache) as a second reference for the
verify+repair path. Tellingly, **rust-par2's very existence** — a from-scratch 2026 effort still at
0.x — corroborates that doing this well is real work, not trivial.

---

## 5. Clean-room Swift rewrite — feasibility

A clean-room Swift PAR2 engine is **legally unencumbered** and **technically tractable**, and it is
the only solid permissive in-process path to MAS. The legal ground is firm at primary source: the
PAR2 spec *prose* is GFDL-1.2, but the **file format itself** is granted free of any obligation —
verbatim: *"The introduced principles, the file format secification [sic] and it's details can be
used free by everyone for any type of software. There will be no license or other limitations. …
open, closed or shared source, public domain, freeware, shareware or commercial software — you can
use this spec."* (PAR spec
<https://parchive.sourceforge.net/docs/specifications/parity-volume-spec-1.0/article-spec.html>.)
"Clean-room" discipline matters only to avoid copying GPL par2cmdline **source**; implementing the
documented format from the spec is unencumbered.

### 5.1 Verify (RS-free) is genuinely easy; repair/create (GF(2^16) RS) is the hard part

- **VERIFY needs NO Reed-Solomon — confirmed.** Verification uses only hashing: full-file MD5 and
  MD5-of-first-16KiB (File Description packet), per-slice MD5+CRC32 (IFSC packet, standard reflected
  CRC32 poly `0xEDB88320` over the zero-padded slice), and a sliding-window rolling-CRC32 matcher
  (O(N) per file). No GF(2^16), no matrix. Swift has CryptoKit `Insecure.MD5` and a trivial CRC32.
  This is directly confirmed by reading gopar: `par2/verify.go` never instantiates the RS coder; the
  coder (`rsec16`) is imported only by `create.go`/`encoder.go`/`repair.go`/`decoder.go` (07 Claim
  3). **This layer is low-risk and is worth building regardless of the MAS decision** — it is
  already the planned native read-only parser + status engine (ARCHITECTURE.md §1.3; 03 §3, §8).
- **REPAIR + CREATE need the GF(2^16) Reed-Solomon codec — the hard, compatibility-critical core.**
  Field GF(2^16), generator polynomial `0x0001100B` (x^16+x^12+x^3+x+1); per-input-slice constants
  are powers of 2 of order 65535 (skip exponents divisible by 3/5/17/257 — first constants 2, 4, 16,
  128, 256, 2048, 8192, 16384, 4107, …); matrix entry `M[j][i] = g_i^(e_j)`; recovery word
  `R_j = XOR_i (D_i · g_i^e_j)`. CREATE = that matrix-vector product. REPAIR = build the
  missing-inputs × chosen-recovery submatrix, Gauss-Jordan invert it in GF(2^16), solve for the lost
  slices, re-verify. (03 §5; 07 Claim 3.)

### 5.2 The two dominant risks, with concrete mitigations

1. **Cross-tool compatibility (the #1 risk) — and you CANNOT "fix" the matrix.** PAR2's
   Vandermonde construction is *not* provably MDS (James Plank's 1997 tutorial wrongly claimed it
   was; he issued a formal correction — Plank & Ding, UT tech report **CS-03-504**, April 2003).
   PAR3 adopts the *corrected* matrix, which is precisely *why PAR3 is incompatible*. For PAR2,
   **every interoperable tool must reproduce the identical legacy constant sequence, slice ordering,
   and `g_i^e_j` matrix byte-for-byte.** turbo/ParPar change only *how fast* GF16 runs (SIMD), never
   the matrix, so they stay byte-compatible — and so must we. gopar makes the trap concrete: it ships
   *both* `rsec16/vandermonde.go` *and* `rsec16/cauchy.go`; pick the wrong convention and you
   silently produce sets no other tool can repair.
   - **Mitigation:** a **large, bidirectional golden-fixture corpus** as a permanent regression
     gate. (a) Sets created by par2cmdline, par2cmdline-turbo, **and** Windows MultiPar/par2j that
     ModernPAR must verify *and* repair; (b) sets created by ModernPAR that turbo and MultiPar must
     verify *and* repair (the reverse direction catches matrix/ordering/constant mistakes that
     one-directional tests miss). Include the historically tool-breaking edge cases: last-slice
     zero-padding, files smaller than one slice, renamed/concatenated/prepended-garbage inputs (the
     `-N` skip-leading-data class), high block counts near the 32768 source / 65535 recovery limits,
     and the "enough blocks but repair fails" class (par2cmdline issue #156) — which in practice
     traces to **block-detection** bugs (mispositioned/duplicate/null blocks), *not* matrix
     singularity. **Most real failures are matcher bugs, not RS-math bugs** — so weight test effort
     toward the sliding-window matcher.
2. **SIMD performance (the #2 risk) — Apple Silicon has a specific gap.** turbo's speed is entirely
   ParPar's SIMD GF16 backend (split-lookup-table via PSHUFB/VTBL, XOR-JIT, GFNI-affine on x86).
   **The fastest x86 path (GFNI / `GF2P8AFFINEQB`) has no ARM NEON equivalent**; on Apple Silicon
   the realistic best is the **NEON VTBL split-table** method. Swift's `simd` module and
   Accelerate/vDSP are **useless for this core** — they expose no Galois-field, table-shuffle, or
   carryless-multiply primitive.
   - **Mitigation:** write a small **first-party C file with hand-written ARM NEON intrinsics**
     (`vqtbl*` table-lookup; optionally `vmull_p8`/PMULL carryless multiply), permissively licensed
     because *we* write it, compiled arm64-native, callable from Swift via a C module. Pure scalar
     Swift (log/antilog tables) is fine for verify and adequate for small repairs, but 5–20× slower
     than turbo on create/large repair. Data point that this is reachable: Rust's `reed-solomon-simd`
     GF(2^16) hits ~±10% of x86 AVX2 on M1 (~6.4–10.2 GiB/s encode) — a careful Swift+NEON-C engine
     can plausibly reach ~50–80% of turbo on create and parity on verify. Treat SIMD as an
     **iterative, optional** phase: ship correct-but-scalar first, optimize later.

### 5.3 Effort estimate (one experienced engineer comfortable with finite-field math + SIMD)

| Phase | Scope | Estimate | Risk |
|---|---|---|---|
| **1 — Parser + VERIFY** | packet scan/validate, Main/FileDesc/IFSC decode, MD5/CRC32, sliding-window matcher, file-status taxonomy | **~3–5 eng-weeks** | Low |
| **2 — REPAIR** | GF(2^16) field + log/antilog tables + **legacy Vandermonde matrix** + Gauss-Jordan inversion + **bidirectional interop corpus** | **~6–10 eng-weeks** | **High** — dominated by byte-exact compat, *not* the algebra |
| **3 — CREATE** | matrix-vector encode, recovery-file sizing/naming (`-u`/`-l`/`-n`), exponent assignment, write-back | **~3–5 eng-weeks** | Medium (reuses Phase-2 field/matrix) |
| **4 — SIMD perf** | NEON split-table kernel + multithreading to approach turbo | **~3–6 eng-weeks** | Medium, iterative/optional |
| **(PAR1)** | GF(2^8), ≤255 files, simple — *already planned native* (ARCHITECTURE.md §1.2) | ~1–2 eng-weeks | Low |

**Total to full PAR2 parity ≈ 16–28 engineer-weeks (~4–7 months)**, plus an *ongoing* interop-test
maintenance tax. With a less-specialized or part-time engineer, the figure can easily double and the
SIMD phase can become open-ended tuning.

### 5.4 Phased path — and yes, a MAS build can ship verify+repair before create

The phases above *are* the path: **Verify → Repair → Create → (SIMD)**. Critically, **a MAS build
can ship verify+repair first and add create in a later update.** Verify and repair are exactly the
operations users need for ModernPAR's core workflow ("I downloaded a damaged Usenet set, fix it");
**create is the lower-frequency producer-side feature.** A native engine that does parse + verify +
repair is fully MAS-shippable on its own, and create reuses the Phase-2 field/matrix, so it is
*incremental, not a rewrite*. This de-risks the project: ship the easy, low-risk **verify** first to
validate the parser/matcher against real sets, then **repair**, then **create**. (07 Claim 3
phasing.)

---

## 6. Options and recommendation

Three coherent strategies. Each is internally consistent; they differ on whether MAS is worth the
clean-room PAR2 investment.

### Option A — Stay off-MAS (Developer-ID / notarized). **RECOMMENDED — and ADOPTED (2026-06-09).**
Keep the *decided* architecture: PAR2 via GPL turbo (in-process embed primary, subprocess
`HelperProcessEngine` fallback — ARCHITECTURE.md §0 / ROADMAP Decision 2; either way GPL, either
way off-MAS) + RARLAB UnRAR linked for full RAR fidelity; Developer-ID-signed, hardened-runtime,
notarized DMG, Sparkle 2 updates, App Sandbox on.

- **Pros:** Most powerful and most compatible (full RAR5 + multi-volume + password + SFX; byte-exact
  PAR2 interop inherited free from turbo). Fastest to ship — it is the current plan, no engine
  rewrite. No Apple commission, no review latency, full update control via Sparkle. The audience
  (Usenet/recovery power users) is well-served by direct distribution.
- **Cons:** No MAS presence/discoverability. (For this audience, a non-issue.)

### Option B — Dual distribution (Developer-ID now, MAS edition later). *(Pre-decision label: recommended as the long-term shape — SHELVED by the 2026-06-09 owner decision; see the decision stamp at top.)*
Ship the Option-A Developer-ID edition **now**. In parallel, build a **clean-room Swift PAR2 engine**
(verify+repair first, create later) + **XADMaster (or libarchive)** for RAR, and ship a **MAS edition**
once the engine is ready. *One codebase, two build configurations* — viable **only if the PAR2 engine
is clean-room**; the engine slots in behind the existing `PAR2Engine` protocol (§7).

- **Pros:** Best of both — power users get the full Developer-ID build today; MAS unlocks the
  store audience later. The clean-room engine has **independent value even for Option A**: it removes
  the last GPL/Rosetta-era subprocess, gives a single universal Swift codebase, native
  progress/cancellation, and sandbox simplicity. Verify+native-parser (Phase 1) is **worth building
  regardless** (low risk, high architectural payoff).
- **Cons:** ~4–7 engineer-months for full PAR2 parity + ongoing interop-test burden. The MAS edition
  carries a **real RAR regression**: XADMaster lacks header-encrypted RAR (and its RAR5/exotic-split
  fidelity lags RARLAB); libarchive can't decrypt RAR at all and is fragile on multi-volume. So the
  MAS edition is a *reduced-fidelity* sibling, not a replacement. Plus Apple commission + review.

### Option C — MAS-first clean-room from the start. **NOT recommended.**
Commit to the clean-room Swift engine + XADMaster *before* shipping anything, targeting MAS as the
primary channel.

- **Pros:** Single clean codebase; permissive from day one.
- **Cons:** Slowest and riskiest — gates the *entire* product on the highest-risk component (the
  GF(2^16) RS codec + byte-exact interop) and accepts the RAR-fidelity regression *for all users*,
  not just MAS users, while delaying the Rosetta-retirement urgency that motivates the whole project.
  It throws away turbo's free byte-exact interop for no near-term benefit.

### Recommendation
*(Pre-decision text. On 2026-06-09 the owner adopted **Option A only** — Option B is shelved, not
rejected. Items 1–2 and 4 below remain in force; item 3's gate was answered "not a priority.")*

**Adopt Option A now; treat Option B as the roadmap.** Concretely:

1. **Ship the Developer-ID / notarized edition** on the current architecture (turbo + UnRAR). This is
   correct, fastest, and unaffected by any of the above (consistent with ROADMAP Decision 6,
   ARCHITECTURE.md §10).
2. **Build the native Swift parser + VERIFY layer regardless** (Phase 1, ~3–5 weeks, low risk). It is
   already planned (ARCHITECTURE.md §1.3; 03), powers the document UI natively, and is the first step
   of the engine *if* you ever go for MAS.
3. **Gate the full REPAIR/CREATE + SIMD + XADMaster investment on whether MAS is a genuine business
   priority.** If yes, execute Option B: build the clean-room engine behind the existing protocol,
   ship a **verify+repair MAS edition first**, add create later, and accept the documented RAR
   regression for the MAS build only. If MAS is not a priority, the clean-room repair/create engine
   becomes a "nice-to-have, do incrementally" and Option A stands indefinitely.
4. **Get counsel before any release** — especially before committing to MAS (B1/B2 license readings),
   but also for the Developer-ID build's GPL + UnRAR coexistence (ARCHITECTURE.md §10, item 10).

---

## 7. Impact on ARCHITECTURE.md / ROADMAP.md

**If Option A stays (the default): essentially no change.** ARCHITECTURE.md §0/§10 and ROADMAP
Decisions 1/2/6 already record "no Mac App Store" and the turbo + UnRAR posture. This doc supplies
the *precise, cited rationale* those decisions reference, and tightened three framings the older
docs overstated (✅ carried into ARCHITECTURE.md §0/§10 and ROADMAP Decision 6 on 2026-06-09):

- State the GPL/MAS reason precisely: **Apple's Usage Rules are GPLv2 §6 "further restrictions" that
  attach to any GPL binary in the Store regardless of process/link boundary** — *not* "the subprocess
  firewall is defeated." The firewall solves copyright scope; MAS eligibility is a separate axis.
- Add the honest caveat that GPL-or-later code *is* App-Store-shippable **if the copyright holder
  grants a GPLv3 §7 App Store exception** — ModernPAR simply cannot obtain that for turbo (we're not
  the holder). That is the real blocker, not an inherent GPL property.
- Note that **RAR extraction is provably MAS-shippable** (The Unarchiver, Keka); UnRAR is a blocker
  we *choose* for clean licensing, removable by engine swap — not an Apple ban.

**If Option B (or C) is chosen, the changes are small because the architecture already anticipated
this:**

- **The `PAR2Engine` protocol already abstracts the engine** (ARCHITECTURE.md §1.5, §6 — the
  embedded engine, the helper fallback, and a future clean-room engine all slot in behind the same
  protocol "without touching the UI"). A **`NativeSwiftPAR2Engine: PAR2Engine`** slots in behind
  that seam exactly as `EmbeddedEngine`, `HelperProcessEngine`, and `NativePAR1Engine` do. The UI, document model, event stream
  (`EngineEvent`), and `OperationSession` are all engine-agnostic and **do not change.** This is the
  single most important architectural payoff: the abstraction that exists for the GPL firewall and
  for PAR3-future is the *same* seam the clean-room engine uses.
- **`ModernPARCore` already owns the native read-only PAR2/PAR1 parser** (§1.3). The clean-room
  engine's Phase-1 verify layer is largely *that parser plus the matcher/hashing* — it lives in
  `ModernPARCore`, no new C++-interop target, no new module-graph edge.
- **A MAS build configuration** would: select `NativeSwiftPAR2Engine` instead of the turbo
  helper/embed; replace `ArchiveKit`'s `RARExtractor`→`CUnrar` with an **XADMaster** (or libarchive)
  backend behind the *unchanged* `ArchiveExtractor` protocol (§6); **drop Sparkle** (§7.1 commands /
  doc 06 §6) and the `network.client`/mach-lookup Sparkle entitlements; switch signing to Apple
  Distribution. The GPL `COPYING`/source-offer compliance artifacts (doc 06 §3c) are *removed* for the
  MAS build (no GPL component).
- **ROADMAP** would add a gated, post-v1 track: "MAS edition — clean-room `NativeSwiftPAR2Engine`
  (verify → repair → create) + XADMaster RAR; reduced RAR fidelity; conditioned on MAS being a
  business priority." It does **not** displace the Phase 2 embedded/subprocess turbo work for the
  Developer-ID edition.
- **The hard new costs Option B/C introduce** (record them honestly in ROADMAP risks): the ~4–7
  engineer-month engine build, a permanent **bidirectional cross-tool interop test corpus** as a CI
  gate, the NEON GF16 SIMD kernel, and a **user-visible RAR regression** (loss of reliable
  header-encrypted / exotic multi-volume RAR) on the MAS edition.

---

## 8. Sources

Primary, in addition to those cited inline:
- GPLv2 §6 (verbatim): <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
- FSF — GNU Go / App Store: <https://www.fsf.org/news/2010-05-app-store-compliance> ·
  <https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement> ·
  VLC: <https://www.fsf.org/blogs/licensing/vlc-enforcement>
- Apple App Review Guidelines 2.4.5 / 2.5.2: <https://developer.apple.com/app-store/review/guidelines/>
- Apple Licensed Application EULA: <https://www.apple.com/legal/internet-services/itunes/dev/stdeula/> ·
  Media Services Usage Rules: <https://www.apple.com/legal/internet-services/itunes/us/terms.html>
- The Unarchiver (MAS): <https://apps.apple.com/us/app/the-unarchiver/id425424353> ·
  XADMaster (LGPL-2.1): <https://github.com/MacPaw/XADMaster>
- Keka (MAS): <https://apps.apple.com/us/app/keka/id470158793> ·
  RAR-compression wiki: <https://github.com/aonez/Keka/wiki/Rar-compression>
- RARLAB UnRAR license (Fedora): <https://fedoraproject.org/wiki/Licensing:Unrar>
- libarchive RAR5 (no encryption): <https://github.com/libarchive/libarchive/blob/master/libarchive/archive_read_support_format_rar5.c>
- PAR2 spec (format free-use grant + GF math): <https://parchive.sourceforge.net/docs/specifications/parity-volume-spec/article-spec.html> ·
  <https://parchive.sourceforge.net/docs/specifications/parity-volume-spec-1.0/article-spec.html>
- Plank correction CS-03-504: <https://web.eecs.utk.edu/~jplank/plank/papers/CS-03-504.html>
- Engines: turbo <https://github.com/animetosho/par2cmdline-turbo> · par2cmdline
  <https://github.com/Parchive/par2cmdline> · ParPar <https://github.com/animetosho/ParPar> · gopar
  <https://github.com/akalin/gopar> · rust-par2 <https://github.com/AusAgentSmith-org/rust-par2> ·
  par3cmdline <https://github.com/Parchive/par3cmdline> · MultiPar <https://github.com/Yutaka-Sawada/MultiPar>
- Prior ModernPAR research (this repo): `docs/research/03`, `05`, `06`, `07`; `docs/ARCHITECTURE.md`;
  `docs/ROADMAP.md`
