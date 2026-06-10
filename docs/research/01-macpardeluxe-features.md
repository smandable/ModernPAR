# MacPAR deLuxe 5.1.1 — Exhaustive Feature Specification

> Reverse-engineered requirements catalog for **ModernPAR**, the native arm64 SwiftUI rewrite.
> Source of truth: the installed bundle at `/Applications/MacPAR deLuxe.app` (v5.1.1, © 2002–2018 Gerard Putter,
> built Xcode 10 / macOS 10.14 SDK, Intel x86_64). Builds on, and does not contradict,
> `docs/research/00-source-notes.md`.

This document is the durable, authoritative feature inventory. Every item is tagged with a rewrite priority:

- **[MVP]** — must exist in the first usable build (core verify/repair/unrar of an existing set).
- **[v1]** — required for feature parity / a credible 1.0 release.
- **[later]** — nice-to-have, post-1.0 or low-frequency.
- **[drop]** — intentionally NOT carried over (with justification).

Sources cited inline are either the local bundle (file path) or external URLs.

---

## 0. How this was extracted (provenance)

All facts below were pulled directly from the installed bundle, not from memory:

- **Help text**: `Contents/Resources/Help files/macpar_deluxe_help.html` → converted with `textutil -convert txt`. Contains the full user manual + complete release-note history from v1.1 → v5.1.1.
- **Message catalog**: `Contents/Resources/English.lproj/Localizable.strings` → `plutil -p`. ~110 keyed strings: every status line, error message, button label, tooltip.
- **Menu + shortcuts**: `Contents/Resources/English.lproj/MainMenu.nib` is a compiled `NSKeyedArchiver` binary plist (ibtool refuses compiled nibs). Extracted titles, key-equivalents (`Q<char>`) and `@selector` action names via `strings`. Cross-checked against the help file.
- **Preference UI labels + tab structure**: `Preferences.nib`, `SaveOptions.nib`, `EditRule.nib`, `Password.nib`, `UnrarFileExists.nib`, `UnrarProgression.nib`, `EncodingSelection.nib`, `Reminder.nib`, `MyDocument.nib` via `strings`.
- **NSUserDefaults keys**: `strings` over `Contents/MacOS/MacPAR deLuxe` (the main binary).
- **CLI contracts**: ran the bundled helpers under Rosetta (`arch -x86_64 .../Helpers/par2SL` and `.../Helpers/par`) to dump their real usage banners.
- **Bundle metadata**: `Contents/Info.plist`, `Global.strings` (URLs), `Credits.rtf` (`textutil`).

### New findings not in the original source notes

1. **RAR filename-encoding disambiguation dialog** (`EncodingSelection.nib`, class `EncodingSelectionController`, defaults key `PrefFilenameEncoding`). When extracted RAR entries contain non-UTF-8 / "special" characters, the app shows a sheet: *"Some file names contain special characters. Please select the most likely interpretation."* with a table of candidate text encodings (columns "Encoding" / "File name"). This is a real, user-facing feature the notes missed. **[v1]** (legacy RAR archives only — RAR5 stores UTF-8). See §3.7.
2. **"Console log" semantics for unattended mode**: in unattended operation the app explicitly states it writes a progress report to the system console log (verbatim Preferences text). Relevant to how ModernPAR should surface unattended results. See §5.1.
3. **`par mix` (m) advanced command** is exposed by the par1 helper banner ("Try to restore from all parity files at once") — the GUI does not surface it directly, but it exists in the engine. **[drop]** for UI.
4. **Engine `+` toggle flags** (par1): the par1 binary supports `+i` (do not add files to parity), `+c` (do not create parity), `+C` (ignore case), `+H` (do not check control hashes), `-O` (work around open-file limit), `-d` (find duplicates). Only a subset is surfaced in the GUI. See §8.
5. **par2SL alias commands**: the par2 helper also accepts `parcreate` / `par2verify` / `par2repair` and allows omitting the par2 filename for single-file create.
6. **Reminder/donation panel** (`Reminder.nib`, class `ReminderController`) is a dedicated nag window with PayPal button + spinner + a randomized set of "I'll do it later" strings (`IllPayLater01`–`08`). **[drop]**.
7. **Crashlytics/Fabric** is wired in `Info.plist` (`Fabric` dict with API key + Crashlytics kit). **[drop]**.

---

## 1. Identity & document model

| Aspect | Value (from `Info.plist`) | ModernPAR |
|---|---|---|
| Bundle id | `nl.xs4all.gp.macpardeluxe` | new id, e.g. `app.modernpar` |
| Principal class | `ParApplication` (NSApplication subclass) | SwiftUI `App` |
| Display name | MacPAR deLuxe | ModernPAR |
| Min OS | `LSMinimumSystemVersion` 10.9 | macOS 14+ (SwiftUI document app) |
| Help book | `CFBundleHelpBookName` "MacPAR deLuxe Help", folder "Help files" | new help / inline |

**Document types** (`CFBundleDocumentTypes`):

