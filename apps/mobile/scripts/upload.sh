#!/usr/bin/env bash
# Upload the exported .ipa to App Store Connect (TestFlight).
#
# Auth (choose one):
#   1) App Store Connect API key (recommended)
#        APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_API_ISSUER_ID
#        and ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8
#   2) App-specific password
#        APPLE_ID="kent@..." APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IPA_PATH="${IPA_PATH:-${ROOT_DIR}/build/export/MaraithonMobile.ipa}"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/Config/appstore.env}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

if [[ ! -f "${IPA_PATH}" ]]; then
  echo "Missing IPA at ${IPA_PATH}. Run scripts/archive.sh first." >&2
  exit 1
fi

if [[ -n "${APP_STORE_CONNECT_API_KEY_ID:-}" && -n "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]]; then
  echo "==> Uploading via App Store Connect API key (${APP_STORE_CONNECT_API_KEY_ID})"
  xcrun altool --upload-app \
    --type ios \
    --file "${IPA_PATH}" \
    --apiKey "${APP_STORE_CONNECT_API_KEY_ID}" \
    --apiIssuer "${APP_STORE_CONNECT_API_ISSUER_ID}"
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  echo "==> Uploading via app-specific password (${APPLE_ID})"
  xcrun altool --upload-app \
    --type ios \
    --file "${IPA_PATH}" \
    --username "${APPLE_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}"
else
  cat >&2 <<EOF
No App Store Connect credentials in env. Set either:
  APP_STORE_CONNECT_API_KEY_ID + APP_STORE_CONNECT_API_ISSUER_ID  (API key in ~/.appstoreconnect/private_keys/)
  APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD                          (app-specific password)
EOF
  exit 1
fi
