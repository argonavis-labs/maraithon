# Sparkle EdDSA Key Management

Sparkle uses an EdDSA (Ed25519) key pair to authenticate Mac
companion app updates. The **private key** lives in the release
operator's Mac Keychain (and a backup in 1Password / on a hardware
token). The **public key** is embedded in the shipped Mac app via
`SUPublicEDKey` in the Info.plist and is therefore baked into every
copy of `Maraithon.app` we ship.

Sparkle verifies, at install time, that the new DMG's bytes were
signed by the matching private key. If the signature is missing or
invalid, the update is rejected — even if the appcast feed itself
was compromised.

## When to (re-)generate the key

- **Once, at the start of the project.** That's the only time
  we expect to run this in normal operation.
- **Never again, ideally.** Rotating means every existing installed
  copy of the app needs a manual reinstall to pick up the new
  public key.
- **Emergency rotation** if the private key is suspected
  compromised. This is a forced reinstall for every user.

## Generating the key pair (one-time)

1. Clone the Mac repo and ensure Sparkle is fetched via SwiftPM:

   ```sh
   cd ~/bliss/maraithon-mac
   xcodegen generate
   # Build once so the Sparkle package is checked out:
   xcodebuild -resolvePackageDependencies
   ```

2. Run the helper script in the Mac repo:

   ```sh
   ./scripts/sparkle_keys.sh
   ```

   This wraps Sparkle's `generate_keys` binary. On first run it:
   - Generates an Ed25519 key pair.
   - Stores the **private** key in your login Keychain under the
     service name `https://sparkle-project.org` with account
     name `ed25519`.
   - Prints the **public** key (a 44-character base64 string) to
     stdout.

3. Copy the public key.

## Persisting the keys

### Private key

- Already in your login Keychain by virtue of `generate_keys`. Do
  not export it.
- Make a backup: open `Keychain Access`, search for
  `sparkle-project.org`, right-click → **Copy Password** to clipboard
  → paste into the shared 1Password vault as a Secure Note titled
  *Maraithon Sparkle EdDSA private key*.
- If you have a hardware token (YubiKey with a TOTP / static
  password slot, or an Apple Configurator passkey), also store the
  base64 string there.

### Public key

- Open `~/bliss/maraithon-mac/Config.local.xcconfig` (gitignored,
  per-developer).
- Add:

  ```xcconfig
  SUPublicEDKey = <44-char base64 public key>
  ```

- Regenerate the project: `xcodegen generate`. The `project.yml`
  references `SUPublicEDKey` via `INFOPLIST_KEY_SUPublicEDKey`, so
  the value flows from `Config.local.xcconfig` → Info.plist →
  bundled app.

- Verify the bundled value after a build:

  ```sh
  plutil -extract SUPublicEDKey raw \
    build/export/Maraithon.app/Contents/Info.plist
  ```

  The 44-char base64 string should be printed.

## Signing a release

`scripts/release.sh` in the Mac repo calls Sparkle's `sign_update`
binary against the final DMG and emits the EdDSA signature into
`build/release-info.json`. The release operator copies that
signature into:

```sh
mix companion.release \
  --version 0.1.1 \
  --build 2 \
  --url https://maraithon.com/releases/Maraithon-0.1.1.dmg \
  --signature "$(jq -r .signature build/release-info.json)" \
  --notes "Bug fixes & improvements."
```

…on the Phoenix server (or via the `--from-release-info` shortcut
that reads the JSON directly). The new row appears in the
`companion_releases` table and is served at
`/companion/appcast.xml` on the next request.

## What lives where

| Artifact | Location |
| --- | --- |
| EdDSA private key | macOS Keychain on the release operator's laptop; 1Password backup |
| EdDSA public key | `Config.local.xcconfig` → bundled into every shipped app |
| Per-release signature | `companion_releases.signature` column (and the appcast XML) |
| DMG bytes | Fly volume mounted at `/data/releases` (served at `https://maraithon.com/releases/*.dmg`) or an S3-fronted CDN — `companion_releases.url` is whatever the operator pasted on the `mix companion.release` invocation |
