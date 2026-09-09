# Runner's local Chrome pattern

Maraithon uses installed Google Chrome on the paired Mac. The reference is `~/bliss/runner/apps/electron/src/main/chrome/`, not Runner Next's hosted browser integration. Maraithon's existing Swift relay already implements this pattern. The Electron rebuild keeps that relay and introduces no Browserbase service, SDK, or credentials.

The hardened OTP runtime still schedules and authorizes browser work. The paired companion claims each command once, operates the task's owned Chrome tab, and retries only result delivery. Profile isolation, loopback DevTools discovery, persistent tab ownership, opaque element references, exact reviewed interactions, and download blocking remain in place. Website sessions stay in the account's existing Mac profile. See `todo-browser-workspace.md` for the protocol.

Browser action cards now identify **Local Chrome · on your Mac** and display a Chrome icon with Runner's actual vector mark. The same image is included in the native companion and mobile assets.

Before launching an idle profile, the companion sets its name to **Runner** and gives its Home button a local, Runner-branded page. This setup runs once, preserves other preferences, and skips profiles with a Chrome lock. A running profile picks up the change after a clean Chrome restart. The home page uses bundled assets without remote requests or scripts. Users can change their profile name and home page afterward without Maraithon repeatedly replacing them.

**Show browser** selects the task tab, restores its window if minimized, and activates the browser PID obtained through that profile's verified DevTools connection. It does not select Chrome by bundle ID, which could bring forward another profile.

The ordinary Google Chrome app and Dock icon retain Google's signature and update path. A separately branded Dock app is not included in this change. Updating an existing installation requires the newly signed companion at its existing app path so its Mac privacy grants remain attached to the same identity and location.

## Verification

- TypeScript, Phoenix assets, Phoenix compilation, and Swift compilation pass.
- A manual preview compiled from the product browser sources opened `https://example.com`, returned its live accessibility snapshot, and restored the same task tab after disconnecting and recreating the browser actor.
- The updated show action returned success using the owned browser PID.
- The signed-in web workspace renders the new browser action card and badge.
- Browser tooling blocked opening the local HTML home page. Its visual appearance inside the managed Chrome instance has not been verified through that tooling.
- No OTP/domain code or migrations changed. No iMessage or other source implementation changed.
- Updated the installed companion at `~/Applications/Maraithon.app` after checking that its signing requirement matched. The existing account and all eight sources returned ready. iMessage ingested two new messages after the update, with 6,993 messages available. The previous signed app is saved outside the repository at `~/Documents/Codex/2026-09-08/let/work/native-before-local-chrome/Maraithon.app`.
