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

codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo
echo "If you previously ran the raw 'askmail' binary, remove its entry from"
echo "System Settings > Privacy & Security > Full Disk Access (it has no"
echo "icon) — it's a different identity from this bundle and won't be reused."
echo "Then open $APP (or drag it to /Applications) and re-grant Full Disk"
echo "Access when prompted; it will show the AskMail icon this time."
