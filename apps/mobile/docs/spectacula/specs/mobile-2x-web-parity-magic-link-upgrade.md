# Mobile 2x Web-Parity Magic Link Upgrade Specification

Status: Complete v1
Purpose: Make the SwiftUI mobile app materially better by matching the web Magic sign-in/sign-up flow and adding a unified Today cockpit that connects Todos, CRM, and Chat.
Audience: Engineering and product review.

## 1. Overview and Goals

The current iOS app is a polished local SwiftUI scaffold, but its authentication flow diverges from the web product. The web Maraithon app at `/Users/kent/bliss/maraithon` uses a passwordless magic-link flow:

- `POST /auth/magic-link` accepts `magic_link[email]` or `email`.
- `Accounts.get_or_create_user_by_email/1` creates a user when the email is new.
- A single-use token is stored hashed in `user_magic_links`.
- The magic link is `/auth/magic/:token`.
- Links expire after 15 minutes.
- Consuming a valid link confirms the user and creates a persisted session.
- Sessions expire after 60 days.
- The same flow covers sign-in and sign-up.

The mobile app must mirror this contract locally and expose production-ready seams for a server-backed implementation later. The product should also become 2x more useful by adding a Today cockpit that turns separate feature tabs into one operational workflow.

## 2. Scope and Non-Goals

### 2.1 In Scope

- Replace the mobile OTP-style development auth with a web-parity magic-link flow.
- Make sign-in and sign-up use the same email-link contract, matching the web behavior.
- Add token/link parsing for:
  - raw token strings
  - `https://.../auth/magic/:token`
  - `maraithon://auth/magic/:token`
  - `maraithon://magic/:token`
- Add a custom URL scheme so the app can receive local magic links.
- Update session persistence to store email-as-user-id and a 60-day session expiry.
- Add a Today cockpit tab that summarizes the user's day, open work, overdue tasks, at-risk CRM, stale contacts, and recent chat context.
- Add pure insight helpers and tests.
- Preserve the existing Todos, CRM, and Chat tabs.

### 2.2 Non-Goals

- Add backend API endpoints to the Phoenix web app.
- Add real email delivery from the mobile app.
- Add Universal Links infrastructure or Apple associated domains.
- Add Magic.com SDK dependencies.
- Add push notifications or background sync.

## 3. Authentication Contract

### 3.1 User Experience

The signed-out screen must show a native passwordless account screen with two modes:

| Mode | Behavior |
|---|---|
| Sign In | Email the user a one-time magic link. Existing users sign in. |
| Sign Up | Email the user a one-time magic link. New users are created automatically. |

Both modes call the same underlying provider method, because the web app creates users on demand. Copy must make clear that there is no password and that links expire in 15 minutes.

In local development, because no Postmark/web backend credentials are present, the request result must show a development magic link. The user can:

- tap "Open Development Link" to consume it immediately
- paste a received link or token into a field
- switch email and request a new link

### 3.2 Auth Provider Interface

```swift
@MainActor
protocol AuthProviding {
    func requestMagicLink(email: String) async throws -> MagicLinkRequest
    func consumeMagicLink(_ linkOrToken: String) async throws -> AuthenticatedUser
    func restoreSession() async throws -> AuthenticatedUser?
    func signOut() async throws
}
```

### 3.3 Local Provider Semantics

| Behavior | Requirement |
|---|---|
| Email normalization | Trim and lowercase before storing. |
| User identity | Use normalized email as the user id, matching the web `User.id`. |
| Link TTL | 15 minutes. |
| Link use | Single use. Consuming a used, missing, malformed, or expired link returns the same invalid/expired user-facing error. |
| Session TTL | 60 days. Expired local sessions are cleared on restore. |
| Development link | Build an HTTPS-style link with `/auth/magic/:token` and also accept the custom scheme. |

## 4. Product Upgrade Contract

### 4.1 Today Cockpit

Add a first tab named `Today` with system image `sparkles.rectangle.stack`. It must:

