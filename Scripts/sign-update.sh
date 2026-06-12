#!/bin/bash
# Sparkle appcast helpers (ROADMAP Phase 9; doc-06 §6).
#
# Wraps the tools that ship inside the RESOLVED Sparkle package (pinned in
# ModernPAR.xcodeproj/…/Package.resolved) so the signing tool version always matches the
# embedded framework. The tools appear under build/SourcePackages/artifacts after any
# xcodebuild of the app (or `xcodebuild -resolvePackageDependencies`).
#
# Usage:
#   Scripts/sign-update.sh generate-keys           one-time: create the EdDSA keypair
#                                                  (private key lands in the login keychain;
#                                                  prints the public key for Info.plist)
#   Scripts/sign-update.sh <update.dmg>            print the sparkle:edSignature attribute
#                                                  (key from the keychain)
#   echo "$KEY" | Scripts/sign-update.sh --ed-key-file - <update.dmg>
#                                                  CI: private key on stdin
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_BIN="$REPO_ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"

if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  echo "sign-update: Sparkle tools not found at $SPARKLE_BIN" >&2
  echo "sign-update: run a build first (they arrive with package resolution):" >&2
  echo "  xcodebuild -project ModernPAR.xcodeproj -scheme ModernPAR -derivedDataPath build -resolvePackageDependencies" >&2
  exit 1
fi

case "${1:-}" in
  generate-keys)
    # Forward the remaining args — generate_keys -x <file> (export) / -f <file> (import)
    # must work through the wrapper. Note: -x writes to a FILE path; "-" is not stdout.
    exec "$SPARKLE_BIN/generate_keys" "${@:2}"
    ;;
  "")
    echo "usage: sign-update.sh generate-keys | [sign_update args] <artifact>" >&2
    exit 2
    ;;
  *)
    exec "$SPARKLE_BIN/sign_update" "$@"
    ;;
esac