| Extension | Type name | Doc class | Role | Icon |
|---|---|---|---|---|
| `.par` | PAR File | `PAR1Document` | Editor | `PARDocument.icns` |
| `.par2` | PAR2 File | `PAR2Document` | Editor | `PAR2Document.icns` |
| `.rar` | RAR archive | `UnrarDocument` | Viewer | `RarDocument.icns` |
| `*` (any) | Any | `MyDocument` | Viewer | — |

It is a **document-based app**: each PAR set / RAR archive opens in its own window. Double-clicking a `.par2` opens & auto-verifies; `.pnn` files cannot be opened by double-click (only via menu) per the help.

- **[MVP]** Register UTIs / document types for `.par`, `.par2`, `.rar`; SwiftUI `DocumentGroup` (or `ReferenceFileDocument`) with a window per set. The catch-all `*` "Any" type is **[later]** (it exists so dropping arbitrary files works; can be a drop target instead of a registered doc type).

---

## 2. Verify / Repair (PAR2 and PAR1)  — CORE

### 2.1 Behaviors
- **[MVP]** Open a `.par2` (or `.par`/`.pNN`) → **auto-verify, then auto-repair if needed** (no extra click). Help §"Par2"/"Par1".
- **[MVP]** During processing the **window cannot be closed**; an operation can be cancelled (see §2.4).
- **[MVP]** Per-file status list with status icon + text (see §2.2).
- **[MVP]** Document-level **status line at window bottom**, colored: **green** on OK end-state, **red** on not-OK (release notes v1.1). String `MyDocument.nib` → field "Status line".
- **[v1]** **Retry recovery** (a.k.a. "Repair again", ⌘R): keep window open between runs; the app **remembers files already checked OK and skips them** next run (release notes v3.7). Used after acquiring more recovery data.
- **[v1]** When recovery is insufficient, report **exactly how much more is needed**: "Cannot restore; need %d more files" (par1) or, for par2, the number of additional recovery blocks / data bytes (help step 4; status strings below).
- **[v1]** **Full-folder scan** for missing/renamed blocks: if parts are missing, the engine scans *all* files in the folder for the missing parts. The app warns when the folder has many unrelated files because this is slow (`ManyUnrelatedFilesWarning`). Help §"Par2" para 2.
- **[v1]** Detect & handle **renamed** files ("OK after renaming file '%@'", status line "...one or more files were renamed").
- **[v1]** **par1-only**: files that "did not contribute to the parity data" (verifiable but not repairable, e.g. `.nfo`/`.sfv`). The app can *process* such sets but cannot *create* them. (Help §"Par1".)
- **[v1]** **par1 Pnn introspection**: status text describing each Pnn file's content (see `PxxFileStatus*` below).
- **[v1]** Folder writability precheck before starting (release notes v3.8 — "checks if the folder is writable"); error `FolderReadOnlyErr`.
- **[v1]** Guard: if the `.par` file itself was moved to the trash, refuse with `PARIsInTrashErr`.

### 2.2 Per-file status states

PAR2/PAR1 file status (`FileStatus0`–`10`):

| Key | Text | Icon (bundle) |
|---|---|---|
| 0 | (none) | — |
| 1 | OK | `FileOKIcon.icns` |
| 2 | Invalid checksum | `FileErrorIcon.icns` |
| 3 | OK after renaming file '%@' | OK |
| 4 | Missing | `FileErrorIcon.icns` |
| 5 | Missing, but can be recovered | `FileRecoverableIcon.icns` |
| 6 | Missing and cannot be recovered | `FileErrorIcon.icns` |
| 7 | Invalid checksum, but can be recovered | `FileRecoverableIcon.icns` |
| 8 | Invalid checksum and cannot be recovered | `FileErrorIcon.icns` |
| 9 | Recovered successfully | OK |
| 10 | Not in PAR file yet | `FileNotInVolumeSetIcon.icns` |

Help also references `FilePossibleErrorIcon.icns` ("missing or damaged, but might be recoverable") and `FileNotInVolumeSetIcon` ("did not contribute to parity data"). Icon JPGs duplicated in `Help files/`.

Par1 Pnn-file status (`PxxFileStatus0`–`7`):

| Key | Text |
|---|---|
| 1 | Valid Pnn file |
| 2 | Contains no recovery blocks |
| 3 | Contains duplicate recovery blocks |
| 4 | Contains 1 recovery block |
| 5 | Contains %d recovery blocks |
| 6 | Contains 1 block from file '%@' |
| 7 | Contains %d blocks from file '%@' |

- **[MVP]** Reproduce statuses 1,2,4,5,6 + the recoverable/non-recoverable distinction. **[v1]** the full par1 Pnn introspection set.

### 2.3 Document status line (`DocStatus0`–`16`)

