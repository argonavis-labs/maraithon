#!/usr/bin/env bash
#
# setup_notarization.sh — One-shot helper to register notarytool
# credentials in the login keychain.
#
# Apple's `notarytool` reads Apple-ID credentials from a named
# keychain profile. This script collects the three values
# (Apple ID email, team ID, app-specific password) and runs
# `xcrun notarytool store-credentials` so subsequent release runs
# can submit non-interactively.
#
# An *app-specific password* is required — your normal Apple ID
# password will not work. Generate one at:
#
#     https://appleid.apple.com/ -> Sign-In and Security ->
#     App-Specific Passwords -> Generate
#
# Pick a memorable label (e.g. "maraithon-notary"); you can revoke
# it from the same page at any time.
#
# Result: a keychain entry named by $NOTARY_KEYCHAIN_PROFILE
# (defaults to AC_NOTARY) is created under the login keychain.

set -euo pipefail

PROFILE_NAME="${NOTARY_KEYCHAIN_PROFILE:-AC_NOTARY}"

command -v xcrun >/dev/null 2>&1 \
    || { echo "ERROR: xcrun not found. Install Xcode command-line tools." >&2; exit 1; }
xcrun --find notarytool >/dev/null 2>&1 \
    || { echo "ERROR: xcrun notarytool not found. Upgrade to Xcode 13+." >&2; exit 1; }

printf 'Setting up notarytool keychain profile: %s\n' "${PROFILE_NAME}"
printf '\n'
printf 'You will need:\n'
printf '  1. Your Apple ID email\n'
printf '  2. Your 10-character Apple team ID (find at https://developer.apple.com/account)\n'
printf '  3. An app-specific password from https://appleid.apple.com/\n'
printf '\n'

read -r -p "Apple ID email: " APPLE_ID
read -r -p "Team ID (10 chars): " TEAM_ID
read -r -s -p "App-specific password: " APP_PASSWORD
printf '\n'

if [[ -z "${APPLE_ID}" || -z "${TEAM_ID}" || -z "${APP_PASSWORD}" ]]; then
    echo "ERROR: all three values are required." >&2
    exit 1
fi

xcrun notarytool store-credentials "${PROFILE_NAME}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${TEAM_ID}" \
    --password "${APP_PASSWORD}"

printf '\n'
printf 'Stored. Verify with:\n'
printf '    xcrun notarytool history --keychain-profile %s\n' "${PROFILE_NAME}"
printf '\n'
printf 'Export this in your shell rc so release.sh picks it up:\n'
printf '    export NOTARY_KEYCHAIN_PROFILE=%s\n' "${PROFILE_NAME}"
printf '    export DEVELOPMENT_TEAM=%s\n' "${TEAM_ID}"
