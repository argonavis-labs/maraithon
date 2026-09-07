# Workflows

## `deploy-gcp.yml`

Server-relevant pushes to `main` run the manual-first fast path: cached Cloud
Build, migrations only when migration files changed, one combined Cloud Run
service deployment, and one health request. The workflow does not run tests.
Native-only, test-only, docs-only, and Markdown-only pushes are ignored, and a
newer push cancels a superseded deploy. See
[`../../docs/development-mode.md`](../../docs/development-mode.md).

## `mobile-release.yml`
- Pushes to `main` that change the iOS app or its release tooling → build the iOS app and upload it to TestFlight, then make it available to the required internal **Founders** group. Backend-only pushes do not create TestFlight builds. If a **Staging** beta group exists, CI attaches the build there too.
- Tag `v*` (e.g. `v1.0.4`) → builds and uploads to TestFlight, then makes it available to the required internal **Founders** group.
- Manual `workflow_dispatch` → choose `staging` or `production`.

Mirrors the gigamono pattern: `main` is the staging track, tags are the production track. Every mobile build also goes to the internal **Founders** TestFlight group, and CI verifies that `kent.fenwick@gmail.com` is present in that group.

### Required GitHub secrets

| Secret | What it is | How to get it |
| --- | --- | --- |
| `APP_STORE_CONNECT_API_KEY_ID` | ASC API key ID (e.g. `2XG664G4GG`) | App Store Connect → Users and Access → Integrations → App Store Connect API |
| `APP_STORE_CONNECT_API_ISSUER_ID` | ASC issuer ID (e.g. `69a6de6e-…`) | Same screen as above |
| `APP_STORE_CONNECT_API_KEY_P8` | Full contents of `AuthKey_<ID>.p8` (PEM, multi-line, **no base64**) | The `.p8` Apple gives you when the key is created |
| `APPSTORE_CERTIFICATES_FILE_BASE64` | Password-protected distribution `.p12`, encoded as base64 | Export the existing Apple Distribution identity with its private key |
| `APPSTORE_CERTIFICATES_PASSWORD` | Password for that `.p12` | Set when exporting the identity |

The runner is `macos-latest`. The workflow selects Xcode 26.6. It imports the
existing distribution identity into a temporary runner keychain and downloads
the App Store profile before archiving. Archive and export use **manual**
signing with `Apple Distribution` and profile **Maraithon AppStore CI** for
`com.bliss.maraithonmobile`, team `PS5W7BFTQ2`. The profile includes production
push notifications and must contain the imported certificate.

The API key downloads profiles and uploads/manages TestFlight builds. Xcode
does not receive `-allowProvisioningUpdates` for either archive or export.
Missing or expired signing assets fail the build; releases must not create
development certificates or revoke team certificates to make room.

Renew signing assets deliberately when the distribution certificate expires:
update the two certificate secrets together and regenerate **Maraithon AppStore
CI** with the replacement certificate and the app's existing capabilities.
Do not revoke other apps' certificates or add a per-release cleanup job.
Keep `.p12` files, passwords, and API private keys out of the repository and logs.

### TestFlight groups

The workflow looks up beta groups by display name via the ASC API. Make sure both groups exist on the Maraithon app:

- `Founders` — required internal track, populated by every mobile build. Must include `kent.fenwick@gmail.com`.
- `Staging` — optional staging track, populated by every push to `main` when the group exists.

Create them under TestFlight → Internal Testing in App Store Connect. The groups must be on the **same app record** (Maraithon, ASC app ID `6773374784`). A missing **Founders** group fails CI; a missing **Staging** group is skipped.

### Local equivalents

The CI workflow ultimately runs `make testflight-mobile`, which is the same
command you can run from your Mac after installing the distribution identity
and **Maraithon AppStore CI** profile. The CI variant installs those assets,
sets `MARAITHON_MOBILE_BUILD_NUMBER`, materializes the API key for upload, and
attaches the resulting build to TestFlight groups. Simulator/development builds
retain their existing Xcode signing settings.

### Cutting a production release

```bash
git tag v1.0.1
git push origin v1.0.1
```

That alone triggers the workflow with `MOBILE_ENV=production`. The build will land in TestFlight under Founders within ~30 minutes.
