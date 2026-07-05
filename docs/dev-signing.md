# Dev signing & Full Disk Access

AskMail reads `~/Library/Mail`, which is protected by macOS TCC — the app needs
**Full Disk Access (FDA)** to enumerate accounts and ingest mail.

## Why the grant kept disappearing

Both `swift build` and the default `.app` packaging **ad-hoc sign** the binary.
For an ad-hoc binary macOS ties the FDA grant to the executable's **cdhash**, and
every rebuild re-links and re-signs it → new cdhash → the grant silently stops
matching, even though the app still shows (toggled on) in System Settings.

## The fix: a stable signing identity

Sign the `.app` bundle with a fixed self-signed identity so its *designated
requirement* stays constant:

```
identifier "com.askmail.app" and certificate leaf = H"…"
```

TCC binds the FDA grant to that requirement, which rebuilds don't change.

## Setup (once per machine)

```sh
Packaging/setup-signing.sh     # create the "AskMail Dev Signing" identity
Packaging/build-app.sh         # build .build/AskMail.app, signed with it
```

Then grant FDA **once** to `.build/AskMail.app`: System Settings → Privacy &
Security → Full Disk Access → **+** → ⌘⇧G → paste the path → enable. Remove any
older ad-hoc `askmail` / AskMail entry first — it's a different identity.

## Day-to-day

Rebuild with `Packaging/build-app.sh` — it re-signs with the stable identity, so
the FDA grant keeps working. If the identity isn't installed it falls back to
ad-hoc signing and prints a reminder to run `setup-signing.sh`.
