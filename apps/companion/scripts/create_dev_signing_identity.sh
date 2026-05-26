#!/usr/bin/env bash
# Configure a *stable* local code-signing identity so macOS TCC (Full
# Disk Access, Keychain, etc.) persists grants across rebuilds.
#
# Preferred path: if you already have an Apple Development or Developer
# ID Application cert in your login Keychain (via Xcode's automatic
# signing), the script picks that up and writes it into
# Config.local.xcconfig. No self-signed identity needed.
#
# Fallback path: only if no real identity exists, the script generates
# a self-signed "Maraithon Dev" cert as a last resort.
#
# Idempotent: safe to re-run.

set -euo pipefail

IDENTITY_NAME="Maraithon Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v "${KEYCHAIN}" | grep -q "${IDENTITY_NAME}"; then
    echo "Identity \"${IDENTITY_NAME}\" already exists. Done."
    exit 0
fi

WORKDIR="$(mktemp -d)"
trap "rm -rf ${WORKDIR}" EXIT
cd "${WORKDIR}"

cat > openssl.conf <<'CONF'
[req]
distinguished_name = req_distinguished_name
prompt             = no
x509_extensions    = v3_ca

[req_distinguished_name]
CN = Maraithon Dev

[v3_ca]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
CONF

openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout key.pem \
    -out cert.pem \
    -config openssl.conf \
    >/dev/null 2>&1

P12_PASS="maraithon-dev"

# OpenSSL 3 ships with a stricter PKCS12 MAC algorithm that older
# Security.framework releases can't verify; -legacy keeps macOS happy.
openssl pkcs12 -export -legacy \
    -inkey key.pem \
    -in cert.pem \
    -out identity.p12 \
    -password "pass:${P12_PASS}" \
    -name "${IDENTITY_NAME}" \
    >/dev/null 2>&1

security import identity.p12 -k "${KEYCHAIN}" -P "${P12_PASS}" -A -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "" "${KEYCHAIN}" >/dev/null 2>&1 || true

# Wire CODE_SIGN_IDENTITY into the per-developer xcconfig if absent.
CONFIG_PATH="$(cd "$(dirname "$0")/.." && pwd)/Config.local.xcconfig"
if [ ! -f "${CONFIG_PATH}" ]; then
    cp "$(dirname "${CONFIG_PATH}")/Config.local.xcconfig.example" "${CONFIG_PATH}"
fi
if ! grep -q "CODE_SIGN_IDENTITY" "${CONFIG_PATH}"; then
    {
        echo ""
        echo "// Stable dev identity created by scripts/create_dev_signing_identity.sh"
        echo "// Locks TCC (Full Disk Access etc.) and Keychain grants across rebuilds."
        echo "CODE_SIGN_IDENTITY = ${IDENTITY_NAME}"
    } >> "${CONFIG_PATH}"
fi

echo "Identity \"${IDENTITY_NAME}\" installed."
echo "Wired CODE_SIGN_IDENTITY in ${CONFIG_PATH}."
echo "Run xcodegen generate && rebuild to start using it."
