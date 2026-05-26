# Maraithon — Release Runbook

End-to-end instructions for cutting a signed, notarized, stapled
`.dmg` of the Maraithon companion app. Follow this guide top to
bottom the first time; subsequent releases are a one-liner.

## Overview

`scripts/release.sh` automates every step:

1. Archive with `xcodebuild`.
2. Export a Developer-ID-signed `.app`.
3. Notarize the `.app` (zipped) and staple the ticket.
4. Build a `.dmg` with `dmgbuild`.
5. Sign, notarize, and staple the `.dmg`.
6. Validate the final artifact.
7. Sign the DMG with Sparkle's `sign_update` (EdDSA).
8. Emit `build/release-info.json` for the server-side publish step.

The output is `build/Maraithon-<version>.dmg`. Version is read
from the archive's `CFBundleShortVersionString` (set in
`project.yml` via `MARKETING_VERSION`) — you do not pass it on the
command line.

## One-time setup

### 1. Install Xcode and command-line tools

- Xcode 15 or newer from the Mac App Store. Launch once and accept
  the license.
- Run `xcode-select --install` if `xcrun` is missing.
- Confirm: `xcrun notarytool --help` and `xcrun stapler --help`
  print usage without error.

### 2. Install Homebrew tooling

```sh
brew install xcodegen dmgbuild
```

- `xcodegen` regenerates `Maraithon.xcodeproj` from `project.yml`.
- `dmgbuild` produces the disk image. (Optional: `brew install
  shellcheck` if you want to lint the release scripts.)

### 3. Install your Developer ID certificate

Apple Developer Program membership is required.

1. Sign in at <https://developer.apple.com/account>.
2. Certificates, Identifiers & Profiles -> Certificates -> `+`.
3. Pick **Developer ID Application**, follow the CSR flow, download
   the resulting `.cer`.
