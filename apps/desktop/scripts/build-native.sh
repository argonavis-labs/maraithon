#!/usr/bin/env bash
# Package the existing signed Mac source service without changing its identity.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Native Mac sources are only built on macOS.'
  exit 0
fi
export MARAITHON_COMPANION_CONFIGURATION_BUILD_DIR="${root}/apps/desktop/native"
export MARAITHON_COMPANION_DERIVED_DATA_PATH="${root}/apps/desktop/native/DerivedData"
"${root}/scripts/monorepo/build" companion
