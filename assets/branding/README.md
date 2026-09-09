# Local Chrome mark

The Chrome provider icon carries Runner's mark in the lower-right corner. Web, Electron, native companion, and mobile use the same composition.

`runner-mark.svg` is copied without changes from `~/bliss/runner/apps/electron/src/renderer/assets/onboarding_intro/tool_call_svgs/runner.svg`, commit `60e866e4d211350754c1fcbaa91f3249cc3ae45d`. SHA-256: `05110fa8bd073f85d4fcc2af55b849f5ef51296eccba7c9002f7ecc882a9b024`.

The base Chrome image is Maraithon's existing `priv/static/images/connector-logos/chrome.png`. SHA-256: `e49a14ff78e500c4b0227ebd6e74e835bc03145ed0f90d2c2c48b75491230fe4`.

Run `node assets/scripts/build-chrome-mark.mjs` from the repository root to rebuild the SVG and native PNGs. This uses `rsvg-convert` from librsvg. Generated assets are committed, so ordinary app builds do not need librsvg.

The Google Chrome app bundle and its Dock icon are not modified.