- greet the signed-in user by email prefix
- show metrics for open todos, overdue todos, pipeline value, and at-risk contacts
- show a Focus Queue of the highest-value current actions:
  - overdue todos
  - today todos
  - at-risk CRM contacts
  - stale contacts not contacted in 7+ days
- show a compact recent-chat section
- provide native navigation links into relevant Todo, CRM, and Chat details where practical

### 4.2 Existing Tabs

Todos, CRM, and Chat remain top-level tabs. Today must not replace existing feature ownership; it composes data across features.

## 5. Technical Design

### 5.1 New/Changed Components

| Component | Change |
|---|---|
| `AuthModels` | Replace OTP challenge fields with magic-link request/session fields. |
| `AuthProviding` | Rename OTP methods to web-parity magic-link methods. |
| `LocalMagicAuthProvider` | Implement single-use 15-minute magic links and 60-day sessions. |
| `MagicLinkParser` | Parse raw token, HTTPS web links, and custom scheme links. |
| `SessionStore` | Request and consume magic links; handle incoming URLs. |
| `MagicSigninView` | Replace code-entry UI with sign-in/sign-up link UI. |
| `Info.plist` | Register `maraithon` URL scheme. |
| `AppShellView` | Add Today tab while preserving Todos, CRM, Chat. |
| `TodayView` | Add cross-feature cockpit. |
| `TodayInsightEngine` | Pure insight/metric helper for tests and UI. |

### 5.2 Data Model Impact

No SwiftData schema changes are required. Auth session persistence uses `UserDefaults`; the persisted user payload changes shape and may invalidate older local demo sessions. If restore fails, the provider clears the old session and signs the user out.

## 6. Failure Handling

- Invalid email: "Please enter a valid email address."
- Invalid, expired, malformed, or already-used link: "Sign-in link is invalid or expired."
- Expired restored session: clear the session and show signed-out UI.
- Incoming auth URL while signed in: consume it and replace the active session only if valid.
- Missing web app path: recorded as an assumption; `/Users/kent/bliss/maraithon` is used as the reference because `~/bliss/maraithon-app` does not exist.

## 7. Test Plan and Validation Matrix

| Area | Validation |
|---|---|
| Web parity | Tests verify 15-minute link expiry and single-use token behavior. |
| Sign-up semantics | New email creates a local user with email id. |
| Deep link parsing | Tests cover raw token, HTTPS link, and custom scheme link. |
| Session TTL | Tests verify restore succeeds before expiry and clears after expiry. |
| Today insights | Tests verify focus queue ordering and metrics. |
| Build | iOS Simulator build passes. |
| Tests | Existing and new tests pass. |
| Spec review | Implementation is checked against this spec before completion. |

## 8. Definition of Done

- The Spectacula spec and lifecycle manifest are saved.
- Auth UI and local provider match the web magic-link contract.
- Sign-in and sign-up share one email-link flow.
- The app handles pasted links and incoming custom-scheme links.
- The Today tab exists and composes Todos, CRM, and Chat into a useful cockpit.
- Tests cover the new auth/link/insight behavior.
- `xcodegen generate`, build, and tests pass, or blockers are recorded.

## 10. Completion Notes

- Implemented web-parity magic-link auth, sign-in/sign-up UI, custom-scheme handling, and parser coverage.
- Added Today as the first tab with cross-feature metrics, a focus queue, recent chat, and navigation into CRM/chat plus todo editing.
- Added tests for local magic-link semantics, parser behavior, and Today insights.
- Verified with `xcodegen generate`, iOS Simulator build, iOS Simulator tests, `plutil -lint`, and manifest JSON validation.

## 9. Assumptions

| Assumption | Impact |
|---|---|
| `/Users/kent/bliss/maraithon` is the intended web reference. | The requested `~/bliss/maraithon-app` path is absent; this repo contains the matching Phoenix magic-link implementation. |
| Mobile remains offline-capable for now. | The local provider mirrors web semantics instead of requiring live Postmark/backend credentials. |
| Adding a Today tab is acceptable. | It materially improves product quality while preserving Todos, CRM, and Chat tabs. |
| Universal Links are future work. | The app supports a custom URL scheme and pasted HTTPS links now. |