| Key | Text |
|---|---|
| 0 | (empty) |
| 1 | Verifying the files. Press ⌘. to cancel. |
| 2 | Restoring files. Press ⌘. to cancel. |
| 3 | Canceled. |
| 4 | Cannot restore; need %d more files. |
| 4A | Cannot restore; need one more file. |
| 4B | Cannot restore. |
| 5 | All files checked out fine. |
| 6 | All files checked out fine; one or more files were renamed. |
| 7 | Files restored successfully. |
| 8 | Files restored successfully; one or more files were renamed. |
| 9 | The PAR file is not valid. |
| 10 | New PAR file should be generated. |
| 11 | Generating PAR files. Press ⌘. to cancel. |
| 12 | PAR files generated successfully. |
| 13 | Only non-recoverable files are missing. |
| 14 | Only non-recoverable files are missing; one or more files were renamed. |
| 15 | An internal error occurred during processing. |
| 16 | Waiting to start PAR check... |

- **[MVP]** statuses 1,2,3,5,7,11,12,16. **[v1]** the rest (4/4A/4B, 6/8, 9/10, 13/14, 15). ModernPAR should keep the colored end-state convention and the "press ⌘. to cancel" affordance (or a Cancel button).

### 2.4 Cancellation & progress
- **[MVP]** **Cancel Operation** = ⌘. (`PerformAbortAction:`); toolbar "Cancel" button (`DocTBAbort`, tip "Cancel the operation"). After cancel, status shows "Canceled." (release notes v2.1 explicitly added this).
- **[MVP]** Live progress (the par2SL engine emits progress; ModernPAR should show a determinate progress bar + status text). For par-set creation, "When par creation is interrupted with Cancel, it is now possible to restart without recreating the set" (release notes v3.6) — **[v1]** resumable-after-cancel nicety.
- **[v1]** **Show / Hide "par" Output** (`PerformToggleParOutput:`, `MenuTextShowParOutput`/`MenuTextHideParOutput`): a raw engine-log view. ModernPAR: a collapsible "engine log" pane.

---

## 3. Unrar (RAR extraction)

Engine: `Contents/Frameworks/libUnrar.dylib` (RARLAB UnRAR; RAR 2.x/3.x/5.x). RAR5 added in v5.0.

### 3.1 Triggering
- **[MVP]** Manual **Unrar Archive…** = **⌘U** (`PerformUnrarFile:`) → pick first file of the set.
- **[v1]** **Drop first file on the dock icon** to start an unrar (RAR `.rar` only, not self-extracting; release notes v2.4.2).
- **[v1]** **Automatic unrar after a successful par2/par check** of a set containing rar files (via the built-in Unrar post-processing rule, §4).

### 3.2 Supported first-file forms (Help §"How to unrar")

| First file | Subsequent | Comment |
|---|---|---|
| `.rar` | `.r00, .r01, …` | RAR 2.x |
| `.exe` | `.r00, .r01, …` | Wintel self-extracting (rare) |
| `.part01.rar` | `.part02.rar, …` | RAR 3.x+ |
| `.part01.exe` | `.part02.rar, …` | RAR 3.x+ self-extracting (rare) |
| `.001` | `.002, …` | split archive (restored in v2.6) |

- **[MVP]** `.rar` + `.rNN` and `.partNN.rar`. **[v1]** `.001/.002`. **[later]** self-extracting `.exe` forms (very rare; UnRAR handles them transparently anyway).

### 3.3 Output placement
- **[MVP]** Multi-item archive → extract into a **new folder named after the archive** (extension stripped). Single top-level item → **no enclosing folder** (changed in v5.0). Help §"How to unrar".
- **[v1]** Destination per the Unrar preference (same folder as archive / ask each time / fixed folder; §5.4).

### 3.4 "Destination already exists" policy (`UnrarFileExists.nib`)
Dialog title "Unrar %@", body `UnrarFileExistsWarning` "An item named "%@" already exists. Make a choice." Buttons / radio options found in the nib:
- Overwrite the file (`mButtonOverwrite`) / **Overwrite all** (`mButtonOverwriteAll`)
- Save file as (rename) (`mButtonSaveAs`) → **Keep Both** (`UnrarFileExistsKeepBothButton`)
- Cancel the Unrar operation (`mButtonCancelAll`) / Cancel (`UnrarFileExistsCancelButton`)

Preference default for this policy: ask / overwrite / keep-both(rename) / cancel (§5.4). "Keep both" first **renames the existing** item then extracts (added v5.0).
- **[v1]** full dialog incl. "overwrite all".

### 3.5 After-unrar segment policy
What to do with the rar segments after success: **Move to trash (default)** / **Leave segments** / **Delete permanently** (`AutoDeleteSeg`, `DeleteSegOption`). Permanent-delete shows a warning (`PermanentDeleteWarning` / `PermanentDeleteWarning` in Prefs nib: *"This option permanently deletes the segments; recovery is not possible."*). Note: trash unavailable on network volumes (help). 
- **[v1]**.

### 3.6 Password-protected archives (`Password.nib`)
- **[v1]** Prompt **once**, reuse the password for the whole archive (fixed in v2.4.2; before that it asked per-segment). Dialog shows "Archive Filename" + password field + OK/Cancel.
- Error strings: `MPDUnrarErrorDomain22` "missing password", `…24` "invalid password", `…12` "invalid data or incorrect password".

