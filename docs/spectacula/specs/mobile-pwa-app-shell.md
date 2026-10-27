# Mobile PWA App Shell Specification

Status: Implementing v1
Purpose: Make Maraithon installable and usable as a polished mobile progressive web app without compromising authenticated data safety.

## 1. Overview and Goals

Maraithon is increasingly used as a daily chief-of-staff surface. Mobile usage should feel like a first-class app: installable from the browser, fast to open, safe when offline, and easy to navigate with one thumb.

Goals:

- Ship basic PWA installability for modern mobile browsers.
- Add mobile app metadata for iOS and Android home-screen usage.
- Improve authenticated mobile navigation with a compact bottom tab bar.
- Preserve the existing Catalyst/Tailwind visual language: quiet, operational, row-oriented, and minimal.
- Avoid caching authenticated HTML or private user data in the service worker.

## 2. Current State and Problem

Current app shell facts:

- `lib/maraithon_web/components/layouts/root.html.heex` defines basic viewport and LiveView bootstrap.
- `priv/static` contains a favicon, connector logos, and robots.txt.
- `MaraithonWeb.static_paths/0` allows `assets`, `fonts`, `images`, `favicon.ico`, and `robots.txt`.
- The authenticated app uses `MaraithonWeb.AdminNavigation.admin_layout/1` for sidebar and mobile drawer navigation.
- There is no `manifest.webmanifest`, `sw.js`, offline page, home-screen metadata, app icon set, or persistent mobile tab bar.

Problems:

- Mobile users cannot install Maraithon as a high-quality standalone app.
- The app does not advertise theme color, standalone display, app title, or icons.
- Mobile navigation requires opening the drawer for common destinations.
- Offline states fall back to browser errors instead of a branded, useful fallback.

## 3. Scope and Non-Goals

In scope for v1:

- PWA manifest with app name, start URL, scope, theme colors, icons, and shortcuts.
- Service worker that precaches safe static shell assets and serves an offline fallback for navigations.
- Mobile metadata in the root layout for iOS/Android install behavior.
- Static app icons and offline page.
- Authenticated mobile bottom tab bar for core routes and command search.
- Tests covering PWA static assets and root layout/mobile shell rendering.

Non-goals for v1:

- Full offline authenticated data sync.
- Background sync for todos, CRM, or connected-app writes.
- Push notification permissions or web push.
- Replacing the existing desktop sidebar.
- Building a separate native mobile app.

## 4. UX / Interaction Model

### 4.1 Installable App

When a user opens Maraithon on mobile:

- Browser install prompts should identify the app as `Maraithon`.
- Home-screen icon should use a clean Maraithon brand mark.
- Standalone launch should open `/dashboard`.
- The browser UI should use a dark neutral theme color that matches the app brand.

### 4.2 Mobile Navigation

On authenticated app pages below the large-screen breakpoint:

- The existing top mobile header remains available for drawer navigation.
- A fixed bottom tab bar appears with Dashboard, Todos, People, Agents, and Search.
- Current route is visually marked.
- Search opens the global command palette instead of navigating.
- Main content gets bottom safe-area padding so the tab bar does not cover controls.

### 4.3 Offline Fallback

If a navigation request fails while offline:

- The service worker returns a branded offline page.
- The offline page makes clear that connected accounts, todos, and live agent state require reconnecting.
- Private authenticated pages are not cached or replayed.

## 5. Functional Requirements

| Requirement | Behavior |
|---|---|
| Manifest | `/manifest.webmanifest` is publicly served and declares standalone PWA metadata. |
| Service worker | `/sw.js` is publicly served and registers from the root layout when supported. |
| Safe caching | Service worker precaches only static icons, manifest-adjacent shell assets, and `/offline.html`. |
| Offline navigation | Failed same-origin navigation requests return `/offline.html`. |
| Mobile metadata | Root layout includes viewport fit, theme color, Apple mobile web app tags, manifest link, icon link, and touch icon. |
| Mobile tab bar | Authenticated mobile pages render bottom navigation without affecting desktop layout. |
| Command access | Mobile tab bar includes a Search action wired to the global command palette trigger. |
| Static routing | `MaraithonWeb.static_paths/0` includes top-level PWA files. |

## 6. Frontend / UI / Rendering Changes

Affected files:

- `lib/maraithon_web.ex`
- `lib/maraithon_web/components/layouts/root.html.heex`
- `lib/maraithon_web/components/admin_navigation.ex`
- `priv/static/manifest.webmanifest`
- `priv/static/sw.js`
- `priv/static/offline.html`
- `priv/static/images/app-icon.svg`
- generated PNG icon files under `priv/static/images`

Design rules:

- No marketing hero, gradients, or decorative cards.
- Bottom tab bar uses compact icons and labels.
- Tab bar respects `env(safe-area-inset-bottom)`.
- Header respects `env(safe-area-inset-top)` when launched standalone.
- Offline page uses the brand mark and a short operational message.

## 7. Security, Privacy, and Data Safety

The service worker must not cache:

- Authenticated HTML responses.
- API responses.
- LiveView WebSocket data.
- User todos, CRM records, memory records, or connected app content.

The service worker may cache:

- PWA icon assets.
- `manifest.webmanifest`.
- `offline.html`.
- Other same-origin static assets if explicitly added later.

## 8. Failure Modes and Edge Cases

| Scenario | Expected behavior |
|---|---|
| Browser does not support service workers | App works normally without registration. |
| Service worker install fails | Failure is ignored; app still loads normally. |
| User is unauthenticated and opens `/dashboard` from PWA | Existing auth flow redirects as it does today. |
| User is offline after app launch | Navigation fallback shows offline page; no private stale page is served. |
| Mobile viewport has a home indicator | Bottom nav content stays above safe area. |
| Desktop viewport | Existing sidebar layout remains primary; bottom nav is hidden. |

## 9. Test Plan and Validation Matrix

| Check | Validation |
|---|---|
| Static manifest | `GET /manifest.webmanifest` returns PWA metadata. |
| Static service worker | `GET /sw.js` returns registration target with cache version. |
| Static offline page | `GET /offline.html` returns branded fallback content. |
| Root metadata | Authenticated HTML includes manifest, theme, Apple mobile tags, and service worker registration. |
| Mobile shell markup | Authenticated HTML includes the mobile tab bar and command-palette trigger. |
| Project gate | `mix precommit` passes before completion. |

## 10. Definition of Done

- PWA static assets are served by Phoenix.
- Root layout advertises installable app metadata.
- Service worker safely caches only public static shell assets.
- Mobile authenticated shell has a clean bottom tab bar.
- Tests cover the PWA assets and mobile shell.
- `mix precommit` passes.
- Spectacula manifest is moved to `done` with verification results.

## 11. Assumptions

- `/dashboard` remains the right standalone start URL for authenticated users.
- Full offline CRUD is deliberately out of scope because the app depends on live connected accounts and sensitive user data.
- A simple generated brand icon is acceptable for v1 and can be replaced by a final brand system later.
