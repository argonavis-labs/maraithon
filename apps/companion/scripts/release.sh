#!/usr/bin/env bash
#
# release.sh — End-to-end release pipeline for Maraithon.app
#
# Builds a Developer-ID-signed, notarized, stapled .dmg ready for
# upload to the Maraithon appcast. Idempotent: re-running blows
# away build/ and starts clean. Fails fast on any non-zero exit.
#
# Required env vars:
#   DEVELOPMENT_TEAM           Apple team ID (10-char), e.g. ABCDE12345.
#   NOTARY_KEYCHAIN_PROFILE    Name passed to `notarytool --keychain-profile`.
#                              Set up once via scripts/setup_notarization.sh.
#   DEVELOPER_ID               Full codesign identity for the DMG, e.g.
#                              "Developer ID Application: Jane Doe (ABCDE12345)".
#
# Optional env vars:
#   SCHEME                     Xcode scheme name. Defaults to "Maraithon".
#   PROJECT                    Xcode project path. Defaults to "Maraithon.xcodeproj".
#   CONFIGURATION              Build config. Defaults to "Release".
#
# Outputs:
#   build/Maraithon-<version>.dmg   Final stapled artifact. Path printed on success.

set -euo pipefail

# --- Repo root -------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# --- Config ----------------------------------------------------------------

SCHEME="${SCHEME:-Maraithon}"
PROJECT="${PROJECT:-Maraithon.xcodeproj}"
CONFIGURATION="${CONFIGURATION:-Release}"

BUILD_DIR="${REPO_ROOT}/build"
ARCHIVE_PATH="${BUILD_DIR}/Maraithon.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
APP_PATH="${EXPORT_PATH}/Maraithon.app"
APP_ZIP="${BUILD_DIR}/Maraithon.zip"
EXPORT_OPTIONS_TEMPLATE="${SCRIPT_DIR}/ExportOptions.plist"
EXPORT_OPTIONS_RENDERED="${BUILD_DIR}/ExportOptions.plist"
DMG_SETTINGS="${SCRIPT_DIR}/dmg_settings.py"

# --- Helpers ---------------------------------------------------------------

log() {
    printf '[release] %s\n' "$*"
}

die() {
    printf '[release] ERROR: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1. ${2:-}"
}

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        die "required env var \$${name} is not set. See docs/RELEASE.md."
    fi
}

# --- Step 1: preflight -----------------------------------------------------

log "step 1/13 — preflight"

require_cmd xcodebuild "Install Xcode from the App Store."
require_cmd xcrun "Install Xcode command-line tools: xcode-select --install"
require_cmd ditto "ditto ships with macOS."
require_cmd dmgbuild "brew install dmgbuild"
require_cmd codesign "Provided by Xcode command-line tools."
require_cmd defaults "defaults ships with macOS."
require_cmd plutil "plutil ships with macOS."

xcrun --find notarytool >/dev/null 2>&1 \
    || die "xcrun notarytool not found. Upgrade to Xcode 13+."
xcrun --find stapler >/dev/null 2>&1 \
    || die "xcrun stapler not found. Upgrade to Xcode 13+."

require_env DEVELOPMENT_TEAM
require_env NOTARY_KEYCHAIN_PROFILE
require_env DEVELOPER_ID

[[ -f "${PROJECT}/project.pbxproj" ]] \
    || die "${PROJECT} not found. Run 'xcodegen generate' first."
[[ -f "${EXPORT_OPTIONS_TEMPLATE}" ]] \
    || die "missing ${EXPORT_OPTIONS_TEMPLATE}."
[[ -f "${DMG_SETTINGS}" ]] \
    || die "missing ${DMG_SETTINGS}."

# Per-developer signing config (Config.local.xcconfig) must exist and
# carry a DEVELOPMENT_TEAM; otherwise xcodebuild can't auto-sign.
# Skip if the helper isn't present yet (older checkouts).
if [[ -x "${SCRIPT_DIR}/check_signing.sh" ]]; then
    "${SCRIPT_DIR}/check_signing.sh"
fi

# Clean slate every run — release builds must be reproducible.
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Render ExportOptions.plist with the real team ID. We keep the template
# checked in with a __DEVELOPMENT_TEAM__ placeholder so the repo doesn't
# leak Apple account info.
sed "s/__DEVELOPMENT_TEAM__/${DEVELOPMENT_TEAM}/g" \
    "${EXPORT_OPTIONS_TEMPLATE}" > "${EXPORT_OPTIONS_RENDERED}"
plutil -lint "${EXPORT_OPTIONS_RENDERED}" >/dev/null \
    || die "rendered ExportOptions.plist is invalid."

# --- Step 2: archive -------------------------------------------------------

log "step 2/13 — xcodebuild archive"
xcodebuild archive \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -archivePath "${ARCHIVE_PATH}" \
    -destination 'generic/platform=macOS' \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
    | tee "${BUILD_DIR}/archive.log"

[[ -d "${ARCHIVE_PATH}" ]] \
    || die "archive did not produce ${ARCHIVE_PATH}."

# --- Read the marketing version off the archive ----------------------------

# Use the archived Info.plist as the source of truth so the script can't
# drift from project.yml. `defaults read` requires an absolute path
# *without* the .plist extension.
ARCHIVED_INFO_PLIST="${ARCHIVE_PATH}/Products/Applications/Maraithon.app/Contents/Info"
[[ -f "${ARCHIVED_INFO_PLIST}.plist" ]] \
    || die "archived Info.plist missing at ${ARCHIVED_INFO_PLIST}.plist."
VERSION="$(defaults read "${ARCHIVED_INFO_PLIST}" CFBundleShortVersionString)"
[[ -n "${VERSION}" ]] || die "CFBundleShortVersionString empty in archived Info.plist."
log "marketing version: ${VERSION}"