### 3.7 RAR filename encoding selection (`EncodingSelection.nib`) — **NEW FINDING**
- **[v1]** When extracted entries have non-UTF-8 names, sheet: *"Some file names contain special characters. Please select the most likely interpretation."* with a table (Encoding / File name preview) and OK/Cancel. Stored as `PrefFilenameEncoding`. RAR5 archives store UTF-8 so this only matters for legacy RAR. ModernPAR can default to UTF-8 with a fallback picker.

### 3.8 Unrar errors (`MPDUnrarErrorDomain11`–`24`, `MPDUnrarLibGlueErrorDomain1`)
Full set: not enough memory (11); invalid data or incorrect password (12); invalid archive (13); unknown format (14); cannot open rar volume %@ (15); cannot create/close/read/write archive (16–19); buffer too small (20); unknown (21); missing password (22); invalid reference (23); invalid password (24); cannot rename/overwrite folder %@ (glue 1). 
- **[MVP]** map these to user-readable errors.

### 3.9 Progress & completion (`UnrarProgression.nib`)
- **[MVP]** Progress window: current file label, determinate progress bar, status text, Cancel. Stays visible when app goes to background (release notes v3.6). Status strings `UnrarStatus1` "Waiting to start Unrar...", `UnrarStatus2` "Extracting the contents of the RAR archive".
- **[v1]** **Notification Center** notification on each finish: titles `UnrarSuccessNotificationTitle` "Unrar successful" / `UnrarFailedNotificationTitle` "Unrar failed", subtitle `UnrarNotificationSubtitle` "Archive: %@", action button `UnrarShowInFinderButton` "Show in Finder". Clicking the notification reveals the result in Finder (replaced the old "always show in Finder" toggle in v5.0). ModernPAR: `UserNotifications` framework.
- "Keep incorrectly expanded (broken) files" option (§5.4): default deletes a partially-extracted file on error.

---

## 4. Post-processing rules (extensible automation)

After a set is verified/repaired successfully, the app runs **post-processing rules** matched by **filename pattern**. Help §"Automatic post-processing" + §"Adding and modifying a post-processing rule"; Preferences "Post-processing" tab.

### 4.1 Default rules (top→bottom, first match wins, one fires per set)

| Trigger (filename) | Action |
|---|---|
| `.rar` | **Built-in Unrar** engine (`BuiltInUnrarRule`, label "Built-in Unrar") — not editable/deletable |
| `.zip` | OS `unzip` (changed from Stuffit in v3.5) |
| `.sit` | Stuffit Expander |
| `.sit.1` | Stuffit (first file of multi-part) |
| `.part01.sitx` | Stuffit (first file of multi-part) |
| `.sitx` | Stuffit Expander |

- **[MVP]** built-in Unrar rule + `.zip` via OS unzip (use `libarchive`/`Compression` or shell `ditto`/`unzip`).
- **[drop]** Stuffit/StuffitExpander rules — dead tech (StuffIt is discontinued, `.sit`/`.sitx` are effectively extinct). Ship default rules only for `.rar` and `.zip`. Users who really need it can add a custom command-line rule.

### 4.2 Rule editor (`EditRule.nib`, class `EditPPRuleController`)
Each rule: **Description** (display name, should be short/unique), a **trigger condition** (set contains ≥1 file whose name matches), and one of three **action types**:
1. **Open in Finder** (as if double-clicked) — errors `PostProcess1Err`.
2. **Open with a chosen application** (the nib has an app-icon well "<Naam programma>" = app-name placeholder) — errors `PostProcess2Err`/`PostProcess3Err`.
3. **Run a command-line script in Terminal** (via `TerminalScript.txt` AppleScript template: `tell application "Terminal" … do script "%1;exit"`). Supports a **macro**: `%1` = command, and post-process macro **"A"** for command-line rules (added v4.1). Error `CantLaunchCommandErr` "Applescript error while trying to perform command".

Rule list management (Prefs "Post-processing" tab): **New Rule…** (`ruleNewButton`), Modify (`ruleModifyButton`), Delete (`ruleDeleteButton`), move **Up/Down** (`ruleUpButton`/`ruleDownButton`, `OnMoveRuleUp:`/`OnMoveRuleDown:`), **Standard** (`mStandardButton`, `OnStandard:` — revert to defaults). The built-in Unrar rule (always last) cannot be edited/deleted.

- **[MVP]** the built-in Unrar + zip behavior (no editor).
- **[v1]** the full rule editor with "open in Finder" and "open with app" actions + reorder + revert-to-default.
- **[later]** the **Terminal command-line script** action. Modernize: rather than driving Terminal.app via AppleScript (fragile, sandbox-hostile), run scripts via `Process`/`NSUserUnixTask` or show output inline. Treat the `%1`/`"A"` macros as the compatibility surface.
- Trigger to run rules manually: **Apply Rule** menu (`PerformPostProcessing:`, `MenuTextPostProcess` "Apply Rule") in the Process menu, when auto-post-process is off.

---

## 5. Preferences (full)

Window title "MacPAR de Luxe Preferences" (`Preferences.nib`, class `PreferencesController`), a tabbed panel. Tabs (from nib): **Basic / Par1 / Par2 / Unrar / Post-processing / Other** (the nib shows tab labels "par 1", "par 2" and the other sections). Backing store = NSUserDefaults; keys confirmed from the main binary.

