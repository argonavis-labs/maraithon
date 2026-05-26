# Code Signing Setup

Maraithon uses **automatic** code signing with a **per-developer team ID**
supplied via a gitignored `Config.local.xcconfig` file. This keeps team IDs
out of the committed `project.yml` while letting Xcode auto-manage certs.

## One-time setup (about a minute)

1. **Find your Apple Developer team ID.**
   - Open <https://developer.apple.com/account>.
   - Click **Membership** in the left sidebar.
   - Copy the 10-character **Team ID** (e.g. `ABCDE12345`).

2. **Create your local config from the template.**

   ```sh
   cp Config.local.xcconfig.example Config.local.xcconfig
   ```

3. **Set your team ID.** Open `Config.local.xcconfig` and uncomment the
   `DEVELOPMENT_TEAM` line, replacing the placeholder with yours:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   ```

4. **Regenerate the Xcode project and open it.**

   ```sh
   xcodegen generate
   open Maraithon.xcodeproj
   ```

5. **Confirm.** In Xcode, select the **Maraithon** target → **Signing &
   Capabilities**. "Automatically manage signing" should be on and your
   team should be pre-selected. No red error banner.

## How it works

- `project.yml` wires `Config.xcconfig` as the base config for both
  Debug and Release.
- `Config.xcconfig` is a committed shim containing one line:
  `#include? "Config.local.xcconfig"` (optional include).
- `Config.local.xcconfig` is **gitignored** and supplies your
  `DEVELOPMENT_TEAM`.
- On a fresh clone with no local file, the include is silently skipped:
  Debug still builds (ad-hoc signing, identity `"-"`); only Release
  archives need a real Developer ID.

## Verify

Run `scripts/check_signing.sh` to confirm your local config exists and
parses. The release script calls this before archiving.
