#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPANION_DIR="${ROOT_DIR}/apps/companion"
MOBILE_DIR="${ROOT_DIR}/apps/mobile"

require_command() {
  local name="$1"

  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "Missing required command: ${name}" >&2
    exit 1
  fi
}

run_in() {
  local dir="$1"
  shift

  echo
  echo "==> ${dir#$ROOT_DIR/}: $*"
  (cd "${dir}" && "$@")
}

selected_component() {
  local requested="${1:-all}"
  local component="$2"

  [[ "${requested}" == "all" || "${requested}" == "${component}" || "${requested}" == "native" && "${component}" != "web" ]]
}

generate_xcode_project() {
  local dir="$1"

  require_command xcodegen
  run_in "${dir}" xcodegen generate
}

ios_destination() {
  if [[ -n "${IOS_DESTINATION:-}" ]]; then
    echo "${IOS_DESTINATION}"
    return
  fi

  require_command xcrun

  local simulator_regex="${MARAITHON_IOS_SIMULATOR_REGEX:-iPhone 17|iPhone 16|iPhone 15}"
  local simulator_line
  simulator_line="$(
    xcrun simctl list devices available |
      awk -v regex="${simulator_regex}" '
        /^-- iOS / { in_ios = 1; next }
        /^-- / { in_ios = 0 }
        in_ios && $0 ~ regex && $0 ~ /\([0-9A-Fa-f-]{36}\)/ {
          print
          exit
        }
      '
  )"

  local udid
  udid="$(printf "%s" "${simulator_line}" | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)).*/\1/p')"

  if [[ -z "${udid}" ]]; then
    echo "Unable to find an available iOS simulator. Set IOS_DESTINATION='platform=iOS Simulator,id=<UDID>'." >&2
    exit 1
  fi

  echo "platform=iOS Simulator,id=${udid}"
}