### 5.1 Basic
| Setting | Default | Defaults key | Priority |
|---|---|---|---|
| **Auto delete par files** — move `.par`/`.par2`/`.pNN` to Trash after a successful restore ("The .par en .pnn files are moved to the trash after a successful restore") | off-ish (advanced) | `AutoDeletePnn` | **[v1]** |
| **Close par window after automatic post-processing** | off | `AutoCloseDocument` | **[v1]** |
| **Default document type when program starts** (PAR1 / PAR2) | PAR2 | `DefaultPar` | **[v1]** |
| **Run unattended** — no dialogs even on error; progress written to **system console log** (use Console.app). On unattended errors writes a user notification. Safe defaults: keep-both on conflict, empty password. | off | `UnattendedOperation` | **[v1]** |

> Modernization note: "writes a progress report to the console log" is a 2018 idiom. ModernPAR should instead use `os.Logger` + a visible activity log, and surface unattended results as notifications.

### 5.2 Par1 (`SaveOptions.nib`)
| Setting | Detail | Defaults key | Priority |
|---|---|---|---|
| **Number of Pnn files to generate** | two methods: *count based on number of subject files* OR *fixed number, independent of the number of files* (nib strings "Number of Pnn files to generate", "independent of the number of files"). Overridable in the Save As panel. | (Par1 group) | **[v1]** |

Validation: `WrongNumPARErr` "The number of Pnn files must be a number between 0 and 99"; `WrongNumFilesPerPARErr` "The number of files must be a number between 1 and 99".

### 5.3 Par2
| Setting | Detail | Defaults key | Priority |
|---|---|---|---|
| **Level of redundancy** (%) | nib "Level of redundancy"; help: parity as % of total set size | `Par2Redundancy` | **[v1]** |
| **Limit par2 file size to match largest data file** | par2 vols are sized 1,2,4,8… blocks; this caps the largest vol to repair the largest data file | `Par2LimitFileSize` | **[v1]** |
| **Block size** (KB) or **Automatic** | nib "Block size", "Automatic", helper text "When you're uploading to UseNet, … set the block size to the size of the data attached to each article", "The block size is calculated from the combined size of the files" | `Par2BlockSize`, `Par2BlockSizeChoice` (default 300 in nib) | **[v1]** |

Validation: `WrongPAR2RedundancyErr` "The redundancy percentage must be a number between 1 and 100"; `WrongPAR2BlockSizeErr` "The block size must be a number between 1 and 419430".

### 5.4 Unrar
| Setting | Options | Defaults key | Priority |
|---|---|---|---|
| **Keep incorrectly expanded (broken) files** | on/off ("Keep extracted files, even if the unrar operation fails") | `KeepBrokenFiles` | **[v1]** |
| **Where must unrar create the extracted items** | *Inside the folder where the rar archive is* (default) / *Always let me choose a location* / *Inside this folder:* (fixed) | `chooseUnrarDestinationFolder` + a stored folder path | **[v1]** |
| **If destination already exists** | *Ask what to do* (default) / Overwrite existing / Keep both (rename) / Cancel | `existingUnrarDestinationAction` | **[v1]** |
| **After successful unrar** | *Move segments to trash* (default) / *Leave segments* / *Delete segments* (permanent, with warning) | `AutoDeleteSeg`, `DeleteSegOption` | **[v1]** |

Related defaults: `AutoUnrar` (auto-unrar after par check), `PrefFilenameEncoding` (§3.7).

### 5.5 Post-processing
| Setting | Detail | Defaults key | Priority |
|---|---|---|---|
| **Automatically post-process files after repair** | if off, trigger manually via Process ▸ Apply Rule | `AutoPostProcess` | **[v1]** |
| **Rules list** | editor with New/Modify/Delete/Up/Down/Standard (§4.2) | `PostProcessRule` (+ `RuleDescription`) | **[v1]** editor; **[MVP]** the rule data model |

### 5.6 Other
| Setting | Detail | Defaults key | Priority |
|---|---|---|---|
| **Automatically check for software updates** | checks an xml version list on every launch; if newer, shows an alert (manual update). "On program startup the Internet is checked for availability of a new version." | `AutoCheckUpdate` | **[drop]** (replace with Sparkle or none — see §9) |
| **When opening multiple files at the same time** | *Process them one by one* (default; queue) / *Process them simultaneously* (warns of overhead) | `SimultaneousProcessing` | **[v1]** |
| **Limit CPU cores used for par2** | default = all cores; `TotalCoresText` "of the %d CPU cores" (added v3.8) | (cores key) | **[later]** (Swift concurrency / `ProcessInfo.activeProcessorCount`; the engine itself should manage parallelism) |

The first-launch flow prompts `AutoCheckQuestion`/`AutoCheckQuestionTitle` ("Check for update"). **[drop]**.

---

## 6. Create (PAR2 and PAR1)

Help §"How to create a par2 (or par) set"; Save panel = `SaveOptions.nib` (`SaveOptionsController`) embedded in the standard Save sheet (`SavePanelExtension.nib`).

