#!/bin/bash
# Entitlements audit (ROADMAP Phase 9, doc-06 §4).
#
# Deny-by-default: the app may hold EXACTLY the entitlements on the allowlist below — sandbox
# on, user-selected read-write, app-scope bookmarks, network.client for Sparkle, and Sparkle's
# two mach-lookup temporary exceptions. Anything else (disable-library-validation, JIT,
# unsigned executable memory, dyld env vars, get-task-allow, broader file access, extra
# temporary exceptions) fails the audit.
#
# Modes:
#   entitlements-audit.sh                  static audit of App/ModernPAR.entitlements (CI, every push)
#   entitlements-audit.sh --app <path>     audit a SIGNED .app: effective entitlements, hardened
#                                          runtime flag, and no get-task-allow on any Mach-O
#                                          (release gate — a Debug build correctly fails this)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS_FILE="$REPO_ROOT/App/ModernPAR.entitlements"

audit_plist() {
  # $1 = plist path, $2 = human label, $3 = "release" to forbid get-task-allow explicitly,
  # $4 = the prefix the mach-lookup names must carry verbatim (the literal build-setting
  #      variable in static mode; the app's real CFBundleIdentifier in --app mode — anything
  #      else means the entitlements were signed unexpanded/mismatched and Sparkle's XPC
  #      lookup will be DENIED in the field while every other gate stays green).
  /usr/bin/python3 - "$1" "$2" "${3:-}" "${4:?audit_plist needs the expected mach-lookup prefix}" <<'PY'
import plistlib, sys

path, label, mode, prefix = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, "rb") as f:
    ent = plistlib.load(f)

MACH_LOOKUP = "com.apple.security.temporary-exception.mach-lookup.global-name"
REQUIRED_TRUE = [
    "com.apple.security.app-sandbox",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.files.bookmarks.app-scope",
    "com.apple.security.network.client",
]
ALLOWED = set(REQUIRED_TRUE) | {MACH_LOOKUP}

errors = []
for key in REQUIRED_TRUE:
    if ent.get(key) is not True:
        errors.append(f"required entitlement missing or not true: {key}")

# Sparkle's two services, exactly: <prefix>-spks + <prefix>-spki, full-string compared —
# order-insensitive, nothing extra, no foreign or unexpanded prefixes.
lookup = ent.get(MACH_LOOKUP)
if not isinstance(lookup, list):
    errors.append(f"{MACH_LOOKUP} missing or not an array")
else:
    expected = {f"{prefix}-spks", f"{prefix}-spki"}
    if set(lookup) != expected or len(lookup) != 2:
        errors.append(
            f"{MACH_LOOKUP} must be exactly {sorted(expected)}, got {lookup}")

for key in sorted(ent):
    if key not in ALLOWED:
        errors.append(f"entitlement not on the allowlist: {key}")

if mode == "release" and ent.get("com.apple.security.get-task-allow"):
    errors.append("get-task-allow present in a release-signed app")

if errors:
    print(f"entitlements-audit: FAIL ({label})")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)
print(f"entitlements-audit: OK ({label}: {len(ent)} entitlements, all on the allowlist)")
PY
}

if [ "${1:-}" = "--app" ]; then
  APP="${2:?usage: entitlements-audit.sh --app <path-to-.app>}"
  [ "$#" -eq 2 ] || { echo "entitlements-audit: unexpected extra arguments after --app" >&2; exit 2; }
  [ -d "$APP" ] || { echo "entitlements-audit: no app bundle at $APP" >&2; exit 1; }

  # 1) Effective (signed-in) entitlements of the main executable.
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  codesign -d --entitlements "$TMP/app.plist" --xml "$APP" 2>/dev/null \
    || { echo "entitlements-audit: cannot read entitlements — is $APP signed?" >&2; exit 1; }
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    "$APP/Contents/Info.plist" 2>/dev/null) \
    || { echo "entitlements-audit: cannot read CFBundleIdentifier from $APP" >&2; exit 1; }
  audit_plist "$TMP/app.plist" "$APP (signed)" release "$BUNDLE_ID"

  # 2) Hardened runtime flag on the app seal. (Capture-then-test everywhere below: piping
  #    into `grep -q` under pipefail kills the writer with SIGPIPE at the first match.)
  SIGN_INFO=$(codesign -dv "$APP" 2>&1)
  if [[ "$SIGN_INFO" != *"flags="*runtime* ]]; then
    echo "entitlements-audit: FAIL — hardened runtime flag missing on $APP" >&2
    exit 1
  fi
  echo "entitlements-audit: OK (hardened runtime flag present)"

  # 3) No Mach-O anywhere in the bundle may carry get-task-allow, and every one must be
  #    runtime-hardened (notarization rejects either).
  STATUS=0
  while IFS= read -r -d '' f; do
    [[ "$(file -b "$f")" == *Mach-O* ]] || continue
    ENT_XML=$(codesign -d --entitlements - "$f" 2>/dev/null || true)
    if [[ "$ENT_XML" == *get-task-allow* ]]; then
      echo "entitlements-audit: FAIL — get-task-allow on $f" >&2
      STATUS=1
    fi
    MACHO_INFO=$(codesign -dv "$f" 2>&1 || true)
    if [[ "$MACHO_INFO" != *"flags="*runtime* ]]; then
      echo "entitlements-audit: FAIL — hardened runtime missing on $f" >&2
      STATUS=1
    fi
  done < <(find "$APP" -type f -print0)
  [ "$STATUS" -eq 0 ] && echo "entitlements-audit: OK (no get-task-allow, all Mach-Os hardened)"
  exit "$STATUS"
fi

if [ "$#" -ne 0 ]; then
  echo "entitlements-audit: unknown argument(s): $*" >&2
  echo "usage: entitlements-audit.sh [--app <path-to-.app>]" >&2
  exit 2
fi

# Static mode: the source file legitimately carries the build-setting variable — but it must
# be EXACTLY that spelling (release.sh's expansion matches only this form; a ${…} or
# :rfc1034identifier variant would sign through unexpanded).
audit_plist "$ENTITLEMENTS_FILE" "App/ModernPAR.entitlements (static)" "" \
  '$(PRODUCT_BUNDLE_IDENTIFIER)'
