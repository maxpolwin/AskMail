#!/usr/bin/env bash
# Packages an already-built .build/AskMail.app into a distributable DMG,
# signing the DMG itself with the same Developer ID identity. Run this after
# build-app.sh (with ASKMAIL_SIGN_IDENTITY set) and notarize.sh, in that
# order, so the .app inside is Developer-ID-signed and notarized before it
# ever gets zipped into the DMG.
#
# Usage:
#   ASKMAIL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#     Packaging/build-app.sh
#   ASKMAIL_NOTARY_PROFILE="AskMail Notary" Packaging/notarize.sh
#   ASKMAIL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#     Packaging/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP=".build/AskMail.app"
IDENTITY="${ASKMAIL_SIGN_IDENTITY:-}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
DMG_NAME="AskMail-$VERSION.dmg"
STAGING=".build/dmg-staging"
DMG_PATH=".build/$DMG_NAME"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run Packaging/build-app.sh first." >&2
  exit 1
fi

if [ -z "$IDENTITY" ]; then
  echo "error: set ASKMAIL_SIGN_IDENTITY to the Developer ID Application identity" >&2
  echo "used to sign $APP, so the DMG can be signed with the same identity." >&2
  exit 1
fi

# Refuse anything not signed with a real Developer ID — same check notarize.sh
# uses, so a mis-signed .app fails fast here instead of via a confusing DMG
# Gatekeeper rejection later.
# awk's early `exit` closes the pipe before codesign finishes writing, which
# sends codesign a SIGPIPE; with pipefail that kills this whole script (exit
# 141) before ever reaching the check below. Disable pipefail for this line.
set +o pipefail
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | awk -F'=' '/^Authority=/{print $2; exit}')"
set -o pipefail
case "$AUTHORITY" in
  "Developer ID Application:"*) ;;
  *)
    echo "error: $APP isn't signed with a Developer ID Application identity" >&2
    echo "(found: '${AUTHORITY:-none}'). Run build-app.sh with ASKMAIL_SIGN_IDENTITY first." >&2
    exit 1
    ;;
esac

echo "Staging DMG contents..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "Building $DMG_PATH..."
rm -f "$DMG_PATH"
hdiutil create -volname "AskMail" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING"

echo "Signing DMG..."
codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

# Gatekeeper checks the outer container a user actually downloads, not just
# the .app nested inside it — the .app's own notarization ticket (from
# notarize.sh) doesn't cover the DMG. Notarize and staple the DMG itself too.
PROFILE="${ASKMAIL_NOTARY_PROFILE:-}"
if [ -z "$PROFILE" ]; then
  echo
  echo "warning: ASKMAIL_NOTARY_PROFILE not set — skipping DMG notarization."
  echo "Gatekeeper will show an 'unidentified developer' warning for this DMG"
  echo "until it's notarized. Re-run with:"
  echo "  ASKMAIL_SIGN_IDENTITY=\"$IDENTITY\" ASKMAIL_NOTARY_PROFILE=\"<profile>\" $0"
else
  echo "Submitting DMG to Apple's notary service (profile: $PROFILE)..."
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait
  echo "Stapling notarization ticket to the DMG..."
  xcrun stapler staple "$DMG_PATH"
fi

echo
echo "Done: $DMG_PATH"