- **[v1]** Build a set by **dragging files from Finder** into the list, or **Add Files…** (⌘F, `PerformAddFile:`).
- **[v1]** **All files must be in one folder** (the app enforces; adding from another folder is rejected).
- **[v1]** **Reject files with a resource fork** (`ResourceForkWarning` "One or more of the files have a resource fork and can therefore not be added to the PAR set"). On modern macOS this is essentially never hit; can be a soft check. **[later]**.
- **[v1]** **Remove** selected files from the set (⌘? / Remove, `PerformParRemove:`).
- **[v1]** **Create PAR Set…** = **⇧⌘S** (`saveDocumentAs:`); in the save panel choose filename + (par2) redundancy % or (par1) number of Pnn files; must save in the file-set's folder. `PathCorrectedWarning` "The files will be written to %@".
- **[v1]** **New PAR 1 Set** (`onNewPar1:`) / **New PAR 2 Set** (`onNewPar2:`).
- **[MVP-doc]** Set-size limits enforced at add/save: **par2 ≤ 32768 files**, **par1 ≤ 255 files**. Errors: `TooManyFilesErr`, `TooManyFilesForPar1ErrP/S`, `TooManyFilesForPar2ErrP/S` ("The document has room for %d more files").
- File-naming convention surfaced to users: `Filename.volXXX+YY.par2` (XXX = first block, YY = block count). Help.
- **[v1]** When all subject files share a base name, suggest it as the `.par` filename (release note v1.1).
- par1 sets **cannot** include "non-contributing" files on create (all added files contribute); recommend leaving insignificant files out.

> Priority rationale: Create is **[v1]**, not MVP. The dominant user story (and the urgency driver — Rosetta retirement) is *verify/repair/unrar of sets you downloaded*. Creation matters for parity but can land after the consume path works.

---

## 7. App-level / UX, menus & shortcuts

### 7.1 Complete menu map (from `MainMenu.nib`)

Extracted title → key-equivalent → action selector. (`Q<c>` = ⌘<c>; modifier mask may add ⇧.)

**Application menu (MacPAR deLuxe)**
- About MacPAR deLuxe → `orderFrontStandardAboutPanel:`
- Preferences… → ⌘, → `PerformPreferences:`  **[MVP]**
- Check for Software Update → `PerformCheckUpdate:`  **[drop]**
- Make a Donation → `PerformReminderNoDelay:`  **[drop]**
- Services (submenu, `_NSServicesMenu`)  **[later]**
- Hide MacPAR deLuxe ⌘H → `hide:` / Hide Others → `hideOtherApplications:` / Show All → `unhideAllApplications:`  (standard, free in SwiftUI)
- Quit MacPAR deLuxe ⌘Q → `terminate:` — **disabled while a par/unrar is running** (v3.8)  **[v1]**

**File**
- Open and Repair… ⌘O → `openDocument:`  **[MVP]**
- New PAR 1 Set → `onNewPar1:` / New PAR 2 Set → `onNewPar2:`  **[v1]**
- Close ⌘W → `performClose:`; **Close All** (⌥-Close) → `PerformCloseAll:` (v3.6)  **[v1]**
- Create PAR Set… ⇧⌘S → `saveDocumentAs:`  **[v1]**

**Edit**
- Cut ⌘X / Copy ⌘C / Paste ⌘V / Clear / Select All ⌘A (standard text editing)
- **Copy selected file names to clipboard** (Copy in the file-list context; v3.7)  **[v1]**
- Add Files… ⌘F → `PerformAddFile:`  **[v1]**
- Remove → `PerformParRemove:`  **[v1]**
- Repair Again ⌘R → `PerformRetryRecovery:`  **[v1]**
- Cancel Operation ⌘. → `PerformAbortAction:`  **[MVP]**
- **Select All Non-OK** (select all erroneous files; v3.7) → `onSelectAllNonOK:`  **[v1]**

**Process**
- Unrar Archive… ⌘U → `PerformUnrarFile:`  **[MVP]**
- Apply Rule → `PerformPostProcessing:`  **[v1]**
- Show/Hide "par" Output → `PerformToggleParOutput:`  **[v1]**

**Window** — Minimize ⌘M (`performMiniaturize:`), Bring All to Front (`arrangeInFront:`), Hide/Customize Toolbar (`toggleToolbarShown:` / `runToolbarCustomizationPalette:`). Standard.

**Help**
- MacPAR deLuxe Help ⌘? → `showHelp:`  **[v1]**
- Get Support by E-mail → `PerformEmailToAuthor:`  **[later]** (repoint to ModernPAR support)
- MacPAR deLuxe Web Page → `PerformVisitWebPage:`  **[later]**

(There is also a hidden/dev **Debug** menu — `mDebugMenu` — **[drop]**.)

