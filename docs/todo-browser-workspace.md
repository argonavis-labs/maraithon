# Todo browser workspace

Todos can use a persistent Google Chrome session on the user's paired Mac,
including when the conversation starts on web or iPhone. The updated Mac app
must be running with Chrome installed. Sign in to websites once in Maraithon's
Chrome profile; those sessions remain local to that profile.

## Runner reference and native implementation

The reference is `~/bliss/runner/apps/electron/src/main/chrome/`: its Chrome
manager, profile, focus suppressor, per-session ownership and desktop relay.
Maraithon uses the same separate-profile, background-tab and outbound-relay
approach. Its Swift companion talks directly to the bounded Chrome DevTools
Protocol surface through URLSession rather than packaging Runner's Electron,
Node, and MCP subprocess stack. No new dependency was added.

Each account has its own private directory under
`~/Library/Application Support/Maraithon/Browser/`. DevTools listens on loopback
with an automatically allocated port. The app verifies the browser identity
from DevToolsActivePort before reconnecting, restores only its owned todo tabs,
and never attaches to the user's ordinary Chrome profile. Cookies and passwords
are not copied from the user's normal browser or sent to the server. At most 20
owned todo tabs remain open. Downloads are disabled for the automation profile.

## Product behavior

The shared todo tool `todo_browser` supports:

- `navigate`: open an exact http(s) source URL in the background.
- `snapshot`: read live accessible page text and current element references.
- `show`: reveal the todo's tab on the Mac for sign-in or manual intervention.
- `click`, `fill`, `press`: prepare the exact page, element and text as a Chrome
  review card. Confirmation runs that one step; it never completes the todo.

Web, Mac, and iPhone show the same immutable Chrome review. The companion checks
that the approved page URL, owned tab, opaque element reference and current
accessible name still match. Stale references require a fresh snapshot and
review. Passwords, one-time codes, file upload controls and unsupported page
widgets require manual interaction in the visible browser. After interaction,
the assistant must inspect the page to verify the website's result.

The first version reads accessible DOM content, not screenshots. Complex
cross-origin frames and custom canvas controls may require the user's visible
browser. Chrome is opened through LaunchServices without activating it; new
todo tabs use `background: true`. Ordinary reviewed links remain in the owned
tab. Website-created popup windows can still request focus.

## Delivery and recovery

The existing supervised AssistantChat runner owns model work. PostgreSQL owns
browser delivery across web/runtime processes and deployment revisions:

- A paired Mac polls the authenticated relay every five seconds while idle;
  HTTP failures back off to 30 seconds. Its browser availability expires after
  30 seconds without a heartbeat.
- A command has a 45-second deadline and is claimed once with a row lock.
  Claiming atomically changes pending to running. Running commands are never
  placed back on the queue.
- The Mac executes commands sequentially. Only result acknowledgements are
  retried, using the same command ID. Confirmed interactions use the prepared
  action ID for deduplication.
- A lost result becomes an uncertain outcome. The assistant must inspect the
  page rather than repeat the interaction. Chrome reconnects on the next read;
  a closed tab is replaced only inside its todo's ownership boundary.
- Payloads and results are encrypted with the application vault and registered
  for rotation. Relay payloads are pruned after one day when that device next
  polls. Device deletion cascades the relay rows; user erasure includes both
  tables. The durable conversation retains the useful work result.

Transport endpoints use CompanionDeviceAuth:
`POST /api/v1/companion/browser/claim` and
`POST /api/v1/companion/browser/:id/result`. Identity is derived from the paired
device, never from request fields. The browser's local debugging endpoint is
never exposed to the cloud. There is no shell or arbitrary JavaScript tool.

Protocol references: [Target](https://chromedevtools.github.io/devtools-protocol/tot/Target/),
[Runtime](https://chromedevtools.github.io/devtools-protocol/tot/Runtime/), and
[Chrome remote debugging profiles](https://developer.chrome.com/blog/remote-debugging-port).

## Release verification — September 8, 2026

Implementation commits: `b4041904` and `876ff8bb`. Changes were merged back into
`~/bliss/maraithon` file by file, preserving its existing working changes.

- Production: `maraithon-00268-jxg` serves 100% of traffic, image
  `dev-876ff8bb3854-20260908135634-1`. Cloud Build
  `57231f48-bbc1-4191-afcd-4873cf56d4c0` succeeded. The relay migration had
  already succeeded in execution `maraithon-migrate-dmmbt` for revision 267.
- Mac: signed development build installed at
  `~/Applications/Maraithon.app`; strict signature verification passed.
  Existing pairing restored after restart.
- iPhone: version 1.0.1, build `20260908134908`, uploaded successfully and
  confirmed `VALID` / `IN_BETA_TESTING` in App Store Connect.
- Phoenix compile with warnings as errors, asset build, SwiftPM compile,
  XcodeGen, signed Mac build, and iPhone simulator build all passed. The main
  checkout's Phoenix compile passed after integration. Tests were intentionally
  not added or run under `docs/development-mode.md`.

Manual production verification used the dedicated todo
`cf5c8bd7-4c32-4a65-8f28-39648c574fdc` and public example pages:

1. A web conversation opened `https://example.com` in the Mac's separate Chrome
   profile and returned the live title, "Example Domain," and "Learn more" link.
2. The assistant prepared an immutable Chrome review for that link and exact
   page. Confirming **Run browser step** executed the click. The action became
   completed while the todo remained open.
3. A fresh snapshot verified "Example Domains" at
   `https://www.iana.org/help/example-domains`.
4. After quitting, updating, and reopening the Mac app, a natural-language
   request inspected the existing tab. It returned the same IANA title and URL
   without navigating or clicking, verifying restored tab ownership. The work
   summary used the updated plain-language page-read message.
5. Only after those checks was the verification todo manually marked done.

The first model request during the initial rollout ended with the existing
incomplete-evidence fallback before issuing a browser command; a new request
and all subsequent browser checks succeeded. Recovery from lost command-result
acknowledgements was inspected in code, not fault-injected. Cross-client review
rendering was compiled on iPhone and shipped through TestFlight; the browser
execution/restart check was driven from the production web conversation.
