#!/bin/bash
# Create a stable self-signed code-signing identity for hexad, once.
#
# WHY THIS EXISTS
#
# Ad-hoc signing (`codesign --sign -`) gives the app a *different* identity on every build. TCC
# keys its grants on that identity, so every rebuild silently drops both Accessibility and Screen
# Recording — and it drops them in the worst possible way: the switches in System Settings stay
# on, while the APIs return false. That is the root cause behind both permission bugs in
# docs/BUGS.md, and it does not survive anyone else installing this either.
#
# A self-signed certificate in the login keychain fixes it. The identity stays the same across
# builds, so a grant given once stays given. It is not a Developer ID — Gatekeeper still asks
# on first launch, and a downloaded copy still needs the quarantine attribute cleared — but the
# permissions stop evaporating, which is the part that makes the app unusable.
#
# THIS IS NOT RUN BY build.sh. It writes to your login keychain, which is not something a build
# should do behind your back. Run it once, by hand:
#
#     ./Scripts/make-identity.sh
#
# After that every build signs with it automatically. To go back, delete the certificate in
# Keychain Access and builds fall back to ad-hoc on their own.

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="hexad Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "==> '$IDENTITY' already exists and is valid — nothing to do."
    security find-identity -v -p codesigning | grep "$IDENTITY" | sed 's/^/    /'
    exit 0
fi

# A certificate can be present *and* invalid — imported, but never trusted, which is what a run
# that failed at the trust step leaves behind. `find-identity` reports "0 valid identities" then,
# so the check above does not catch it, and a second run would import a duplicate and leave two
# certificates with the same name for codesign to choose between.
#
# So anything wearing this name is removed before starting. The certificate is disposable — it is
# regenerated below in a second — and duplicates are much harder to reason about later than a
# clean rebuild is now.
if security find-certificate -c "$IDENTITY" "$KEYCHAIN" > /dev/null 2>&1; then
    echo "==> removing an earlier, incomplete '$IDENTITY'"
    while security find-certificate -c "$IDENTITY" "$KEYCHAIN" > /dev/null 2>&1; do
        # -t deletes the certificate and its trust settings; the private key goes with it.
        security delete-certificate -c "$IDENTITY" -t "$KEYCHAIN" > /dev/null 2>&1 || break
    done
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> generating a self-signed code-signing certificate"

# extendedKeyUsage=codeSigning is what makes `security find-identity -p codesigning` list it.
# Without it the certificate imports fine and is then invisible to codesign, which looks like
# the script silently failing.
cat > "$WORK/openssl.conf" <<'CONF'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = hexad Local Signing

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/openssl.conf" 2>/dev/null

# One PKCS#12 bundle, because the private key and the certificate have to arrive together —
# importing the certificate alone produces something codesign will not use.
#
# **The algorithms are pinned, and that is not optional.** OpenSSL 3 defaults to AES-256-CBC with
# PBKDF2 and a SHA-256 MAC. Apple's importer — Security.framework, which `security import` calls —
# cannot verify that MAC, and the failure it reports is:
#
#     SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)
#
# which sends you looking for a password problem that does not exist. Pinning 3DES and a SHA-1 MAC
# produces a bundle Apple accepts. Both are weak by modern standards and both are fine here: the
# password is the literal string below, in a file that exists for the length of this script.
#
# Explicit algorithms rather than `-legacy`, which asks for RC2 from OpenSSL's legacy provider and
# fails on installs that do not have it loaded. 3DES is in the default provider everywhere.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout pass:hexad -name "$IDENTITY" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> importing into the login keychain"
echo "    macOS will ask for your password, and may ask again the first time codesign uses it."

# -T /usr/bin/codesign pre-authorises codesign, so builds do not stop on a keychain prompt.
#
# Checked rather than assumed: the import is the step that fails, and it fails with a message
# about passwords that has nothing to do with passwords. Carrying on past it would ask for an
# admin password to trust a certificate that was never imported, and end by reporting success.
if ! security import "$WORK/identity.p12" -k "$KEYCHAIN" -P hexad \
    -T /usr/bin/codesign -T /usr/bin/security; then
    echo
    echo "==> the import failed, so nothing was changed."
    echo "    If the message mentions MAC verification, the PKCS#12 bundle was written with"
    echo "    algorithms Apple's importer cannot read. openssl in PATH is:"
    echo "        $(command -v openssl) — $(openssl version)"
    echo "    This script pins 3DES and a SHA-1 MAC for exactly that reason; a build of openssl"
    echo "    without them would need Apple's own: /usr/bin/openssl"
    exit 1
fi

# Trust it for code signing. Without this the certificate exists but is untrusted, and
# `security find-identity -v -p codesigning` reports "0 valid identities found" — the certificate
# and its key are both sitting in the keychain, and nothing will use them.
#
# **`trustRoot`, not `trustAsRoot`.** The two read as synonyms and are not: `trustRoot` is for a
# certificate that *is* a self-signed root, `trustAsRoot` for treating a non-self-signed
# certificate as one. `openssl req -x509` produces a self-signed certificate, so passing
# `trustAsRoot` describes it wrongly and Security rejects it with:
#
#     SecTrustSettingsSetTrustSettings: One or more parameters passed to a function were not valid.
#
# which names neither the parameter nor the certificate.
#
# **`-d` puts a second copy of the certificate in the System keychain**, while its private key
# stays in the login keychain. Both then match the name, and codesign refuses to guess:
#
#     hexad Local Signing: ambiguous (matches ... System.keychain and ... login.keychain-db)
#
# The admin trust domain is still the right place for this — user-domain trust is not consulted
# for code signing on every macOS version — so the duplicate is accepted and `build.sh` signs by
# SHA-1 hash instead of by name, which is unambiguous however many keychains hold a copy.
echo "==> trusting it for code signing (this needs an admin password)"
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain "$WORK/cert.pem"

# Let codesign use the key without a prompt on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" \
    > /dev/null 2>&1 || true

echo
echo "==> done"
security find-identity -v -p codesigning | grep "$IDENTITY" | sed 's/^/    /'
echo
echo "    Build now and the app keeps one identity across rebuilds, so TCC stops"
echo "    dropping Accessibility and Screen Recording every time you rebuild."
echo
echo "    Grant the permissions once more after the first signed build — the app's"
echo "    identity has changed, so the old ad-hoc grants do not carry over."
