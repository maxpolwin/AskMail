#!/usr/bin/env bash
# Submits AskMail.app to Apple's notary service and staples the ticket
# (hardening H-3). Run after build-app.sh has produced a Developer-ID-signed
# bundle — this script refuses anything else, since Apple's notary service
# would just reject it server-side with a less useful error.
#
# One-time setup: create a notarytool credential profile (an app-specific
# password, generated at appleid.apple.com, not your Apple ID password):
#   xcrun notarytool store-credentials "AskMail Notary" \
#     --apple-id "you@example.com" --team-id "<TEAMID>" \
#     --password "<app-specific-password>"
# Credentials go in the login keychain via notarytool itself; this script
# never sees or handles them directly.
#
# Usage:
#   ASKMAIL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#     Packaging/build-app.sh
#   ASKMAIL_NOTARY_PROFILE="AskMail Notary" Packaging/notarize.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP=".build/AskMail.app"
PROFILE="${ASKMAIL_NOTARY_PROFILE:-}"

if [ -z "$PROFILE" ]; then
  echo "error: set ASKMAIL_NOTARY_PROFILE to a notarytool credential profile name." >&2
  echo "Create one once with: xcrun notarytool store-credentials ..." >&2
  exit 1
fi

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run Packaging/build-app.sh first." >&2
  exit 1
fi

# Refuse anything not signed with a real Developer ID: notarization requires
# it, and a clear local error beats an opaque server-side rejection.
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | awk -F'=' '/^Authority=/{print $2; exit}')"
case "$AUTHORITY" in
  "Developer ID Application:"*)
    echo "Signed with: $AUTHORITY"
    ;;
  *)
    echo "error: $APP isn't signed with a Developer ID Application identity" >&2
    echo "(found: '${AUTHORITY:-none}')." >&2
    echo "Re-run build-app.sh with ASKMAIL_SIGN_IDENTITY set to your Developer ID first." >&2
    exit 1
    ;;
esac

ZIP="$(mktemp -t askmail-notarize).zip"
trap 'rm -f "$ZIP"' EXIT

echo "Zipping $APP for submission..."
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple's notary service (profile: $PROFILE)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling the notarization ticket..."
xcrun stapler staple "$APP"

echo "Verifying Gatekeeper acceptance and the stapled ticket..."
spctl -a -vvv -t exec "$APP"
xcrun stapler validate "$APP"

echo
echo "Done. $APP is signed, notarized, and stapled."
