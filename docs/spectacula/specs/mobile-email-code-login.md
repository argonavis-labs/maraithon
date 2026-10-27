# Mobile Email Code Login Specification

Status: Done v1
Purpose: Replace mobile magic-link email login with a copyable sign-in code while preserving web magic-link behavior and production verification coverage.
Audience: Engineering and product review.

## 1. Overview and Goals

The Phoenix web app currently uses passwordless magic links for browser login. The native iOS app reuses the same mobile API contract: it requests a magic-link email, then asks the user to paste a link or token into the app. That breaks down on mobile because the email link opens outside the native app flow and is awkward to copy back into the app.

The mobile login flow must instead send an easy-to-copy one-time code in the email. The user enters that code in the iOS app, the mobile API consumes it, and the app receives the same long-lived mobile session token it receives today.

## 2. Current State and Problem

### 2.1 Current Backend Behavior

- `Maraithon.Accounts.request_magic_link/2` creates a user on demand, stores a SHA-256 hash of a 32-byte URL-safe token in `user_magic_links`, and returns the plaintext token once.
- `Maraithon.Accounts.consume_magic_link/2` consumes one unused, unexpired token and creates a `user_sessions` row.
- `MaraithonWeb.SessionController` emails `/auth/magic/:token` and consumes it for browser sessions.
- `MaraithonWeb.MobileAuthController` also emails `/auth/magic/:token` and exposes `POST /api/mobile/auth/magic/:token` for native sessions.
- `Maraithon.Accounts.EmailTemplates.magic_link/1` renders link-only transactional email content.

### 2.2 Current iOS Behavior

- `MagicSigninView` tells the user to expect a one-time link.
- `ProductionMagicAuthProvider` calls `POST /api/mobile/auth/magic-link`, then consumes a pasted link/token via `POST /api/mobile/auth/magic/:token`.
- Local development auth mirrors the link/token model.
- `apps/mobile/scripts/verify-production-simulator.sh` bypasses mailbox delivery by generating a production magic token through Fly SSH, injecting it into the UI test, and asserting production writes.

### 2.3 Problem

Mobile login requires a copyable value that works inside the app. A browser magic link is the wrong interaction model for this app because it requires a deep-link or browser handoff and gives the user a long opaque token instead of a short code.

## 3. Scope and Non-Goals

### 3.1 In Scope

- Add a mobile sign-in code to the existing passwordless auth model.
- Keep browser magic links working without changing the web login route or email.
- Send mobile login email content that emphasizes a short copyable code, not a magic sign-in link.
- Add a mobile API endpoint that exchanges a code for the existing mobile session response.
- Update the iOS signed-out flow copy, input, and provider behavior to request and submit codes.
- Preserve local development auth with deterministic code support in tests.
- Update the production simulator verification loop so it generates, injects, consumes, and asserts through the code path.
- Add backend and iOS tests for the new behavior.

### 3.2 Non-Goals

- Add SMS, push, passkeys, OAuth, or password login.
- Remove existing web magic-link login.
- Remove the legacy mobile magic-token consume route in this change.
- Add mailbox polling to the production verification loop.
- Add Universal Links or associated-domain setup.

## 4. UX / Interaction Model

### 4.1 Mobile User Flow

1. User opens the signed-out iOS app.
2. User enters email and taps "Email Me a Code".
3. API sends an email containing a copyable one-time code.
4. App shows a code entry state for the requested email.
5. User copies the code from email and pastes or types it into the app.
6. App submits the code to the mobile API.
7. API consumes the code once and returns `session_token` plus `user`.
8. App persists the session and enters the signed-in app shell.

### 4.2 Code Format

| Attribute | Requirement |
|---|---|
| Display format | `XXXX-XXXX` |
| Characters | Uppercase non-ambiguous alphanumeric characters generated server-side |
| Input tolerance | Case-insensitive; ignore spaces and hyphens |
| Expiry | Same 15-minute TTL as magic links |
| Reuse | Single use |
| Email copy | The code is visually prominent and text-selectable/copyable in common mail clients |

