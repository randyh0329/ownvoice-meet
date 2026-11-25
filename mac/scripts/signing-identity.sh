#!/bin/bash
# Prints the name of a signing identity that stays the same from build to build, making it once.
#
# macOS keeps a permission (System Audio Recording, Microphone) for the app's code signature. An ad
# hoc signature changes with every build, so every rebuild looked like a new app and asked again.
# This makes a self-signed certificate for code signing, once, in the login keychain; builds signed
# with it keep their permissions. It signs only this Mac's own builds; it is not an Apple
# Developer ID (others' Macs still see an unidentified developer).
set -euo pipefail
NAME="OwnVoice Meet Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "$NAME"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
# The system's openssl (LibreSSL) writes a .p12 that `security import` reads.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
pass=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
  -out "$tmp/identity.p12" -passout "pass:$pass"
security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "made the signing certificate \"$NAME\" in the login keychain" >&2
echo "$NAME"
