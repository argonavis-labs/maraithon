#!/usr/bin/env bash
# Configure a *stable* local code-signing identity so macOS TCC (Full
# Disk Access, Keychain, etc.) persists grants across rebuilds.
#
# It prefers an existing Developer ID Application identity for local
# debug rebuilds that need durable macOS privacy grants, then falls back
# to Apple Development and finally a self-signed "Maraithon Dev"
# code-signing certificate. We pin the full identity string instead of a
# generic signing selector so Xcode cannot silently choose a different
# certificate between reloads.
#
# Idempotent: safe to re-run.

set -euo pipefail

IDENTITY_NAME="Maraithon Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_PATH="${APP_DIR}/Config.local.xcconfig"
CONFIG_TEMPLATE="${APP_DIR}/Config.local.xcconfig.example"
SELECTED_IDENTITY=""
SELECTED_TEAM=""
SELECTED_CODE_SIGN_IDENTITY=""
SELECTED_CODE_SIGN_STYLE="Manual"

preferred_apple_development_identity() {
    security find-identity -p codesigning -v "${KEYCHAIN}" |
        sed -En 's/.*"(Apple Development: [^"]+)".*/\1/p' |
        head -n 1
}

preferred_developer_id_identity() {
    security find-identity -p codesigning -v "${KEYCHAIN}" |
        sed -En 's/.*"(Developer ID Application: [^"]+)".*/\1/p' |
        head -n 1
}

identity_exists() {
    security find-identity -p codesigning -v "${KEYCHAIN}" | grep -Fq "\"${IDENTITY_NAME}\""
}

ensure_local_config() {
    if [ ! -f "${CONFIG_PATH}" ]; then
        cp "${CONFIG_TEMPLATE}" "${CONFIG_PATH}"
    fi
}

config_has_key() {
    local key="$1"
    [ -f "${CONFIG_PATH}" ] && grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "${CONFIG_PATH}"
}

append_config_line_if_missing() {
    local key="$1"
    local line="$2"

    if ! config_has_key "${key}"; then
        {
            echo ""
            echo "${line}"
        } >> "${CONFIG_PATH}"
    fi
}

set_config_value() {
    local key="$1"
    local value="$2"
    local line="${key} = ${value}"

    if config_has_key "${key}"; then
        local tmp
        tmp="$(mktemp)"
        awk -v key="${key}" -v line="${line}" '
            $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
                if (!done) {
                    print line
                    done = 1
                }
                next
            }
            { print }
        ' "${CONFIG_PATH}" > "${tmp}"
        mv "${tmp}" "${CONFIG_PATH}"
    else
        append_config_line_if_missing "${key}" "${line}"
    fi
}

team_id_from_identity() {
    local identity="$1"

    local subject_ou
    subject_ou="$(
        security find-certificate -c "${identity}" -p "${KEYCHAIN}" 2>/dev/null |
            openssl x509 -noout -subject 2>/dev/null |
            sed -En 's/.*OU[ =]([A-Z0-9]{10}).*/\1/p' |
            head -n 1
    )"

    if [ -n "${subject_ou}" ]; then
        printf '%s\n' "${subject_ou}"
        return
    fi

    printf '%s\n' "${identity}" | sed -En 's/.*\(([A-Z0-9]{10})\)$/\1/p'
}

SELECTED_IDENTITY="$(preferred_developer_id_identity)"

if [ -n "${SELECTED_IDENTITY}" ]; then
    SELECTED_TEAM="$(team_id_from_identity "${SELECTED_IDENTITY}")"
    SELECTED_CODE_SIGN_IDENTITY="${SELECTED_IDENTITY}"
    SELECTED_CODE_SIGN_STYLE="Manual"
    echo "Using existing identity \"${SELECTED_IDENTITY}\"."
elif SELECTED_IDENTITY="$(preferred_apple_development_identity)" && [ -n "${SELECTED_IDENTITY}" ]; then
    SELECTED_TEAM="$(team_id_from_identity "${SELECTED_IDENTITY}")"
    SELECTED_CODE_SIGN_IDENTITY="${SELECTED_IDENTITY}"
    SELECTED_CODE_SIGN_STYLE="Manual"
    echo "Using existing identity \"${SELECTED_IDENTITY}\"."
elif identity_exists; then
    SELECTED_IDENTITY="${IDENTITY_NAME}"
    SELECTED_CODE_SIGN_IDENTITY="${IDENTITY_NAME}"
    SELECTED_CODE_SIGN_STYLE="Manual"
    echo "Identity \"${IDENTITY_NAME}\" already exists."
else

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

    SELECTED_IDENTITY="${IDENTITY_NAME}"
    SELECTED_CODE_SIGN_IDENTITY="${IDENTITY_NAME}"
    SELECTED_CODE_SIGN_STYLE="Manual"
    echo "Identity \"${IDENTITY_NAME}\" installed."
fi

# Wire CODE_SIGN_IDENTITY into the per-developer xcconfig if absent.
ensure_local_config
append_config_line_if_missing \
    CODE_SIGN_STYLE \
    "// Stable local signing keeps macOS privacy grants attached across rebuilds."
set_config_value CODE_SIGN_STYLE "${SELECTED_CODE_SIGN_STYLE}"
if [ -n "${SELECTED_TEAM}" ]; then
    set_config_value DEVELOPMENT_TEAM "${SELECTED_TEAM}"
fi
append_config_line_if_missing \
    CODE_SIGN_IDENTITY \
    "// Identity created by scripts/create_dev_signing_identity.sh."
set_config_value CODE_SIGN_IDENTITY "${SELECTED_CODE_SIGN_IDENTITY}"

echo "Wired CODE_SIGN_IDENTITY in ${CONFIG_PATH}."
echo "Run xcodegen generate && rebuild to start using it."
