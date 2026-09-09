# Maraithon Desktop

Maraithon now opens to tasks in a shared Phoenix workspace. Electron supplies the desktop window. The signed Swift companion supplies the Mac context. Erlang/OTP still owns the work.

The web app and desktop use the same task screens, action cards, drafts, data model, and server events. The responsive web app uses the same theme on phones. The native iOS app has not been rewritten.

## Run it

From the repository root:

```sh
make build-desktop
MARAITHON_DESKTOP_ORIGIN=http://127.0.0.1:4000 make run-desktop
```

Start Phoenix separately with the repository's normal development command. Sign-in opens in your default browser. After signing in, choose **Open Maraithon** to return to the desktop task list. The desktop keeps its own session across restarts.

The default origin is `https://maraithon.com`. That server must run this branch before the new desktop sign-in endpoints will work. This change does not deploy the server.

`MARAITHON_DESKTOP_ORIGIN` accepts an HTTPS origin or a loopback HTTP origin for development. Sessions are isolated by origin. `MARAITHON_DESKTOP_USER_DATA` can point at a separate profile for previews.

## Keep the Mac context

```sh
make build-sync-helper
```

The helper is built from `apps/companion`, with its existing signing configuration. **Mac sources** in the sidebar or **Command-comma** opens it. A packaged desktop app starts it in the background; a development shell only starts it automatically when `MARAITHON_START_NATIVE=1`. Set `MARAITHON_START_NATIVE=0` to suppress automatic startup in an isolated preview. The source button remains available.

The helper keeps `com.maraithon.companion`, its existing credential stores, encryption keys, privacy permissions, queues, cursors, and source implementations. It still includes Messages, Contacts, Notes, Voice Memos, Reminders, Calendar, Files, browser history, and the Chrome relay. Electron does not read the Messages database or take ownership of those permissions.

A running companion is reused. Otherwise Electron starts the bundled helper with `--sync-helper`. `MARAITHON_NATIVE_HELPER` can point at a specific signed companion bundle. Closing or quitting Electron leaves native sync running. The helper's source window remains available from its menu bar.

Desktop login and Mac pairing are separate existing sessions. If Mac sources shows **Connect to Maraithon**, pair the device there. Signing into the task window does not silently pair a device or grant access to local data. During verification on this Mac, both builds restored the existing account after the brief startup screen. All eight sources reported ready. The rebuilt helper completed a live iMessage check successfully, with existing context intact and no new pairing or privacy grants.

## Where the Runner design comes from

`priv/static/styles/runner-theme.css` contains Runner Next's actual product tokens from `apps/web-client/src/styles.css`, reference commit `c529ee6f96bca4e2839996ba176757184b0473df`:

- Light and dark colours, status and pill colours, foreground mixes, borders, motion, shadows, and paper grain.
- Geist Variable, copied with its OFL licence.
- Runner's 11/13/15/18 px desktop type scale and larger mobile scale.
- Button recipes from `components/ui/button.tsx`, adapted to the existing Phoenix component API.
- The centred browser sign-in flow and macOS window conventions from Runner's desktop app.

The portable stylesheet converts Tailwind 4 `@theme` declarations to CSS variables. A small adapter preserves Maraithon's existing zinc utility names. Phoenix's task layout stays in `assets/css/app.css`; its events and durable draft hooks stay in their existing modules. The desktop build copies the same theme and font files, so it cannot acquire a separate colour palette.

## Build a local Mac app

```sh
make package-desktop
```

This builds and signs the Swift helper, copies shared assets, and packages Electron. When the helper uses an Apple Development identity, the local packaging script uses that identity for the desktop too. The result is `apps/desktop/dist/mac-arm64/Maraithon Desktop.app` on an Apple Silicon Mac.

The helper is excluded from Electron's re-signing pass. Its original signature and entitlements must stay intact. Verify both bundles with `codesign --verify --deep --strict` before distributing a build.

This local build is development signed. A public release still needs Developer ID signing, notarization, and a deployed server with the desktop auth routes. `npm run dist` invokes the release packager; configure the release identities and notarization through the existing release process first. Windows and Linux targets are configured but have not been built or verified here. Mac-only sources stay on macOS.

## Security and data boundaries

The renderer is sandboxed with context isolation and no Node integration. Its preload exposes only sign-in, retry, and source settings. Main-process handlers validate their sender. Only the trusted main frame may write to the clipboard for draft copying; clipboard reading and other device permissions remain denied. Navigation stays on the configured origin; external links and connector consent open in the system browser.

The browser handoff uses a random state and PKCE verifier, a bounded loopback listener, an encrypted short-lived ticket, and Maraithon's existing single-use magic-link/session records. The verifier stays in Electron's main process. No new auth tables or migrations are introduced. The handoff does not copy the browser's cookies.

The rebuild changes presentation and desktop integration. Domain modules, OTP supervision, ingestion, delivery guards, action approvals, schemas, and migrations remain at the checkpoint commit. Drafts still use the existing LiveView storage hooks and receipt-based clearing. Web drafts remain tab-scoped. Electron uses persistent local storage under the same user/task key, inside its isolated origin profile, so drafts also survive quitting the app. They are not an offline task database; the offline screen offers reconnect while preserving the local session and saved drafts.

## Branch and rollback

The implementation lives on `codex/runner-desktop`. The complete starting state, including the hardened work that was uncommitted in the original checkout, is saved at `17c04b97` and branch `rollback/pre-runner-desktop`.

The original checkout at `~/bliss/maraithon` was left on its original branch with its original changes. To review the checkpoint in a separate checkout:

```sh
git worktree add ../maraithon-before-electron rollback/pre-runner-desktop
```

No production deployment, merge, or database rollback is needed to stop using this preview.
