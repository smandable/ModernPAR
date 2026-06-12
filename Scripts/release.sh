#!/bin/bash
# ModernPAR release pipeline (ROADMAP Phase 9; doc-06 §5).
#
# Build → sign bottom-up → notarize the .app → staple the .app → DMG → notarize the DMG →
# staple the DMG → verify everything. Both the DMG and the inner .app end up stapled, so
# Gatekeeper passes offline whether the user keeps the DMG or Sparkle extracts the app.
#
# Signing rules (doc-06 §5a): bottom-up, never --deep; Hardened Runtime + --timestamp on
# every Mach-O; the app last, with the expanded entitlements ($(PRODUCT_BUNDLE_IDENTIFIER)
# is a BUILD-SETTING variable — codesign does not substitute it, so we expand it here).
#
# Usage:
#   Scripts/release.sh                          # full release (Developer ID + notarization)
#   Scripts/release.sh --adhoc                  # smoke test: ad-hoc identity, no notarization
#   Scripts/release.sh --skip-notarize          # signed but not notarized (local testing)
#
# Options:
#   --identity "Developer ID Application: …"    signing identity (default: first Developer ID
#                                               Application in the keychain)
#   --version X.Y.Z                             MARKETING_VERSION (default: latest v* tag,
#                                               else the project default)
#   --build-number N                            CURRENT_PROJECT_VERSION / CFBundleVersion,
#                                               must increase monotonically for Sparkle
#                                               (default: git commit count)
#   --notary-profile NAME                       notarytool keychain profile (default:
#                                               ModernPAR-Notary; local path)
#   --notary-key FILE --notary-key-id ID --notary-issuer ISSUER
#                                               App Store Connect API key (CI path)
#   --output DIR                                artifact directory (default: dist)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

IDENTITY=""
ADHOC=0
NOTARIZE=1
NOTARY_PROFILE="ModernPAR-Notary"
NOTARY_KEY="" NOTARY_KEY_ID="" NOTARY_ISSUER=""
VERSION=""
BUILD_NUMBER=""
EXPLICIT_BUILD_NUMBER=0
OUTDIR="dist"

while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --adhoc) ADHOC=1; NOTARIZE=0; shift ;;
    --skip-notarize) NOTARIZE=0; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; EXPLICIT_BUILD_NUMBER=1; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
    --notary-key) NOTARY_KEY="$2"; shift 2 ;;
    --notary-key-id) NOTARY_KEY_ID="$2"; shift 2 ;;
    --notary-issuer) NOTARY_ISSUER="$2"; shift 2 ;;
    --output) OUTDIR="$2"; shift 2 ;;
    *) echo "release: unknown option $1" >&2; exit 2 ;;
  esac
done

if [ "$ADHOC" -eq 1 ]; then
  IDENTITY="-"
elif [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  if [ -z "$IDENTITY" ]; then
    echo "release: no Developer ID Application identity in the keychain." >&2
    echo "release: create one at developer.apple.com, or run with --adhoc to smoke-test." >&2
    exit 1
  fi
fi

# --timestamp needs a real certificate; ad-hoc signing cannot reach a timestamp authority.
TIMESTAMP_FLAG="--timestamp"
[ "$ADHOC" -eq 1 ] && TIMESTAMP_FLAG="--timestamp=none"

if [ -z "$VERSION" ]; then
  VERSION=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)
fi
[ -z "$BUILD_NUMBER" ] && BUILD_NUMBER=$(git rev-list --count HEAD)

# Sparkle orders updates by CFBundleVersion, so the build number must STRICTLY grow between
# releases. The commit-count default is not monotonic across branches or rewritten history —
# fail fast against every existing v* tag rather than shipping an update nobody is offered.
# An explicit --build-number is the operator's override.
if [ "$EXPLICIT_BUILD_NUMBER" -eq 0 ]; then
  MAX_PREV=0
  HEAD_SHA=$(git rev-parse HEAD)
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    sha=$(git rev-parse -q --verify "$tag^{commit}" 2>/dev/null || true)
    [ -n "$sha" ] && [ "$sha" != "$HEAD_SHA" ] || continue
    count=$(git rev-list --count "$tag" 2>/dev/null || echo 0)
    [ "$count" -gt "$MAX_PREV" ] && MAX_PREV=$count
  done < <(git tag -l 'v*')
  if [ "$BUILD_NUMBER" -le "$MAX_PREV" ]; then
    echo "release: build number $BUILD_NUMBER does not exceed an existing release tag's" \
      "$MAX_PREV — Sparkle would never offer this update. Pass --build-number explicitly." >&2
    exit 1
  fi
fi

APP="build/Build/Products/Release/ModernPAR.app"
ENT_SRC="App/ModernPAR.entitlements"