### 7.2 Toolbar (per-document window)
Items (icons in `Contents/Resources/DocTB*`, labels/tips in `Localizable.strings`):
New (`DocTBNewPARSet`) · Open+Repair (`DocTBOpen`, "Open and verify; repair if necessary") · Repair again (`DocTBReRecover`) · Add (`DocTBAddFiles`, two tips depending on par1/par2) · Remove (`DocTBRemove`) · Create par1 (`DocTBSaveAs1`) · Create par2 (`DocTBSaveAs2`) · Cancel (`DocTBAbort`) · Preferences (`DocTBPreferences`) · Help (`DocTBHelp`) · Homepage (`DocTBWeb`) · Support/E-mail (`DocTBEmail`) · Donation (`DocTBReward`, "Reward the author with a shareware donation") · Quit (`DocTBQuit`).
- **[MVP]** New, Open+Repair, Add, Create, Cancel, Repair-again. **[v1]** Remove, Preferences, Help. **[drop]** Donation; **[later]** Homepage, Support, Quit-in-toolbar (redundant on mac). Toolbar is user-customizable + remembers layout. ModernPAR: native SwiftUI `.toolbar`.

### 7.3 Other UX
- **[MVP]** Drag files into the list; double-click `.par2` to open; drop rar on dock icon (**[v1]**).
- **[v1]** File list: **alternating row colors**; columns resizable; **window size + column widths persist** between runs (v2.2). Finder-style filename sort so `.sit.2` precedes `.sit.10` (v2.3).
- **[v1]** Recent files are **not** shown in the dock (deliberate, v4.2.6) — ModernPAR may keep an in-app recents but should respect this preference.
- **[drop]** Recently-processed files in dock menu.
- Status line colored green/red (§2.1). **[MVP]**

### 7.4 Localization
- Ships **English + Dutch** (`English.lproj`, `Dutch.lproj`). French/Spanish were dropped in v2.3.
- **[later]** ModernPAR: ship English first; structure strings for localization (String Catalogs). Dutch is a nice nod but optional.

---

## 8. CLI option → user-facing preference mapping

These are the engine contracts ModernPAR's PAR2/PAR1 engine must reproduce (verbatim banners captured from the bundled helpers).

### par2SL (PAR2) — `par2 c|v|r [options] <par2 file> [files]`
| CLI option | Meaning | Surfaced as | Priority |
|---|---|---|---|
| `c` / `v` / `r` | create / verify / repair (aliases `parcreate`/`par2verify`/`par2repair`) | the verb chosen by the action (auto on open) | **[MVP]** |
| `-b<n>` | Block-Count (mutually exclusive with `-s`) | derived from block-size choice | **[v1]** |
| `-s<n>` | Block-Size in **KB** | Prefs ▸ Par2 ▸ **Block size** (or Automatic) | **[v1]** |
| `-r<n>` | Redundancy **%** | Prefs ▸ Par2 ▸ **Level of redundancy** + Save panel | **[v1]** |
| `-c<n>` | Recovery block count (mutually exclusive with `-r`) | not directly surfaced (advanced) | **[later]** |
| `-f<n>` | First recovery-block number | not surfaced | **[later]** |
| `-u` | Uniform recovery file sizes (mutually exclusive with `-l`) | implied when **not** limiting file size | **[v1]** |
| `-l` | Limit recovery file size (mutually exclusive with `-u`/`-n`) | Prefs ▸ Par2 ▸ **Limit par2 file size to match largest data file** | **[v1]** |
| `-n<n>` | Number of recovery files (mutually exclusive with `-l`) | derived | **[later]** |
| `-m<n>` | Memory (MB) to use | (could map to a memory/cores pref) | **[later]** |
| `-v`/`-q` | verbosity | "Show par Output" detail level | **[v1]** |
| `--` | end-of-options sentinel | internal | **[MVP]** |

### par (PAR1) — `par c|r|a|m [options] <par file> [files]`
| CLI option | Meaning | Surfaced as | Priority |
|---|---|---|---|
| `c` / `r` / `a` | check / recover / add | verb (auto on open / on create) | **[v1]** |
| `m` | mix (restore from all parity files at once) | **not surfaced** | **[drop]** (advanced/internal) |
| `-p<n>` | files per parity volume | Par1 pref method "count based" | **[v1]** |
| `-n<n>` | number of parity volumes | Par1 pref method "fixed number" + Save panel | **[v1]** |
| `-m` | move existing files aside | internal during recover | **[v1]** |
| `-r` | recover parity volumes too | internal | **[v1]** |
| `-f` | fix faulty filenames | internal (rename handling) | **[v1]** |
| `-d` | search for duplicates | not surfaced | **[later]** |
| `-k` | keep broken files | internal | **[later]** |
| `+i` | do NOT add files to parity | internal | **[drop]** |
| `+c` | do NOT create parity volumes | internal | **[drop]** |
| `+C` | ignore case in filename comparisons | internal | **[later]** |
| `+H` | do not check control hashes | internal | **[drop]** |
| `-O` | work around open-file limit | internal (the "Too many open files" fix, v2.2) | **[later]** |
| `-v`/`+v` | verbosity | "Show par Output" | **[v1]** |

> Engine strategy: the prudent path is to NOT shell out to a 2003 GPL C fork. Evaluate **par2cmdline-turbo** (animetosho, SIMD/multithreaded, actively maintained) for PAR2 and a small Swift/C PAR1 implementation, or treat par1 as **[later]/[drop]** given its obsolescence (see Risks). Whatever engine is chosen must expose the `-s/-r/-l/-u` knobs above.

