# Production Mobile Simulator Verification Loop Specification

Status: Complete
Purpose: Prove the native SwiftUI app can sign in to production and create/update production Todos and CRM people through the iOS Simulator.
Audience: Engineering.

## 1. Scope

- Use the production Maraithon app at `https://maraithon.com`.
- Authenticate as `kent@runner.now` with the same magic-link/session contract used by web.
- Avoid mailbox dependency by generating a real production magic-link token through the Fly release runtime.
- Run the native iOS app in Simulator and consume that token through a DEBUG-only launch environment hook.
- Create and modify a Todo from the app.
- Create and modify a CRM person from the app.
- Assert the resulting production records through the public mobile API with a fresh production session.

## 2. Implementation Contract

| Area | Decision |
|---|---|
| Repeatable entry point | `scripts/verify-production-simulator.sh` runs the full loop. |
| Token generation | Fly SSH release eval starts only Repo dependencies, then calls `Maraithon.Accounts.request_magic_link/2`. |
| Simulator auth | UI tests pass `MARAITHON_UI_TEST_MAGIC_TOKEN` to the app. |
| State reset | DEBUG-only app code clears persisted auth and local SwiftData before UI test launch. |
| UI automation | XCUITest creates a Todo, marks it done, creates a person, edits notes, and waits for native UI confirmation. |
| Server assertion | Script gets a fresh API session and verifies exact Todo/person records by unique run id. |

## 3. Definition of Done

- `xcodegen generate` succeeds.
- Simulator UI test signs in with a real production token.
- Production Todo is created and updated to `done`.
- Production CRM person is created and has updated notes.
- Script exits non-zero on any missing dependency, app failure, auth failure, or production assertion failure.

## 4. Completion Notes

- Deployed production release `v521` for Fly app `maraithon`, which includes `/api/mobile` routes.
- Verified direct production magic-token consumption returns a session for `kent@runner.now`.
- Ran `scripts/verify-production-simulator.sh` successfully with run id `20260526005817`.
- The successful loop signed in on iOS Simulator, created `iOS prod todo 20260526005817`, marked it `done`, created `iOS Prod Person 20260526005817`, updated its notes, and confirmed both records through `https://maraithon.com/api/mobile`.
- Verified production sign-up semantics with `mobile-signup-20260526010141@runner.now`; consuming a fresh magic token created the account and returned a session.
