#!/usr/bin/env bash
#
# check_signing.sh — verify per-developer signing config is in place.
#
# Exits 0 when Config.local.xcconfig exists and contains a non-commented
# DEVELOPMENT_TEAM assignment that parses to a non-empty value.
# Exits non-zero otherwise, printing an actionable message pointing at
# docs/SIGNING.md.
#
# Called by scripts/release.sh before archiving so we fail fast instead
# of producing an unsigned / mis-signed Release build.

set -euo pipefail

# Resolve repo root from this script's location (scripts/ lives at root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOCAL_CONFIG="${REPO_ROOT}/Config.local.xcconfig"

if [[ ! -f "${LOCAL_CONFIG}" ]]; then
  cat >&2 <<EOF
error: ${LOCAL_CONFIG} not found.

This file supplies your per-developer DEVELOPMENT_TEAM. To create it:

  cp Config.local.xcconfig.example Config.local.xcconfig
  # then edit and set DEVELOPMENT_TEAM = <your Apple team id>

See docs/SIGNING.md for full instructions.
EOF
  exit 1
fi

# Pull DEVELOPMENT_TEAM out of the local config, ignoring commented lines.
# xcconfig comments use // (single-line). We strip those and look for
# the first uncommented DEVELOPMENT_TEAM = <value> assignment.
team="$(
  sed -E 's|//.*$||' "${LOCAL_CONFIG}" \
    | grep -E '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=' \
    | head -n 1 \
    | sed -E 's|^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*||' \
    | sed -E 's|[[:space:]]+$||' \
  || true
)"

if [[ -z "${team}" ]]; then
  cat >&2 <<EOF
error: ${LOCAL_CONFIG} exists but does not set DEVELOPMENT_TEAM.

Open the file and uncomment / set:

  DEVELOPMENT_TEAM = ABCDE12345   # your 10-char Apple team id

See docs/SIGNING.md.
EOF
  exit 1
fi

echo "check_signing: DEVELOPMENT_TEAM = ${team}"
exit 0
