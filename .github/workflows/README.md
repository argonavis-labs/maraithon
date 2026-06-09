# Workflows

## `deploy-fly.yml`
Push to `main` → deploys the Phoenix backend to Fly.

## `mobile-release.yml`
- Push to `main` → builds the iOS app and uploads to TestFlight, then attaches it to **Internal Testers**. If a **Staging** beta group exists, CI attaches the build there too.
- Tag `v*` (e.g. `v1.0.4`) → builds and uploads to TestFlight, then attaches to the **Internal Testers** (production) beta group.
- Manual `workflow_dispatch` → choose `staging` or `production`.

Mirrors the gigamono pattern: `main` is the staging track, tags are the production track. Every mobile build also goes to **Internal Testers**, and CI verifies that `kent.fenwick@gmail.com` is present in that group.

### Required GitHub secrets

| Secret | What it is | How to get it |
| --- | --- | --- |
| `APP_STORE_CONNECT_API_KEY_ID` | ASC API key ID (e.g. `2XG664G4GG`) | App Store Connect → Users and Access → Integrations → App Store Connect API |
| `APP_STORE_CONNECT_API_ISSUER_ID` | ASC issuer ID (e.g. `69a6de6e-…`) | Same screen as above |
| `APP_STORE_CONNECT_API_KEY_P8` | Full contents of `AuthKey_<ID>.p8` (PEM, multi-line, **no base64**) | The `.p8` Apple gives you when the key is created |

The runner is `macos-latest`. The workflow expects Xcode 26 to be selectable; GitHub-hosted macOS runners ship with multiple Xcodes — adjust the `Select Xcode` step if a different version is needed. Xcode uses the App Store Connect API key for automatic signing and provisioning.

### TestFlight groups

The workflow looks up beta groups by display name via the ASC API. Make sure both groups exist on the Maraithon app:

- `Internal Testers` — required internal track, populated by every mobile build. Must include `kent.fenwick@gmail.com`.
- `Staging` — optional staging track, populated by every push to `main` when the group exists.

Create them under TestFlight → Internal Testing in App Store Connect. The groups must be on the **same app record** (Maraithon, ASC app ID `6773374784`). A missing **Internal Testers** group fails CI; a missing **Staging** group is skipped.

### Local equivalents

The CI workflow ultimately runs `make testflight-mobile`, which is the same command you can run from your Mac. The CI variant sets `MARAITHON_MOBILE_BUILD_NUMBER`, materializes the API key for upload and automatic signing, and attaches the resulting build to TestFlight groups.

### Cutting a production release

```bash
git tag v1.0.1
git push origin v1.0.1
```

That alone triggers the workflow with `MOBILE_ENV=production`. The build will land in TestFlight under Internal Testers within ~30 minutes.
