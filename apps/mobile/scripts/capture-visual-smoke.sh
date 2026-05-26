#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${MARAITHON_VERIFY_CONFIG:-${ROOT_DIR}/Config/production-verification.env}"
HELPER_FILE="${ROOT_DIR}/scripts/lib/production-magic-token.sh"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Missing verification config: ${CONFIG_FILE}" >&2
  exit 1
fi

if [[ ! -f "${HELPER_FILE}" ]]; then
  echo "Missing production magic token helper: ${HELPER_FILE}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${HELPER_FILE}"

: "${FLY_APP:?FLY_APP is required in ${CONFIG_FILE}}"
: "${MARAITHON_VERIFY_EMAIL:?MARAITHON_VERIFY_EMAIL is required in ${CONFIG_FILE}}"
: "${SIMULATOR_UDID:?SIMULATOR_UDID is required in ${CONFIG_FILE}}"

APPEARANCE="${1:-${MARAITHON_VISUAL_APPEARANCE:-light}}"
RUN_ID="${MARAITHON_VERIFY_RUN_ID:-$(date -u +%Y%m%d%H%M%S)}"
SNAPSHOT_DIR="${2:-${MARAITHON_VISUAL_SNAPSHOT_DIR:-${ROOT_DIR}/build/verification/liquid-glass-${APPEARANCE}-${RUN_ID}}}"
IOS_DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,id=${SIMULATOR_UDID}}"

if [[ "${SNAPSHOT_DIR}" != /* ]]; then
  SNAPSHOT_DIR="${ROOT_DIR}/${SNAPSHOT_DIR}"
fi

case "${APPEARANCE}" in
  light | dark) ;;
  *)
    echo "Appearance must be 'light' or 'dark', got '${APPEARANCE}'." >&2
    exit 1
    ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_command flyctl
require_command xcodebuild
require_command xcodegen
require_command xcrun

cd "${ROOT_DIR}"

echo "Capturing ${APPEARANCE} visual smoke screenshots for ${MARAITHON_VERIFY_EMAIL}"
xcodegen generate
xcrun simctl boot "${SIMULATOR_UDID}" >/dev/null 2>&1 || true
xcrun simctl bootstatus "${SIMULATOR_UDID}" -b >/dev/null
xcrun simctl ui "${SIMULATOR_UDID}" appearance "${APPEARANCE}"
mkdir -p "${SNAPSHOT_DIR}"

MAGIC_TOKEN="$(generate_maraithon_magic_token "${FLY_APP}" "${MARAITHON_VERIFY_EMAIL}" "mobile-visual-smoke-${RUN_ID}")"

xcodebuild \
  -quiet \
  -project MaraithonMobile.xcodeproj \
  -scheme MaraithonMobile \
  -destination "${IOS_DESTINATION}" \
  -only-testing:MaraithonMobileUITests/VisualSmokeUITests/testCapturePrimaryTabs \
  test \
  MARAITHON_MAGIC_TOKEN="${MAGIC_TOKEN}" \
  MARAITHON_VISUAL_SNAPSHOT_DIR="${SNAPSHOT_DIR}"

echo "Visual smoke screenshots captured in ${SNAPSHOT_DIR}"