---

## 9. Things to DROP or MODERNIZE (with justification)

| Item | Decision | Why |
|---|---|---|
| Shareware **donation nags** (`Reminder.nib`, `Make a Donation`, `Donation`/`Reward` toolbar item, `PerformReminder:`, `IllPayLater01-08`, PayPal/Kagi logos, `Reminder.nib` spinner) | **[drop]** | ModernPAR is a clean rewrite; no shareware model. Remove all nag UI and randomized "pay later" strings. |
| **Crashlytics / Fabric** (`Info.plist` Fabric dict + API key) | **[drop]** | Third-party crash SDK; privacy + maintenance burden. Use Apple's built-in crash reporting / MetricKit if anything. |
| **StuffIt / StuffitExpander** post-process rules (`.sit/.sitx/.sit.1/.part01.sitx`) | **[drop]** | StuffIt is discontinued; the format is extinct. Keep only `.rar` and `.zip` default rules; users can add custom rules if truly needed. |
| **Custom XML auto-updater** (`AutoCheckUpdate`, `VersionlistURL`/`TestVersionlistURL`, `Check for Software Update`, `CanDownloadNew`/`NewVersionAvailable`/etc.) | **[drop]/replace** | Bespoke `versionlist.xml` polling on every launch is dated and brittle. Replace with **Sparkle 2** (EdDSA-signed appcast) — decided, ROADMAP Decision 6 (MAS later ruled out; see `research/08`). |
| **Terminal.app AppleScript** post-process action (`TerminalScript.txt`) | **[modernize]** | Driving Terminal via AppleScript is sandbox-hostile and fragile. Run scripts via `Process`/`NSUserUnixTask`; show output inline. Keep `%1`/`"A"` macro compatibility. |
| **"Console log" unattended reporting** | **[modernize]** | Use `os.Logger` + an in-app activity log + notifications instead of telling users to open Console.app. |
| **PowerPC / universal-PPC** notes, 32-bit modes, "open file limit" workarounds, Snow-Leopard GCD specifics | **[drop]** | Irrelevant on arm64. Use Swift Concurrency (`async`/`await`, `TaskGroup`) for parallelism. |
| **Resource-fork rejection** on add | **[later]** | Resource forks are effectively gone on modern macOS; keep a soft guard but don't build UI around it. |
| **Email-to-author / Homepage / Kagi/PayPal** menu+toolbar items | **[modernize]** | Repoint to ModernPAR's own support URL/repo, or drop. |
| **Dutch/French/Spanish** localizations | **[later]** | Ship English; structure for localization later. |

Modernization platform decisions (from source notes, endorsed here): SwiftUI document-based app; **sandbox + security-scoped bookmarks** (needed because the engine writes alongside the source files — see Risks); native progress + `UserNotifications`; native arm64 (universal optional); Swift Concurrency; drag-drop via SwiftUI `.dropDestination`.

---

## 10. Prioritized build order (summary)

**MVP (the Rosetta-retirement lifeboat — consume an existing set):**
1. Document app + `.par2`/`.rar` types; open & auto-verify/repair a PAR2 set; per-file status icons + colored status line; Cancel (⌘.); progress.
2. Unrar (⌘U + drop-on-dock): `.rar`/`.rNN` + `.partNN.rar`, single-vs-multi output folder, progress window, error mapping.
3. Built-in Unrar + `.zip` post-processing after verify; Preferences shell with the most-used toggles.

**v1 (parity):** PAR1 verify/repair; Create (par2 + par1) with redundancy/block-size/Pnn-count; full Preferences (all six tabs); rule editor (Finder/app actions); password + encoding dialogs; retry-recovery memory; Notification Center; one-by-one vs simultaneous queue; copy-names / select-all-non-OK; window/column persistence.

**later:** Terminal-script rule action, CPU-core limiting, self-extracting `.exe` rar, recents, localization, `*`-catch-all doc type.

**drop:** donation nags, Crashlytics, custom XML updater, StuffIt rules, Debug menu, PPC/32-bit cruft.

---

## 11. Reference: external engine sources
- par2cmdline lineage / parchive: https://sourceforge.net/projects/parchive/
- author's macOS-optimized PAR2 fork source: https://www.xs4all.nl/~gp/MacPAR_deLuxe/par2SL_Source.zip
- **par2cmdline-turbo** (recommended to evaluate): https://github.com/animetosho/par2cmdline-turbo
- RARLAB UnRAR source (note license restrictions): https://www.rarlab.com/rar_add.htm
- libarchive (RAR read support alternative): https://github.com/libarchive/libarchive
- Sparkle (replacement updater): https://sparkle-project.org/
- Original app's URLs (`Global.strings`): web page `https://www.xs4all.nl/~gp/MacPAR_deLuxe`, download `…/MacPARdeLuxe.dmg`, params `…/rtparams.json`, version list `…/versionlist.xml`. (All for reference only; do not reuse.)