The code length must be long enough to avoid making brute-force guessing practical without introducing a broader rate-limiting system in this change.

## 5. Functional Requirements

| ID | Requirement |
|---|---|
| FR-1 | Browser login continues to email and consume `/auth/magic/:token` links. |
| FR-2 | Mobile `POST /api/mobile/auth/magic-link` creates a mobile sign-in code and sends code email content. |
| FR-3 | Mobile request responses include the normalized email, expiry seconds, and a signal that delivery is an email code. |
| FR-4 | Mobile `POST /api/mobile/auth/magic-code` accepts `code` or `magic_code[code]`. |
| FR-5 | Valid code consumption creates the same response shape as token consumption: `session_token` and `user`. |
| FR-6 | Invalid, expired, malformed, or reused codes return `401` with `invalid_or_expired_code`. |
| FR-7 | Existing `POST /api/mobile/auth/magic/:token` keeps working for compatibility and operational fallback. |
| FR-8 | iOS production auth submits code input to the code endpoint, while link URLs still work as a compatibility path. |
| FR-9 | Local iOS auth exposes a development code and validates code expiry/single-use semantics. |
| FR-10 | The production mobile verification script uses generated sign-in codes, not magic tokens, for simulator and API assertion sessions. |

## 6. Data and Domain Model

### 6.1 Database

Extend `user_magic_links` with an optional `code_hash` binary column. The existing table remains the source of truth for passwordless auth attempts.

| Column | Type | Null | Notes |
|---|---|---|---|
| `code_hash` | `:binary` | `true` | SHA-256 hash of the normalized ungrouped code. Present for mobile code attempts. |

Add an index on `code_hash` for lookup. The code hash should not be unique because codes are short-lived and collision probability is handled by high entropy and expiry/used filters.

### 6.2 Domain Functions

| Function | Responsibility |
|---|---|
| `Accounts.request_magic_link/2` | Existing web-compatible token request, unchanged externally. |
| `Accounts.request_magic_code/2` | Create user if needed, generate token plus code, store both hashes, return plaintext code once. |
| `Accounts.consume_magic_link/2` | Existing token consume path. |
| `Accounts.consume_magic_code/2` | Normalize code, find one unused/unexpired matching row with `code_hash`, mark it used, confirm user, create session. |

## 7. Backend / Service Changes

### 7.1 Email Delivery

Add `EmailTemplates.magic_code/1` and `MagicLinkSender.deliver_code/2`. The Postmark delivery path should remain shared and use Req. The log-only fallback should log the code in development just as it currently logs the link.

The code email must not render the web magic-link URL as the primary call to action. It should include:

- subject: `Your Maraithon sign-in code`
- heading: `Sign in to Maraithon`
- intro telling the user to enter the code in the mobile app
- prominent code block
- 15-minute expiry line
- safety line

### 7.2 Mobile API

`POST /api/mobile/auth/magic-link`

- Keep path for app compatibility.
- Internally call `Accounts.request_magic_code/2`.
- Send code email.
- Return JSON:

```json
{
  "magic_code": {
    "email": "user@example.com",
    "expires_in_seconds": 900,
    "delivery": "email_code"
  },
  "magic_link": {
    "email": "user@example.com",
    "expires_in_seconds": 900,
    "delivery": "email_code"
  }
}
```

`magic_link` remains as a compatibility alias for older app decoding; new code should prefer `magic_code`.

`POST /api/mobile/auth/magic-code`

Request:

```json
{ "code": "ABCD-2345" }
```

Success response:

```json
{
  "session_token": "<plaintext session token>",
  "user": {
    "id": "user@example.com",
    "email": "user@example.com",
    "session_expires_at": "<iso8601>"
  }
}
```

Error response:

```json
{ "error": "invalid_or_expired_code" }
```

## 8. iOS Changes

### 8.1 Auth Models and Provider