# One temp root, one cleanup path — partial runs must not strew app-sized leftovers.
TMPROOT=$(mktemp -d -t ModernPAR-release)
trap 'rm -rf "$TMPROOT"' EXIT

echo "release: identity      = $IDENTITY"
echo "release: version       = ${VERSION:-<project default>}"
echo "release: build number  = $BUILD_NUMBER"
echo "release: notarization  = $([ "$NOTARIZE" -eq 1 ] && echo on || echo OFF)"

# ── 1) Build (unsigned: every signature below is ours, applied bottom-up) ────────────────
VERSION_SETTINGS=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
[ -n "$VERSION" ] && VERSION_SETTINGS+=(MARKETING_VERSION="$VERSION")

xcodebuild -project ModernPAR.xcodeproj -scheme ModernPAR \
  -configuration Release -derivedDataPath build \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  "${VERSION_SETTINGS[@]}" \
  clean build

test -d "$APP" || { echo "release: no app at $APP" >&2; exit 1; }

# The identifier everything below keys on — read from the BUILT app, never hardcoded
# (project.pbxproj owns PRODUCT_BUNDLE_IDENTIFIER; a stale duplicate here would sign
# mach-lookup exception names Sparkle's XPC services don't actually use).
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
[ -n "$BUNDLE_ID" ] || { echo "release: empty CFBundleIdentifier in built app" >&2; exit 1; }

# Ship gate: a notarized build must carry a REAL Sparkle public key. Shipping the empty
# placeholder would field a fleet of apps whose updater is permanently dead — exactly the
# state the UpdaterConfiguration gate makes silent.
if [ "$NOTARIZE" -eq 1 ]; then
  ED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)
  if ! printf '%s' "$ED_KEY" | /usr/bin/python3 -c '
import base64, sys
raw = sys.stdin.read().strip()
try:
    key = base64.b64decode(raw, validate=True)
except Exception:
    sys.exit(1)
sys.exit(0 if len(key) == 32 else 1)'; then
    echo "release: SUPublicEDKey in the built Info.plist is missing or a placeholder —" \
      "a notarized release would ship with a dead updater. Generate the key" \
      "(Scripts/sign-update.sh generate-keys), set it in App/Info.plist, or use" \
      "--skip-notarize for a local test build." >&2
    exit 1
  fi
fi

# The bundled Sparkle license text must match the resolved package's LICENSE — the in-test
# gate can only content-sniff (no package checkout under swift test), so the release path
# does the byte-compare.
SPARKLE_LICENSE="build/SourcePackages/artifacts/sparkle/Sparkle/LICENSE"
BUNDLED_SPARKLE_LICENSE="Packages/PARKit/Sources/ModernPARUI/Resources/Licenses/Sparkle.txt"
if [ -f "$SPARKLE_LICENSE" ] && ! cmp -s "$SPARKLE_LICENSE" "$BUNDLED_SPARKLE_LICENSE"; then
  echo "release: bundled Sparkle license (Resources/Licenses/Sparkle.txt) drifted from the" \
    "resolved package's LICENSE — update the copy before releasing." >&2
  exit 1
fi

# Belt and braces: nothing in the bundle may carry a foreign slice (the build phase already
# thinned Sparkle; a regression here must stop the release, not ship).
while IFS= read -r -d '' f; do
  [[ "$(file -b "$f")" == *Mach-O* ]] || continue
  archs=$(lipo -archs "$f" 2>/dev/null || true)
  if [ -n "$archs" ] && [ "$archs" != "arm64" ]; then
    echo "release: $f is not arm64-only (archs: $archs)" >&2
    exit 1
  fi
done < <(find "$APP" -type f -print0)

# ── 2) Strip extended attributes that break signing ──────────────────────────────────────
xattr -cr "$APP"

# ── 3) Sign bottom-up ─────────────────────────────────────────────────────────────────────
# Expand build-setting variables in the entitlements (codesign takes them literally), and
# refuse to sign if ANY variable spelling survived the expansion — an unexpanded mach-lookup
# name would silently break Sparkle's XPC lookup in the field.
ENT_EXPANDED="$TMPROOT/entitlements.plist"
sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" "$ENT_SRC" >"$ENT_EXPANDED"
plutil -lint "$ENT_EXPANDED" >/dev/null
if grep -q "PRODUCT_BUNDLE_IDENTIFIER" "$ENT_EXPANDED"; then
  echo "release: entitlements still reference PRODUCT_BUNDLE_IDENTIFIER after expansion —" \
    "the file uses a variable spelling this script does not handle." >&2
  exit 1
fi

