#!/usr/bin/env bash
# Regenerate the MaraithonMobile AppIcon.appiconset from a single 1024 master.
# Marketing PNG (1024) is flattened to remove alpha (App Store rejects RGBA).
#
# Usage:
#   apps/mobile/scripts/regen-app-icon.sh [path/to/master_1024.png]
#
# Default master: apps/companion/docs/icon/AppIcon.icon.draft/icon_1024.png
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MOBILE_DIR="${ROOT_DIR}/apps/mobile"
SRC="${1:-${ROOT_DIR}/apps/companion/docs/icon/AppIcon.icon.draft/icon_1024.png}"
DEST="${MOBILE_DIR}/MaraithonMobile/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "${SRC}" ]]; then
  echo "Master icon not found: ${SRC}" >&2
  exit 1
fi

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick is required. brew install imagemagick" >&2
  exit 1
fi

echo "Master: ${SRC}"
echo "Dest:   ${DEST}"

# Flattened 1024 marketing icon (no alpha). White background avoids any halo.
magick "${SRC}" -background white -alpha remove -alpha off "${DEST}/AppIcon-1024.png"

# In-app icons keep alpha so they look clean against any home-screen wallpaper.
declare -a sizes=(
  "AppIcon-20.png 20"
  "AppIcon-20@2x.png 40"
  "AppIcon-20@3x.png 60"
  "AppIcon-29.png 29"
  "AppIcon-29@2x.png 58"
  "AppIcon-29@3x.png 87"
  "AppIcon-40.png 40"
  "AppIcon-40@2x.png 80"
  "AppIcon-40@3x.png 120"
  "AppIcon-60@2x.png 120"
  "AppIcon-60@3x.png 180"
  "AppIcon-76@2x.png 152"
  "AppIcon-83.5@2x.png 167"
)

for entry in "${sizes[@]}"; do
  name="${entry% *}"
  size="${entry##* }"
  magick "${SRC}" -resize "${size}x${size}" "${DEST}/${name}"
  echo "  generated ${name} (${size}px)"
done

echo "Done."
