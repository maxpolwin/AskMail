#!/bin/bash
# Builds a release AskMail.app, signs it with the Developer ID Application
# certificate (hardened runtime, timestamped), packages it into a signed DMG,
# and notarizes/staples it. Produces a DMG ready to hand to other users.
#
# One-time setup before running this:
#   xcrun notarytool store-credentials "askmail-notary" \
#     --apple-id "you@example.com" --team-id PDPT7GQQWN --password "app-specific-password"
# (Generate the app-specific password at https://appleid.apple.com > Sign-In and Security.)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AskMail"
IDENTITY="Developer ID Application: Max Polwin (PDPT7GQQWN)"
NOTARY_PROFILE="askmail-notary"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"

BUILD_DIR=".build/release-pkg"
APP="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
DMG_STAGING="$BUILD_DIR/dmg-staging"

if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "error: signing identity '$IDENTITY' not found in keychain." >&2
  echo "Run 'security find-identity -v -p codesigning' to see available identities." >&2
  exit 1
fi

echo "==> Building release binary..."
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP..."
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/askmail" "$APP/Contents/MacOS/askmail"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing with Developer ID (hardened runtime)..."
codesign --force --deep --options runtime --timestamp \
  --entitlements Packaging/AskMail.entitlements \
  --sign "$IDENTITY" "$APP"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose "$APP" || true

echo "==> Building DMG..."
mkdir -p "$DMG_STAGING"
cp -R "$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" \
  -ov -format UDZO "$DMG_PATH"

echo "==> Signing DMG..."
codesign --force --sign "$IDENTITY" "$DMG_PATH"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo
  echo "warning: no stored notarytool credentials found under profile '$NOTARY_PROFILE'."
  echo "Run this once, then re-run this script:"
  echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
  echo "    --apple-id \"you@example.com\" --team-id PDPT7GQQWN --password \"app-specific-password\""
  echo
  echo "Skipping notarization/stapling. DMG is signed but not notarized: $DMG_PATH"
  exit 0
fi

echo "==> Submitting for notarization (this can take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo "==> Final Gatekeeper check..."
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"

echo
echo "Done: $DMG_PATH"
