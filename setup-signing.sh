#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity ("Snapi Dev") in the
# login keychain. Signing every build with the SAME identity keeps the app's
# TCC (Screen Recording) permission across rebuilds — ad-hoc signing does not,
# because its cdhash changes every build and macOS treats it as a new app.
#
# Run once. Safe to re-run (no-op if the identity already exists).
set -euo pipefail

IDENTITY="Snapi Dev"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "Signing identity \"$IDENTITY\" already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $IDENTITY
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> Generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

# -legacy: macOS `security import` can't read OpenSSL 3's default PKCS12 ciphers.
LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
  LEGACY="-legacy"
fi
openssl pkcs12 -export $LEGACY \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:snapi >/dev/null 2>&1

echo "==> Importing into login keychain (codesign will be allowed to use it)"
security import "$TMP/identity.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P snapi -T /usr/bin/codesign >/dev/null

echo "==> Trusting the certificate for code signing"
# Without trust, codesign reports "0 valid identities". User-level trust
# (no -d) avoids needing an admin password.
security add-trusted-cert \
  -r trustRoot -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "$TMP/cert.pem" >/dev/null 2>&1 || \
  echo "   (trust prompt may appear — approve it, or run: security add-trusted-cert -r trustRoot -p codeSign \"$TMP/cert.pem\")"

# Let codesign use the key without an interactive password prompt.
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true

echo "==> Done. Identity \"$IDENTITY\" ready."
echo "   Rebuild with ./build.sh; grant Screen Recording once and it will stick."