# 3a. Nested code, deepest first: every .xpc/.app/.framework under Frameworks plus loose
#     Mach-O executables that aren't some bundle's main binary (Sparkle's Autoupdate).
#     --preserve-metadata keeps each item's own entitlements (Sparkle's XPC services need
#     theirs); ours go only on the app itself.
FRAMEWORKS_DIR="$APP/Contents/Frameworks"
if [ -d "$FRAMEWORKS_DIR" ]; then
  ITEMS="$TMPROOT/signables"
  : >"$ITEMS"
  while IFS= read -r -d '' bundle; do
    printf '%d\t%s\n' "$(tr -dc '/' <<<"$bundle" | wc -c)" "$bundle" >>"$ITEMS"
  done < <(find "$FRAMEWORKS_DIR" -mindepth 1 -type d \
    \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" \) -print0)
  while IFS= read -r -d '' f; do
    [[ "$(file -b "$f")" == *Mach-O* ]] || continue
    parent=$(dirname "$f"); name=$(basename "$f")
    case "$parent" in
      */Contents/MacOS) continue ;;
      *.framework/Versions/*)
        fw=$(basename "$(dirname "$(dirname "$parent")")" .framework)
        [ "$name" = "$fw" ] && continue ;;
    esac
    printf '%d\t%s\n' "$(tr -dc '/' <<<"$f" | wc -c)" "$f" >>"$ITEMS"
  done < <(find "$FRAMEWORKS_DIR" -type f -perm +111 -print0)

  sort -rn "$ITEMS" | cut -f2- | while IFS= read -r item; do
    echo "release: sign $item"
    codesign --force --options runtime $TIMESTAMP_FLAG \
      --preserve-metadata=entitlements --sign "$IDENTITY" "$item"
  done
fi

# 3b. The app, last, with OUR entitlements.
echo "release: sign $APP"
codesign --force --options runtime $TIMESTAMP_FLAG \
  --entitlements "$ENT_EXPANDED" --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"

# ── 4) Verify before submitting ───────────────────────────────────────────────────────────
# (No `cmd | grep -q` under pipefail: grep -q closes the pipe at the first match and the
# writer dies with SIGPIPE=141, failing the pipeline. Capture, then test.)
codesign --verify --deep --strict --verbose=2 "$APP"
SIGN_INFO=$(codesign -dv "$APP" 2>&1)
case "$SIGN_INFO" in
  *"flags="*runtime*) ;;
  *) echo "release: hardened runtime flag missing" >&2; exit 1 ;;
esac
if [ "$ADHOC" -eq 0 ]; then
  Scripts/entitlements-audit.sh --app "$APP"
else
  echo "release: (adhoc) skipping strict entitlements audit gate"
fi

# ── 5) Notarize + staple the .app, then build/notarize/staple the DMG ────────────────────
notary_args=()
if [ -n "$NOTARY_KEY" ]; then
  notary_args=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
fi

notarize() {
  # $1 = artifact. submit --wait; on failure pull the log so the offending binary is named.
  local out id status
  out=$(xcrun notarytool submit "$1" "${notary_args[@]}" --wait 2>&1) || true
  echo "$out"
  id=$(sed -n 's/^[[:space:]]*id: \([0-9a-f-]*\)$/\1/p' <<<"$out" | head -1)
  status=$(sed -n 's/^[[:space:]]*status: \(.*\)$/\1/p' <<<"$out" | tail -1)
  if [ "$status" != "Accepted" ]; then
    echo "release: notarization FAILED for $1 (status: ${status:-unknown})" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" "${notary_args[@]}" >&2
    exit 1
  fi
}

mkdir -p "$OUTDIR"
DMG_VERSION="${VERSION:-$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)}"
DMG="$OUTDIR/ModernPAR-$DMG_VERSION.dmg"

if [ "$NOTARIZE" -eq 1 ]; then
  ZIP="$TMPROOT/ModernPAR.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "release: notarizing the .app"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# ditto, not cp -R: cp filters every mode through the caller's umask, which can strip
# group/other execute bits inside the bundle on a restrictive shell.
STAGING="$TMPROOT/dmg-staging"
mkdir "$STAGING"
ditto "$APP" "$STAGING/ModernPAR.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "ModernPAR" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

# Sign the DMG itself BEFORE notarizing it, so the ticket covers the image's own cdhash and
# spctl's context:primary-signature verdict works offline.
codesign --force --sign "$IDENTITY" $TIMESTAMP_FLAG "$DMG"

if [ "$NOTARIZE" -eq 1 ]; then
  echo "release: notarizing the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  # The end-to-end Gatekeeper verdicts (what a clean offline Mac will decide).
  spctl --assess --type execute --verbose "$APP"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
else
  echo "release: NOTARIZATION SKIPPED — $DMG is not shippable"
fi

shasum -a 256 "$DMG"
echo "release: done → $DMG"
if [ "$NOTARIZE" -eq 1 ]; then
  cat <<EOF

Next (Sparkle): sign the DMG for the appcast —
  Scripts/sign-update.sh "$DMG"
EOF
fi