- Keep the existing `AuthProviding` shape unless a small signature change is required.
- `ProductionMagicAuthProvider.requestMagicLink` continues to request email delivery but treats the response as a code request.
- `ProductionMagicAuthProvider.consumeMagicLink` should route short code-looking input to `MobileAPIClient.consumeMagicCode`.
- Link URLs should remain supported for compatibility by extracting the token and calling the existing token consume route.
- `MagicLinkRequest` should include optional development code fields for local/debug flows.

### 8.2 Signed-Out UI

- Replace user-visible "link" copy with "code" copy.
- Primary action label: `Email Me a Code`.
- Pending state heading: `Check your email`.
- Pending copy: `We sent a one-time code to <email>. Codes expire in 15 minutes.`
- Entry placeholder: `Enter sign-in code`.
- Use `.textContentType(.oneTimeCode)` where appropriate.
- Development local flow should show the development code and a button to use it.

## 9. Failure Modes and Backward Compatibility

| Case | Behavior |
|---|---|
| Invalid email | `422 {"error":"invalid_email"}`; app shows existing invalid-email copy. |
| Invalid code | `401 {"error":"invalid_or_expired_code"}`; app shows invalid/expired code copy. |
| Expired code | Same as invalid code. |
| Reused code | Same as invalid code. |
| Legacy mobile token | Existing `/api/mobile/auth/magic/:token` remains valid. |
| Web login | Existing `/auth/magic-link` and `/auth/magic/:token` stay link-based. |
| Email delivery failure | Mobile request returns existing bad gateway behavior if delivery fails materially; log-only development remains `:ok`. |

## 10. Verification Loop

The production mobile verification loop must be changed from token injection to code injection:

1. Fly release eval calls `Maraithon.Accounts.request_magic_code/2`.
2. Helper extracts a code matching the display format.
3. UI test passes `MARAITHON_MAGIC_CODE` into the test process.
4. App launch support consumes `MARAITHON_UI_TEST_MAGIC_CODE`.
5. The simulator reaches the signed-in app shell.
6. The script performs the existing Todo, People, and Chat production assertions.
7. The assertion session is acquired through `POST /api/mobile/auth/magic-code`.

## 11. Test Plan and Validation Matrix

| Area | Required validation |
|---|---|
| Migration/schema | `user_magic_links.code_hash` exists and schema compiles. |
| Accounts | Code request returns formatted code; code consume creates session; code is single-use; expired/malformed code fails. |
| Email template | Code template includes code, expiry, and no `/auth/magic/` URL. |
| Mobile controller | Request endpoint stores a code hash and returns code delivery metadata; code endpoint signs in; invalid code returns `401`. |
| Web controller | Existing web magic-link tests still pass. |
| iOS parser/provider | Code normalization accepts `XXXX-XXXX`, spaces, and lowercase; local provider signs in with code and rejects reuse/expiry. |
| iOS UI | Signed-out copy and fields reference codes, not links. |
| Verification loop | Production script and UI test consume code env vars and use code endpoint for assertion session. |
| Project gates | Run targeted Phoenix tests, targeted iOS tests/build where practical, `mix precommit` or record blocker. |

## 12. Definition of Done

- Spec and lifecycle manifest are saved in `docs/spectacula`.
- Backend supports mobile code request/consume without breaking web magic links.
- Mobile email content sends a copyable code instead of a magic sign-in link.
- iOS login flow requests and consumes codes.
- Production verification loop exercises the code path.
- Relevant backend and iOS tests pass, or blockers are recorded.
- Final self-review confirms implementation matches this spec.

## 13. Assumptions

| Assumption | Impact |
|---|---|
| A high-entropy 8-character non-ambiguous code is acceptable for v1. | Avoids adding rate limiting in this change while staying copyable. |
| Keeping route name `/auth/magic-link` for request compatibility is acceptable. | Existing app request code can evolve without breaking older clients immediately. |
| Plain `$spectacula` invocation means final vetting is off. | The required loop is implementation self-review plus project verification, not an extra reviewer gate. |
