# Dev signing, Full Disk Access & hardened runtime

AskMail reads `~/Library/Mail`, which is protected by macOS TCC — the app needs
**Full Disk Access (FDA)** to enumerate accounts and ingest mail. It's also a
high-value target if compromised (FDA + Keychain + a derived mailbox copy), so
every build — dev or release — is signed with the **hardened runtime** and a
minimal entitlements file. See [hardening.md](hardening.md) (H-1..H-5) for the
full rationale.

## Why the grant kept disappearing

Ad-hoc signing ties the FDA grant to the executable's **cdhash**, and every
rebuild re-links and re-signs it → new cdhash → the grant silently stops
matching, even though the app still shows (toggled on) in System Settings.

## The fix: a stable signing identity

Sign the `.app` bundle with a fixed self-signed identity so its *designated
requirement* stays constant:

```
identifier "com.askmail.app" and certificate leaf = H"…"
```

TCC binds the FDA grant to that requirement, which rebuilds don't change.

## Setup (once per machine, dev only)

```sh
Packaging/setup-signing.sh     # create the "AskMail Dev Signing" identity
Packaging/build-app.sh         # build .build/AskMail.app, signed with it
```

`setup-signing.sh` imports the key scoped to `/usr/bin/codesign` only (`-T`,
not `-A`) — a local process other than codesign cannot use it to forge
AskMail's signature and inherit its FDA grant (H-5). The identity is
dev-only; it is never notarizable and must never be used for a build handed
to anyone else.

Then grant FDA **once** to `.build/AskMail.app`: System Settings → Privacy &
Security → Full Disk Access → **+** → ⌘⇧G → paste the path → enable. Remove any
older ad-hoc `askmail` / AskMail entry first — it's a different identity.

## Day-to-day

Rebuild with `Packaging/build-app.sh` — it re-signs with the stable identity
(hardened runtime + `Packaging/AskMail.entitlements`, H-1/H-2), so the FDA
grant keeps working. If the identity isn't installed it falls back to
ad-hoc signing (still hardened-runtime-signed) and prints a reminder to run
`setup-signing.sh`.

Verify what actually got signed:

```sh
codesign -dv --verbose=4 .build/AskMail.app        # expect flags=0x10000(runtime)
codesign -d --entitlements :- .build/AskMail.app   # expect only get-task-allow=false
codesign --verify --strict --deep .build/AskMail.app
```

## Release: Developer ID + notarization

A dev-signed build is never notarizable and Gatekeeper will block it for
anyone else it's shared with. For a real release:

```sh
ASKMAIL_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
  Packaging/build-app.sh
ASKMAIL_NOTARY_PROFILE="AskMail Notary" Packaging/notarize.sh
```

`notarize.sh` requires a one-time `notarytool` credential profile (an
app-specific password, not your Apple ID password — see the script's header)
and refuses to submit anything not signed with a real Developer ID identity.
This step needs your own paid Apple Developer Program membership and
credentials; it cannot be run without them.
