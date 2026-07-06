#!/bin/bash
# Assembles a real AskMail.app bundle around the SwiftPM executables, signed
# with the hardened runtime and minimal entitlements (hardening H-1, H-2,
# H-4, H-6 — see docs/hardening.md).
#
# `swift run askmail` launches a bare Mach-O binary with no Info.plist and no
# icon, so anything macOS registers for it (notably the Full Disk Access
# entry in System Settings) shows a blank icon. This script builds the
# release binaries and wraps them in a proper .app bundle (Info.plist + icon
# + code signature) so the app has a real identity and icon everywhere,
# including Privacy & Security.
#
# The bundle also embeds a sandboxed parser XPC service (H-6): all untrusted
# .emlx/MIME/HTML/PDF parsing runs there, isolated from the main app's Full
# Disk Access and Keychain access.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building release binaries..."
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

APP=".build/AskMail.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/XPCServices"

cp "$BIN_PATH/askmail" "$APP/Contents/MacOS/askmail"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The XPC service's bundle id (Packaging/AskMailParserXPC-Info.plist) must
# match its directory name and the ParserXPC.serviceName the app connects to.
XPC="$APP/Contents/XPCServices/com.askmail.app.parser.xpc"
mkdir -p "$XPC/Contents/MacOS"
cp "$BIN_PATH/AskMailParserXPC" "$XPC/Contents/MacOS/AskMailParserXPC"
cp Packaging/AskMailParserXPC-Info.plist "$XPC/Contents/Info.plist"

# ASKMAIL_SIGN_IDENTITY names a real "Developer ID Application: ..." identity
# for a release build. A secure timestamp is requested only on this path
# (H-1): it needs network access to Apple's timestamp authority, and Apple's
# notary service (Packaging/notarize.sh, H-3) requires it — but a routine
# offline dev rebuild shouldn't depend on that network call. Otherwise,
# prefer the stable self-signed dev identity so the Full Disk Access grant
# survives rebuilds (ad-hoc signing changes the cdhash each build and breaks
# it); falls back to ad-hoc if that identity isn't installed. Dev identity is
# never notarizable — see Packaging/setup-signing.sh and docs/dev-signing.md.
DEV_IDENTITY="AskMail Dev Signing"
if [ -n "${ASKMAIL_SIGN_IDENTITY:-}" ]; then
  MODE="release"
elif security find-certificate -c "$DEV_IDENTITY" >/dev/null 2>&1; then
  MODE="dev-stable"
else
  MODE="dev-adhoc"
fi

# Every path adds the hardened runtime (H-1) and each component's own
# minimal entitlements (H-2/H-6 — no App Sandbox for the main app since FDA
# needs it, App Sandbox + nothing else for the parser service).
sign() {
  local target="$1" entitlements="$2"
  case "$MODE" in
    release)
      codesign --force --timestamp --options runtime \
        --entitlements "$entitlements" --sign "$ASKMAIL_SIGN_IDENTITY" "$target"
      ;;
    dev-stable)
      codesign --force --options runtime --entitlements "$entitlements" --sign "$DEV_IDENTITY" "$target"
      ;;
    dev-adhoc)
      codesign --force --options runtime --entitlements "$entitlements" --sign - "$target"
      ;;
  esac
}

# Inside-out (H-4): sign the nested XPC service before the app that embeds
# it. Never `--deep` — it would sign nested code with the outer bundle's
# identifier/entitlements instead of the service's own sandboxed ones.
echo "Signing parser XPC service..."
sign "$XPC" "Packaging/AskMailParserXPC.entitlements"
codesign --verify --strict "$XPC"

echo "Signing AskMail.app..."
sign "$APP" "Packaging/AskMail.entitlements"
codesign --verify --strict --deep "$APP"

case "$MODE" in
  release)
    echo
    echo "Signed and verified with Developer ID identity '$ASKMAIL_SIGN_IDENTITY'."
    echo "Run Packaging/notarize.sh next to notarize and staple."
    exit 0
    ;;
  dev-stable)
    echo "Signed $APP with the stable '$DEV_IDENTITY' identity (hardened runtime)."
    STABLE=1
    ;;
  dev-adhoc)
    echo "Ad-hoc signed $APP (hardened runtime). Run Packaging/setup-signing.sh once for a"
    echo "stable identity so the Full Disk Access grant survives future rebuilds."
    STABLE=0
    ;;
esac

echo
echo "Built $APP"
echo
echo "If you previously granted Full Disk Access to an older build (the raw"
echo "'askmail' binary or an ad-hoc bundle), remove that stale entry in System"
echo "Settings > Privacy & Security > Full Disk Access, then add $APP and enable it."
if [ "$STABLE" = 1 ]; then
  echo "With the stable identity, that grant will now persist across rebuilds."
fi
echo
echo "This is a dev signature — not a Developer ID, not notarized. Gatekeeper"
echo "will still block this bundle for anyone else it's shared with. For a"
echo "release build: ASKMAIL_SIGN_IDENTITY=\"Developer ID Application: ...\" $0"
echo "then Packaging/notarize.sh."
