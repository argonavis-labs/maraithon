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

`make run-companion` configures stable signing automatically the first time it
sees no pinned `CODE_SIGN_IDENTITY` in the local signing config. A
`DEVELOPMENT_TEAM` value by itself is not enough for Full Disk Access
persistence because Xcode can still choose a different local certificate. The
launcher uses an existing Apple Development certificate when one is available,
falling back to Developer ID or a local self-signed `Maraithon Dev` identity
only when needed. The setup pins the full signing identity in gitignored
`Config.local.xcconfig`, which makes future companion builds keep the same TCC
identity instead of letting Xcode choose a different local certificate.
`make run-companion` also installs the Debug app at
`~/Applications/Maraithon.app` before launching it, preserving that app bundle
directory across reloads so Full Disk Access is granted to one stable app path
instead of an Xcode DerivedData bundle. It removes generated DerivedData
`Maraithon.app` copies after installation so System Settings does not show
multiple indistinguishable development builds.

You can still run `make setup-companion-signing` explicitly to prepare signing
without launching the app.

`make run-companion` records the installed app's designated code-signing
requirement, but it does **not** reset Full Disk Access during a normal reload.
That keeps a valid grant from disappearing just because the app was rebuilt.

If Full Disk Access still does not apply after switching to the stable app,
reset the stale TCC row explicitly and grant the stable installed app again:

```sh
make reset-companion-fda
```

Then open System Settings -> Privacy & Security -> Full Disk Access and add
or enable the revealed `~/Applications/Maraithon.app` copy. Future
`make run-companion` reloads preserve that bundle path and remove stale
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
