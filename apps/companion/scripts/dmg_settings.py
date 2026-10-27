# dmgbuild settings for Maraithon.
#
# Invoked by `scripts/release.sh` as:
#
#     dmgbuild -s scripts/dmg_settings.py "Maraithon <version>" build/Maraithon-<version>.dmg
#
# dmgbuild executes this file as a Python module and reads its
# top-level variables. See https://dmgbuild.readthedocs.io/ for the
# full list of recognized keys.
#
# We deliberately keep this minimal: a white 540x380 window with the
# Maraithon.app icon next to an Applications-folder symlink. No
# background image, no fancy chrome — the look mirrors the rest of
# the app (clean, content-first).

import os.path

# Resolve the exported .app relative to the script location so the
# settings file works whether dmgbuild is run from the repo root or
# from inside `scripts/`.
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(_SCRIPT_DIR)
_APP_PATH = os.path.join(_REPO_ROOT, "build", "export", "Maraithon.app")

# --- Volume ----------------------------------------------------------------

# Filesystem layout: ship the signed .app and a symlink to /Applications
# so the user can drag-install.
files = [_APP_PATH]
symlinks = {"Applications": "/Applications"}

# Volume format & size: UDZO is the standard compressed read-only image.
# `size` left unset → dmgbuild auto-sizes from contents.
format = "UDZO"

# --- Window appearance -----------------------------------------------------

# 540x380 is the canonical "two icons side-by-side" DMG window.
window_rect = ((200, 200), (540, 380))
icon_size = 96
text_size = 13

# Icon coordinates within the window. Left/right thirds, vertically
# centered. Drag from Maraithon.app -> Applications is implied by
# position; no decorative arrow background.
icon_locations = {
    "Maraithon.app": (140, 180),
    "Applications": (400, 180),
}

# Default view: icon (not list/column) so the drag-install metaphor reads.
default_view = "icon-view"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# Background: leave unset → plain white. The Finder will use the
# default volume background, which matches our minimal design ethos.
background = "builtin-arrow"

# Volume icon: fall back to the .app's icon if a .icns isn't supplied
# explicitly. (No volume icon path → dmgbuild uses the system default,
# which is fine.)