DMG_PATH="${BUILD_DIR}/Maraithon-${VERSION}.dmg"

# --- Step 3: exportArchive -------------------------------------------------

log "step 3/13 — xcodebuild -exportArchive"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportOptionsPlist "${EXPORT_OPTIONS_RENDERED}" \
    -exportPath "${EXPORT_PATH}" \
    | tee "${BUILD_DIR}/export.log"

[[ -d "${APP_PATH}" ]] \
    || die "export did not produce ${APP_PATH}."

# --- Step 4: zip for notarization -----------------------------------------

log "step 4/13 — ditto .app -> .zip"
ditto -c -k --keepParent "${APP_PATH}" "${APP_ZIP}"

# --- Step 5: notarize the app zip -----------------------------------------

log "step 5/13 — notarytool submit (app)"
xcrun notarytool submit "${APP_ZIP}" \
    --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
    --wait \
    | tee "${BUILD_DIR}/notarize-app.log"

# `--wait` exits non-zero on rejection, so reaching here means accepted.

# --- Step 6: staple the app -----------------------------------------------

log "step 6/13 — stapler staple (app)"
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

# --- Step 7: build the DMG ------------------------------------------------

log "step 7/13 — dmgbuild"
# dmgbuild refuses to overwrite; we already wiped build/ so this is safe.
dmgbuild -s "${DMG_SETTINGS}" "Maraithon ${VERSION}" "${DMG_PATH}"
[[ -f "${DMG_PATH}" ]] || die "dmgbuild did not produce ${DMG_PATH}."

# --- Step 8: sign the DMG -------------------------------------------------

log "step 8/13 — codesign DMG"
codesign --sign "${DEVELOPER_ID}" \
    --options runtime \
    --timestamp \
    "${DMG_PATH}"

# --- Step 9: notarize the DMG ---------------------------------------------

log "step 9/13 — notarytool submit (dmg)"
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
    --wait \
    | tee "${BUILD_DIR}/notarize-dmg.log"

# --- Step 10: staple the DMG ----------------------------------------------

log "step 10/13 — stapler staple (dmg)"
xcrun stapler staple "${DMG_PATH}"

# --- Step 11: validate ----------------------------------------------------

log "step 11/13 — stapler validate (dmg)"
xcrun stapler validate "${DMG_PATH}"

# --- Step 12: Sparkle EdDSA sign_update -----------------------------------
#
# Sparkle verifies every update against the SUPublicEDKey baked into
# the shipped app. The matching private key lives in the release
# operator's login Keychain (see ../maraithon/docs/companion/SPARKLE_KEYS.md).
# `sign_update` reads the private key from the Keychain, signs the
# DMG bytes, and prints the EdDSA signature on stdout — which the
# server-side `mix companion.release` task picks up.

log "step 12/13 — Sparkle sign_update"

find_sign_update() {
    local candidates=(
        "${REPO_ROOT}/.build/checkouts/Sparkle/bin/sign_update"
        "${REPO_ROOT}/.build/artifacts/sparkle/Sparkle/bin/sign_update"
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
        -type f -name sign_update -path '*Sparkle*' 2>/dev/null \
        | head -n 1)"

    if [[ -n "${derived}" && -x "${derived}" ]]; then
        printf '%s\n' "${derived}"
        return 0
    fi

    return 1
}

SIGN_UPDATE="$(find_sign_update || true)"
[[ -n "${SIGN_UPDATE}" ]] \
    || die "could not find Sparkle's sign_update. Run scripts/sparkle_keys.sh first."

# `sign_update` prints a line shaped like:
#   sparkle:edSignature="…" length="…"
# We capture both the signature and the length for release-info.json.
SIGN_UPDATE_OUTPUT="$("${SIGN_UPDATE}" "${DMG_PATH}")"
log "${SIGN_UPDATE_OUTPUT}"

# Parse `sparkle:edSignature="…"` out of the output.
SIGNATURE="$(printf '%s' "${SIGN_UPDATE_OUTPUT}" \
    | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"

[[ -n "${SIGNATURE}" && "${SIGNATURE}" != "${SIGN_UPDATE_OUTPUT}" ]] \
    || die "could not parse signature out of sign_update output: ${SIGN_UPDATE_OUTPUT}"

# --- Step 13: release-info.json ------------------------------------------
#
# A small JSON manifest the server side reads to publish the new
# release into the appcast. Lives next to the DMG in build/.

log "step 13/13 — release-info.json"

# Marketing version is already read; build number from the same plist.
BUILD_NUMBER="$(defaults read "${ARCHIVED_INFO_PLIST}" CFBundleVersion)"
[[ -n "${BUILD_NUMBER}" ]] || die "CFBundleVersion empty in archived Info.plist."

# File size in bytes (for the optional `length` enclosure attribute).
FILE_SIZE="$(stat -f '%z' "${DMG_PATH}")"

# SHA-256 of the DMG (informational; Sparkle uses the EdDSA signature,
# not a checksum, but a sha256 is handy for off-band verification).
SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"

RELEASE_INFO_PATH="${BUILD_DIR}/release-info.json"

cat > "${RELEASE_INFO_PATH}" <<JSON
{
  "version": "${VERSION}",
  "build": "${BUILD_NUMBER}",
  "dmg_path": "${DMG_PATH}",
  "signature": "${SIGNATURE}",
  "file_size": ${FILE_SIZE},
  "sha256": "${SHA256}"
}
JSON

plutil -lint "${RELEASE_INFO_PATH}" >/dev/null \
    || die "rendered release-info.json is invalid."

log "release complete"
printf '\n%s\n' "${DMG_PATH}"
printf '%s\n' "${RELEASE_INFO_PATH}"
