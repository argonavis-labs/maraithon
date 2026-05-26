#!/usr/bin/env bash
# Build a Release archive of MaraithonMobile for App Store distribution.
#
# Outputs:
#   build/archive/MaraithonMobile.xcarchive
#   build/export/MaraithonMobile.ipa
#
# Env overrides:
#   ARCHIVE_PATH, EXPORT_PATH, EXPORT_OPTIONS_PLIST, CONFIGURATION, SCHEME
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

CONFIGURATION="${CONFIGURATION:-Release}"
SCHEME="${SCHEME:-MaraithonMobile}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${ROOT_DIR}/build/archive/MaraithonMobile.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-${ROOT_DIR}/build/export}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-${ROOT_DIR}/Config/ExportOptions.plist}"

mkdir -p "$(dirname "${ARCHIVE_PATH}")" "${EXPORT_PATH}"

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
  -quiet \
  clean archive

echo "==> xcodebuild -exportArchive"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}" \
  -allowProvisioningUpdates \
  -quiet

echo
echo "Archive: ${ARCHIVE_PATH}"
echo "IPA:     ${EXPORT_PATH}/MaraithonMobile.ipa"
