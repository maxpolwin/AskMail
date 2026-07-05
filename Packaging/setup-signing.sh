#!/usr/bin/env bash
# One-time: create a stable self-signed code-signing identity in the login
# keychain so build-app.sh can sign AskMail.app with a constant designated
# requirement. That lets a single Full Disk Access grant survive rebuilds
# (ad-hoc signing changes the cdhash every build and breaks the grant).
#
# Safe to re-run: it no-ops if the identity already exists. See docs/dev-signing.md.
set -euo pipefail

CN="AskMail Dev Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Identity '$CN' already exists — nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > openssl.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = AskMail Dev Signing
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout key.pem -out cert.pem -days 3650 -config openssl.cnf >/dev/null 2>&1
openssl pkcs12 -export -inkey key.pem -in cert.pem \
  -out ident.p12 -passout pass:askmaildev -name "$CN" >/dev/null 2>&1

echo "Importing into login keychain (-A avoids per-app codesign prompts)…"
security import ident.p12 -k "$KEYCHAIN" -P askmaildev -A

echo "Done. Now run Packaging/build-app.sh, then grant Full Disk Access to"
echo ".build/AskMail.app once — the grant will persist across rebuilds."
