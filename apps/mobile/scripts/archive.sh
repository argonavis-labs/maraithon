#!/usr/bin/env bash
# Build a Release archive of MaraithonMobile for App Store distribution.
#
# Outputs:
#   build/archive/MaraithonMobile.xcarchive
#   build/export/MaraithonMobile.ipa
#
# Env overrides:
#   ARCHIVE_PATH, EXPORT_PATH, EXPORT_OPTIONS_PLIST, CONFIGURATION, SCHEME
#   APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_API_ISSUER_ID,
#   APP_STORE_CONNECT_API_KEY_PATH
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

CONFIGURATION="${CONFIGURATION:-Release}"
SCHEME="${SCHEME:-MaraithonMobile}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${ROOT_DIR}/build/archive/MaraithonMobile.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-${ROOT_DIR}/build/export}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-${ROOT_DIR}/Config/ExportOptions.plist}"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/Config/appstore.env}"

mkdir -p "$(dirname "${ARCHIVE_PATH}")" "${EXPORT_PATH}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

XCODEBUILD_AUTH_ARGS=()
if [[ -n "${APP_STORE_CONNECT_API_KEY_ID:-}" && -n "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]]; then
  API_KEY_PATH="${APP_STORE_CONNECT_API_KEY_PATH:-${HOME}/.appstoreconnect/private_keys/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8}"
  if [[ -f "${API_KEY_PATH}" ]]; then
    XCODEBUILD_AUTH_ARGS=(
      -authenticationKeyPath "${API_KEY_PATH}"
      -authenticationKeyID "${APP_STORE_CONNECT_API_KEY_ID}"
      -authenticationKeyIssuerID "${APP_STORE_CONNECT_API_ISSUER_ID}"
    )
  else
    echo "Missing App Store Connect API key at ${API_KEY_PATH}" >&2
    exit 1
  fi
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. brew install xcodegen" >&2
  exit 1
fi

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild archive (${CONFIGURATION})"
xcodebuild \
  -project MaraithonMobile.xcodeproj \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "generic/platform=iOS" \
  -archivePath "${ARCHIVE_PATH}" \
  -allowProvisioningUpdates \
  "${XCODEBUILD_AUTH_ARGS[@]}" \
  -quiet \
  clean archive

echo "==> xcodebuild -exportArchive"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}" \
  -allowProvisioningUpdates \
  "${XCODEBUILD_AUTH_ARGS[@]}" \
  -quiet

echo
echo "Archive: ${ARCHIVE_PATH}"
echo "IPA:     ${EXPORT_PATH}/MaraithonMobile.ipa"
