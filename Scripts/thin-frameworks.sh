#!/bin/bash
# Thin embedded frameworks to arm64.
#
# Sparkle's SwiftPM artifact ships universal (arm64 + x86_64) binaries, but ModernPAR is
# arm64-only by design and CI fails the build if ANY Mach-O in the bundle carries another
# slice (the Phase 8 exit criterion). This phase strips foreign slices from everything under
# Contents/Frameworks after Xcode embeds the package products.
#
# lipo invalidates the vendor's Developer ID signature, so everything under Frameworks is
# re-signed here bottom-up (deepest nested code first, never --deep), preserving entitlements
# and flags — Sparkle's XPC services carry entitlements they need at runtime. Debug builds
# re-sign ad-hoc; release distribution re-signs the whole tree with the real Developer ID in
# Scripts/release.sh afterwards, so the identity used here only needs to keep the bundle
# launchable locally.
#
# Runs as an Xcode build phase (needs ENABLE_USER_SCRIPT_SANDBOXING=NO: it rewrites files the
# build system doesn't know are ours) and is a no-op when there is nothing embedded.
set -euo pipefail

# Both variables are required — a guessed fallback path would silently no-op the thinning
# and surface later as a baffling arch-gate failure far from the cause.
FRAMEWORKS_DIR="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
KEEP_ARCH="arm64"

if [ ! -d "$FRAMEWORKS_DIR" ]; then
  echo "thin-frameworks: nothing embedded at $FRAMEWORKS_DIR — skipping"
  exit 0
fi

# Identity for re-signing: the build's expanded identity when Xcode is signing, ad-hoc as a
# fallback. When signing is disabled entirely (CI builds with CODE_SIGNING_ALLOWED=NO) we
# still thin but skip re-signing — nothing validates an unsigned CI bundle.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
RESIGN=1
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
  RESIGN=0
fi

# Capture-then-test (never `file | grep -q` under pipefail: grep -q closing the pipe early
# can kill the writer with SIGPIPE and fail the pipeline).
is_macho() {
  [[ "$(file -b "$1" 2>/dev/null)" == *Mach-O* ]]
}

# True when $1 is the main binary of an enclosing bundle — those are sealed when the bundle
# itself is signed and must not be signed as loose files:
#   Foo.framework/Versions/<v>/Foo  (framework main binary)
#   <bundle>/Contents/MacOS/<exe>   (.app / .xpc main binary)
is_bundle_main_binary() {
  local f="$1" parent name
  parent=$(dirname "$f")
  name=$(basename "$f")
  case "$parent" in
    */Contents/MacOS) return 0 ;;
    *.framework/Versions/*)
      local fw
      fw=$(basename "$(dirname "$(dirname "$parent")")" .framework)
      [ "$name" = "$fw" ] && return 0
      ;;
  esac
  return 1
}

thinned_any=0

# 1) Thin every Mach-O under Frameworks that carries a foreign slice.
while IFS= read -r -d '' f; do
  is_macho "$f" || continue
  archs=$(lipo -archs "$f" 2>/dev/null || true)
  [ -n "$archs" ] || continue
  if [ "$archs" = "$KEEP_ARCH" ]; then
    continue
  fi
  if ! printf '%s\n' $archs | grep -qx "$KEEP_ARCH"; then
    echo "thin-frameworks: ERROR: $f has no $KEEP_ARCH slice (archs: $archs)" >&2
    exit 1
  fi
  echo "thin-frameworks: $f ($archs) -> $KEEP_ARCH"
  lipo "$f" -thin "$KEEP_ARCH" -output "$f.thin"
  mv -f "$f.thin" "$f"
  thinned_any=1
done < <(find "$FRAMEWORKS_DIR" -type f -print0)

if [ "$thinned_any" -eq 0 ]; then
  echo "thin-frameworks: all embedded Mach-Os already $KEEP_ARCH-only"
  exit 0
fi

if [ "$RESIGN" -eq 0 ]; then
  echo "thin-frameworks: code signing disabled — thinned without re-signing"
  exit 0
fi

# 2) Re-sign bottom-up. Signable items are (a) every nested code bundle (.xpc / .app /
#    .framework, including the embedded frameworks themselves) and (b) every loose Mach-O
#    executable that is NOT some bundle's main binary (e.g. Sparkle's Versions/B/Autoupdate).
#    A loose executable is always deeper than its enclosing bundle, so one depth-descending
#    sort yields a correct bottom-up order. Never --deep.
ITEMS=$(mktemp)
trap 'rm -f "$ITEMS"' EXIT

while IFS= read -r -d '' bundle; do
  printf '%d\t%s\n' "$(tr -dc '/' <<<"$bundle" | wc -c)" "$bundle" >>"$ITEMS"
done < <(find "$FRAMEWORKS_DIR" -mindepth 1 -type d \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" \) -print0)

while IFS= read -r -d '' f; do
  is_macho "$f" || continue
  is_bundle_main_binary "$f" && continue
  printf '%d\t%s\n' "$(tr -dc '/' <<<"$f" | wc -c)" "$f" >>"$ITEMS"
done < <(find "$FRAMEWORKS_DIR" -type f -perm +111 -print0)

sort -rn "$ITEMS" | cut -f2- | while IFS= read -r item; do
  [ -n "$item" ] || continue
  echo "thin-frameworks: re-sign $item"
  codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements,flags "$item"
done

echo "thin-frameworks: done"