4. Double-click the `.cer` to import it into the login keychain.
5. Confirm with `security find-identity -v -p codesigning`. You
   should see a line like:

   ```
   1) ABCDEF0123456789…  "Developer ID Application: Jane Doe (ABCDE12345)"
   ```

   Note both the full string (you'll set it as `$DEVELOPER_ID`)
   and the 10-character team ID in parentheses
   (`$DEVELOPMENT_TEAM`).

### 4. Generate an app-specific password

Apple Notary Service requires an app-specific password (your
regular Apple ID password is rejected).

1. Visit <https://appleid.apple.com/>.
2. Sign-In and Security -> App-Specific Passwords -> Generate.
3. Label it something memorable, e.g. `maraithon-notary`.
4. Copy the generated password (`xxxx-xxxx-xxxx-xxxx`). You
   cannot view it again — revoke and regenerate if you lose it.

### 5. Register notarytool credentials

Run the helper:

```sh
./scripts/setup_notarization.sh
```

It prompts for your Apple ID, team ID, and app-specific password,
then calls `xcrun notarytool store-credentials AC_NOTARY …`. The
credentials live in your login keychain under that profile name —
the release script references them via
`$NOTARY_KEYCHAIN_PROFILE`.

Verify the profile works:

```sh
xcrun notarytool history --keychain-profile AC_NOTARY
```

### 6. Create `Config.local.xcconfig`

The Xcode project reads your team ID from a gitignored xcconfig so
auto-signing works without committing Apple account info. See
[`SIGNING.md`](SIGNING.md) for the full walkthrough; the short
version:

```sh
cp Config.local.xcconfig.example Config.local.xcconfig
# edit the file, set DEVELOPMENT_TEAM = <your 10-char team id>
```

`scripts/release.sh` invokes `scripts/check_signing.sh` before
archiving and refuses to continue if this file is missing or
empty.

### 7. Generate the Sparkle EdDSA key pair (one-time, ever)

Sparkle signs every update with an Ed25519 key pair. The **private**
key lives in your login Keychain (and a backup in 1Password). The
**public** key is bundled into the shipped app via `SUPublicEDKey`
in `Info.plist` and is what every installed copy uses to verify
incoming updates.

```sh
./scripts/sparkle_keys.sh
```

Output looks like:

```
[sparkle_keys] public key: dGVzdHRlc3R0ZXN0dGVzdHRlc3R0ZXN0dGVzdHRl
[sparkle_keys] paste the following line into Config.local.xcconfig:

    SUPublicEDKey = dGVzdHRlc3R0ZXN0dGVzdHRlc3R0ZXN0dGVzdHRl
```

1. Copy the `SUPublicEDKey = …` line into
   `Config.local.xcconfig` (gitignored, per-developer).
2. Re-run `xcodegen generate` so the value flows into Info.plist.
3. Back up the private key by opening **Keychain Access**, searching
   for `sparkle-project.org`, copying the password, and pasting it
   into the shared 1Password vault as *Maraithon Sparkle EdDSA
   private key*.

The script is idempotent — re-running just prints the existing
public key without regenerating.

### 8. Set environment variables

Add to `~/.zshrc` (or your shell's rc file):

```sh
export DEVELOPMENT_TEAM="ABCDE12345"
export NOTARY_KEYCHAIN_PROFILE="AC_NOTARY"
export DEVELOPER_ID="Developer ID Application: Jane Doe (ABCDE12345)"
```

Reload (`exec $SHELL -l`) and confirm all three print:

```sh
echo "$DEVELOPMENT_TEAM $NOTARY_KEYCHAIN_PROFILE $DEVELOPER_ID"
```

## Cutting a release

```sh
cd /path/to/maraithon-mac
xcodegen generate            # regenerate Maraithon.xcodeproj
./scripts/release.sh
```

On success, the final line of output is the path to the stapled
DMG:

```
build/Maraithon-0.1.0.dmg
```

Upload this artifact to the Maraithon server and bump the Sparkle
appcast (`https://maraithon.fly.dev/companion/appcast.xml`).

### Bumping the version

Edit `MARKETING_VERSION` in `project.yml`, re-run `xcodegen
generate`, then `./scripts/release.sh`. The script reads the
version off the freshly built archive, so there is no risk of the
artifact filename disagreeing with what's inside.

## Publishing a release

Once `scripts/release.sh` finishes, you have two artifacts in
`build/`:

- `Maraithon-<version>.dmg` — the signed, notarized, stapled DMG.
- `release-info.json` — version, build number, signature, file
  size, and SHA-256, captured for the server-side publish step.

The Phoenix server reads `release-info.json` and inserts a row
into the `companion_releases` table; from then on,
`/companion/appcast.xml` serves the new release to every installed
copy of the Mac app.

### 1. Upload the DMG

Today the DMG is hosted on the Phoenix server's Fly volume, mounted
at `/data/releases` and served at
`https://maraithon.com/releases/Maraithon-<version>.dmg`. SCP it
across:

```sh
fly ssh sftp shell -a maraithon
put build/Maraithon-0.1.1.dmg /data/releases/Maraithon-0.1.1.dmg
exit
```

(If we move to S3 or a CDN in the future, swap this step for an
`aws s3 cp` — the rest of the flow is the same. The URL just
changes.)

### 2. Publish the row

On the server (or via `fly ssh console -a maraithon`):

```sh
mix companion.release \
    --version 0.1.1 \
    --build 2 \
    --url https://maraithon.com/releases/Maraithon-0.1.1.dmg \
    --signature "$(jq -r .signature build/release-info.json)" \
    --notes 'release notes here'
```

…or, if you've copied `release-info.json` to the server:

```sh
mix companion.release \
    --url https://maraithon.com/releases/Maraithon-0.1.1.dmg \
    --notes 'release notes here' \
    --from-release-info build/release-info.json
```

The new release appears in `/companion/appcast.xml` immediately
(with a 5-minute cache header).

## Troubleshooting

### Notarization fails

The script prints the submission ID on the failing
`xcrun notarytool submit` call. Inspect the full log:

```sh
xcrun notarytool log <submission-id> \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE"
```

Common causes:

- **Hardened Runtime missing.** Confirm `ENABLE_HARDENED_RUNTIME =
  YES` in `project.yml`. Inspect the built app with
  `codesign -d -vv --entitlements - build/export/Maraithon.app`.
- **Unsigned nested binary.** Sparkle's XPC services occasionally
  show up un-signed if you exported the archive with `signingStyle
  = manual`. Stick with `automatic` (the default in
  `ExportOptions.plist`).
- **Wrong team ID.** `$DEVELOPMENT_TEAM` must match the certificate
  used. Re-check `security find-identity -v -p codesigning`.
- **Expired certificate.** Renew in the Apple developer portal.

### `Maraithon.xcodeproj not found`

Run `xcodegen generate` first. The project file is intentionally
not committed.

### `dmgbuild: command not found`

`brew install dmgbuild`. If it's installed via `pipx`, ensure
`pipx`'s bin directory is on `$PATH`.

### "Developer ID Application" identity not found

The certificate isn't installed, or the keychain is locked.

```sh
security find-identity -v -p codesigning
security unlock-keychain login.keychain-db
```

### Re-running after a partial failure

`release.sh` deletes `build/` at the start of every invocation, so
re-running is always safe. If you want to inspect intermediate
artifacts before they're wiped, copy `build/` elsewhere first.

## What the script does NOT do

- **Tag the git commit.** Tag manually:
  `git tag v$(plutil -extract CFBundleShortVersionString raw Sources/Maraithon/Resources/Info.plist)`.
- **Upload the DMG.** Copy `build/Maraithon-<version>.dmg` onto the
  Fly volume (or wherever the URL in `release-info.json` points)
  yourself — see *Publishing a release* above.
- **Insert the appcast row.** Run `mix companion.release` on the
  server with the JSON manifest emitted by the script.

## Reference

- Apple notarization docs:
  <https://developer.apple.com/documentation/security/customizing-the-notarization-workflow>
- dmgbuild docs: <https://dmgbuild.readthedocs.io/>
- Sparkle code-signing guide:
  <https://sparkle-project.org/documentation/sandboxing/>
