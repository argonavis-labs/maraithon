# Code Signing Setup

Maraithon uses **automatic** code signing with a **per-developer team ID**
supplied via a gitignored `Config.local.xcconfig` file. This keeps team IDs
out of the committed `project.yml` while letting Xcode auto-manage certs.

## Rebuild-stable privacy grants

Full Disk Access and other macOS privacy grants are attached to the app's
code-signing identity. If Debug builds are ad-hoc signed, a rebuild can look
like a new app to TCC and the grant will not persist. For local companion
development, run:

```sh
make run-companion
```

`make run-companion` configures stable signing automatically before each local
run. A `DEVELOPMENT_TEAM` value by itself is not enough for Full Disk Access
persistence because Xcode can still choose a different local certificate. The
launcher uses an existing Apple Development certificate when one is available
because Xcode can register that local debug app for execution. Developer ID
Application certificates are intended for notarized distribution builds, so
local debug runs only fall back to Developer ID when no Apple Development certificate is
available, and then to a local self-signed `Maraithon Dev` identity if needed.
The setup pins the full signing identity in gitignored
`Config.local.xcconfig`, which makes future companion builds keep the same TCC
identity instead of letting Xcode choose a different local certificate.
`make run-companion` also builds the Debug app directly at
`~/Applications/Maraithon.app` before launching it. Building at that stable path
lets Xcode register the app for local execution while keeping Full Disk Access
attached to one app path instead of an Xcode DerivedData bundle. It removes
generated DerivedData `Maraithon.app` copies and Xcode's auxiliary product
files after the build so System Settings does not show multiple
indistinguishable development builds.

The companion Debug target also disables Xcode's debug dylib mode. That keeps
the code that reads protected local stores in the app's main signed executable
instead of a rebuild-specific `Maraithon.debug.dylib`, which makes Full Disk
Access behave like a grant to the stable app rather than a changing debug
artifact.

You can still run `make setup-companion-signing` explicitly to prepare signing
without launching the app.

`make run-companion` records the installed app's designated code-signing
requirement. When that requirement is first recorded, upgraded, or changes, the
launcher clears stale Maraithon Full Disk Access rows once so macOS does not
keep applying an old development-copy grant to the wrong app. It does **not**
reset Full Disk Access during a normal reload after the current requirement has
been recorded, so a valid grant does not disappear just because the app was
rebuilt.

If Full Disk Access still does not apply after switching to the stable app,
reset the stale TCC row explicitly and grant the stable installed app again:

```sh
make reset-companion-fda
```

Then open System Settings -> Privacy & Security -> Full Disk Access and add
or enable the revealed `~/Applications/Maraithon.app` copy. Future
`make run-companion` reloads rebuild that same bundle path and remove stale
DerivedData copies before launching without resetting Full Disk Access.

## Apple Developer setup

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
  local signing values.
- On a fresh clone with no local file, the include is silently skipped:
  Debug still builds (ad-hoc signing, identity `"-"`); only Release
  archives need a real Developer ID.

## Verify

Run `scripts/check_signing.sh` to confirm your local config exists and
parses. The release script calls this before archiving.
