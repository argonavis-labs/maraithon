#!/usr/bin/env bash
# Deterministically build and upload the latest iOS app to TestFlight.
#
# Usage:
#   make testflight-mobile
#
# Env overrides:
#   MARAITHON_MOBILE_BUILD_NUMBER=202605271439  # optional exact build number
#   SKIP_BUILD_BUMP=1                           # archive/upload current build
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="${ROOT_DIR}/project.yml"
IPA_PATH="${ROOT_DIR}/build/export/MaraithonMobile.ipa"
UPLOAD_LOG_DIR="${ROOT_DIR}/build/testflight"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

current_build_number() {
  awk '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' "${PROJECT_YML}"
}

next_build_number() {
  local current candidate
  current="$(current_build_number)"
  # 14-digit (with seconds): App Store Connect sorts builds numerically, and
  # historical uploads used this format — a shorter timestamp would sort as
  # an OLDER build and never reach testers.
  candidate="${MARAITHON_MOBILE_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"

  if [[ ! "${candidate}" =~ ^[0-9]+$ ]]; then
    echo "Build number must be numeric: ${candidate}" >&2
    exit 1
  fi

  if [[ "${current}" =~ ^[0-9]+$ ]] && (( candidate <= current )); then
    candidate="$((current + 1))"
  fi

  printf '%s\n' "${candidate}"
}

set_build_number() {
  local build_number="$1"
  perl -0pi -e "s/CURRENT_PROJECT_VERSION: \\d+/CURRENT_PROJECT_VERSION: ${build_number}/" "${PROJECT_YML}"
}

ipa_value() {
  local plist_key="$1"
  local tmpdir value
  tmpdir="$(mktemp -d)"
  unzip -q "${IPA_PATH}" -d "${tmpdir}"
  value="$(/usr/libexec/PlistBuddy -c "Print :${plist_key}" "${tmpdir}/Payload/MaraithonMobile.app/Info.plist")"
  rm -rf "${tmpdir}"
  printf '%s\n' "${value}"
}

require_command awk
require_command date
require_command perl
require_command unzip
require_command xcodebuild
require_command xcodegen
require_command xcrun

cd "${ROOT_DIR}"

if [[ "${SKIP_BUILD_BUMP:-0}" == "1" ]]; then
  BUILD_NUMBER="$(current_build_number)"
  echo "==> Using existing mobile build ${BUILD_NUMBER}"
else
  BUILD_NUMBER="$(next_build_number)"
  echo "==> Setting mobile build number to ${BUILD_NUMBER}"
  set_build_number "${BUILD_NUMBER}"
fi

"${ROOT_DIR}/scripts/archive.sh"

IPA_VERSION="$(ipa_value CFBundleShortVersionString)"
IPA_BUILD="$(ipa_value CFBundleVersion)"

if [[ "${IPA_BUILD}" != "${BUILD_NUMBER}" ]]; then
  echo "IPA build mismatch: expected ${BUILD_NUMBER}, got ${IPA_BUILD}" >&2
  exit 1
fi

mkdir -p "${UPLOAD_LOG_DIR}"
UPLOAD_LOG="${UPLOAD_LOG_DIR}/upload-${BUILD_NUMBER}.log"

echo "==> Uploading MaraithonMobile ${IPA_VERSION} (${IPA_BUILD}) to TestFlight"
"${ROOT_DIR}/scripts/upload.sh" 2>&1 | tee "${UPLOAD_LOG}"

DELIVERY_UUID="$(awk '/Delivery UUID:/ {print $3; exit}' "${UPLOAD_LOG}")"

echo
echo "TestFlight upload accepted"
echo "Version:       ${IPA_VERSION}"
echo "Build:         ${IPA_BUILD}"
if [[ -n "${DELIVERY_UUID}" ]]; then
  echo "Delivery UUID: ${DELIVERY_UUID}"
fi
echo "IPA:           ${IPA_PATH}"
echo "Upload log:    ${UPLOAD_LOG}"
