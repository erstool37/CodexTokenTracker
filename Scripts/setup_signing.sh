#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity so the app's signature
# (and therefore its keychain ACL / "Always Allow") stays constant across rebuilds.
# Idempotent: re-running does nothing once the identity exists.
set -euo pipefail

IDENTITY_CN="CodexTokenTracker Self Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY_CN" >/dev/null 2>&1; then
  echo "Signing identity already present: $IDENTITY_CN"
  exit 0
fi

OPENSSL_BIN="$(command -v openssl || true)"
if [ -x /opt/homebrew/bin/openssl ]; then
  OPENSSL_BIN="/opt/homebrew/bin/openssl"
fi
if [ -z "$OPENSSL_BIN" ]; then
  echo "ERROR: openssl not found" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = codesign
prompt = no

[ dn ]
CN = $IDENTITY_CN

[ codesign ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

"$OPENSSL_BIN" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/openssl.cnf"

# macOS `security import` needs an old-style PKCS12: legacy ciphers AND a SHA1 MAC.
# OpenSSL 3 defaults to a SHA-256 MAC that the importer rejects ("MAC verification failed").
P12_COMPAT_FLAGS=""
if "$OPENSSL_BIN" pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
  P12_COMPAT_FLAGS="-legacy"
fi
if "$OPENSSL_BIN" pkcs12 -help 2>&1 | grep -q -- "-macalg"; then
  P12_COMPAT_FLAGS="$P12_COMPAT_FLAGS -macalg sha1"
fi
# A non-empty transport password is required: macOS rejects empty-password PKCS12
# MACs ("MAC verification failed"). This password is only used for the import handoff.
P12_PASS="codextracker-transport"
"$OPENSSL_BIN" pkcs12 -export $P12_COMPAT_FLAGS -descert \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$P12_PASS" -name "$IDENTITY_CN"

# -A: let any app use the key without a per-use prompt; -T codesign: explicit allow.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A -T /usr/bin/codesign

echo "Imported signing identity: $IDENTITY_CN"
security find-identity -p codesigning | grep "$IDENTITY_CN" || true
