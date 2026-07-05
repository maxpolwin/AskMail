#!/bin/bash
# Assembles a real AskMail.app bundle around the SwiftPM executable.
#
# `swift run askmail` launches a bare Mach-O binary with no Info.plist and no
# icon, so anything macOS registers for it (notably the Full Disk Access
# entry in System Settings) shows a blank icon. This script builds the
# release binary and wraps it in a proper .app bundle (Info.plist + icon +
# ad-hoc code signature) so the app has a real identity and icon everywhere,
# including Privacy & Security.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building release binary..."
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

APP=".build/AskMail.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/askmail" "$APP/Contents/MacOS/askmail"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer a stable self-signed identity so the Full Disk Access grant survives
# rebuilds (ad-hoc signing changes the cdhash each build and breaks it). Falls
# back to ad-hoc if the identity isn't installed. See Packaging/setup-signing.sh.
IDENTITY="AskMail Dev Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "Signed $APP with the stable '$IDENTITY' identity."
  STABLE=1
else
  codesign --force --deep --sign - "$APP"
  echo "Ad-hoc signed $APP. Run Packaging/setup-signing.sh once for a stable"
  echo "identity so the Full Disk Access grant survives future rebuilds."
  STABLE=0
fi

echo
echo "Built $APP"
echo
echo "If you previously granted Full Disk Access to an older build (the raw"
echo "'askmail' binary or an ad-hoc bundle), remove that stale entry in System"
echo "Settings > Privacy & Security > Full Disk Access, then add $APP and enable it."
if [ "$STABLE" = 1 ]; then
  echo "With the stable identity, that grant will now persist across rebuilds."
fi
