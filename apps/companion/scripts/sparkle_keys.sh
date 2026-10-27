#!/usr/bin/env bash
#
# sparkle_keys.sh — One-shot helper to generate the Sparkle EdDSA
# key pair used to sign Maraithon companion app updates.
#
# Sparkle's `generate_keys` binary creates an Ed25519 key pair,
# stores the private key in the login Keychain under the service
# `https://sparkle-project.org`, and prints the matching public key
# to stdout. The public key is a 44-character base64 string that
# must be pasted into Config.local.xcconfig as `SUPublicEDKey` so
# xcodegen embeds it in the shipped app's Info.plist.
#
# Idempotent: if the private key already exists in the Keychain,
# `generate_keys` skips regeneration and just prints the matching
# public key. Run this script as many times as you like — it will
# never overwrite an existing key without explicit confirmation
# via Sparkle's own UI.
#
# Output: prints the public key (and a copy-pasteable
# Config.local.xcconfig line) to stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

log() {
    printf '[sparkle_keys] %s\n' "$*"
}

die() {
    printf '[sparkle_keys] ERROR: %s\n' "$*" >&2
    exit 1
}

# --- Locate Sparkle's generate_keys binary --------------------------------
#
# SwiftPM places Sparkle inside DerivedData. The exact path depends
# on the build configuration name, but the binary is always called
# `generate_keys` and lives at:
#   .build/checkouts/Sparkle/bin/generate_keys
# (when fetched by `xcodebuild -resolvePackageDependencies`)
# or:
#   ~/Library/Developer/Xcode/DerivedData/Maraithon-*/SourcePackages/
#     artifacts/sparkle/Sparkle/bin/generate_keys
# (when fetched by an actual Xcode build).
#
# We look in both locations.

find_generate_keys() {
    local candidates=(
        "${REPO_ROOT}/.build/checkouts/Sparkle/bin/generate_keys"
        "${REPO_ROOT}/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    # Fall back to DerivedData (Xcode SPM cache).
    local derived
    derived="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
        -type f -name generate_keys -path '*Sparkle*' 2>/dev/null \
        | head -n 1)"

    if [[ -n "${derived}" && -x "${derived}" ]]; then
        printf '%s\n' "${derived}"
        return 0
    fi

    return 1
}

GENERATE_KEYS="$(find_generate_keys || true)"

if [[ -z "${GENERATE_KEYS}" ]]; then
    log "could not find Sparkle's generate_keys binary."
    log "fetching SwiftPM packages..."
    xcodebuild -resolvePackageDependencies -project Maraithon.xcodeproj >/dev/null \
        || die "xcodebuild -resolvePackageDependencies failed. Run 'xcodegen generate' first."

    GENERATE_KEYS="$(find_generate_keys || true)"
fi

[[ -n "${GENERATE_KEYS}" && -x "${GENERATE_KEYS}" ]] \
    || die "still could not find generate_keys. Open Xcode once to force SPM resolution."

log "using ${GENERATE_KEYS}"

# --- Run generate_keys ----------------------------------------------------
#
# `generate_keys` prints a friendly banner to stdout that includes
# the public key on a line of its own. We capture the whole thing
# so we can echo it back and also extract the key for the
# convenience message at the bottom.

set +e
OUTPUT="$("${GENERATE_KEYS}" 2>&1)"
STATUS=$?
set -e

printf '%s\n' "${OUTPUT}"

if [[ ${STATUS} -ne 0 ]]; then
    die "generate_keys exited with status ${STATUS}. See output above."
fi

# Sparkle prints the public key as a 44-character base64 string on
# its own line. Match the last such line in the output.
PUBLIC_KEY="$(printf '%s\n' "${OUTPUT}" \
    | grep -Eo '[A-Za-z0-9+/]{43}=' \
    | tail -n 1)"

printf '\n'
log "public key: ${PUBLIC_KEY:-<could not parse — copy it from the output above>}"

if [[ -n "${PUBLIC_KEY}" ]]; then
    printf '\n'
    log "paste the following line into Config.local.xcconfig (gitignored):"
    printf '\n'
    printf '    SUPublicEDKey = %s\n' "${PUBLIC_KEY}"
    printf '\n'
    log "then re-run 'xcodegen generate' so the value flows into Info.plist."
fi
