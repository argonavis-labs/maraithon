# Apple Reviewer Bypass Credentials

## Context

App Store submission `a581df1c-c520-4ccb-9bd7-17733cb6226e` (build `202606090100`)
was rejected on **June 11, 2026** under **Guideline 2.1 — Information Needed**:

> We were unable to sign in with the following demo account credentials you
> provided in App Store Connect:
> User name: reviewer@maraithon.com
> Password: [redacted App Review code]

This is the only blocker. The reviewer never reached app functionality. They saw
the sign-in screen, entered the App Store Connect credentials, and could not get
past it. The newer build `20260612050845` is already processed and valid but
will fail review for the same reason unless this is fixed.

## Why the reviewer can't sign in

Maraithon mobile auth is magic-link only (`lib/maraithon/accounts.ex`,
`lib/maraithon_web/controllers/mobile_auth_controller.ex`):

1. User enters email → `POST /api/mobile/auth/magic-code` →
   `Accounts.request_magic_code/2` mints an 8-char code and Postmark emails it.
2. User enters code → `POST /api/mobile/auth/magic-code/consume` →
   `Accounts.consume_magic_code/2` mints a session.

There is no password field anywhere. The password/code listed in App Store
Connect is not wired to anything in code, and `reviewer@maraithon.com` is not a
deliverable mailbox — even if Apple's reviewer typed it correctly, Postmark
would either bounce or silently drop the code. The reviewer is stuck on the
email-code screen with no way to receive a code.

This is the standard failure mode for magic-link apps under Guideline 2.1. The
fix is a deterministic bypass for one well-known reviewer identity.

## Goal

Apple's reviewer can sign into Maraithon by entering exactly the credentials
listed in App Store Connect, with no email round-trip, no special build, and no
risk of the bypass being exploitable by anyone else.

## Non-goals

- General password auth. The product stays magic-link.
- A "demo mode" or sandboxed account. The reviewer logs in as a real user with a
  real (seeded) account so they can see every feature.
- Multiple reviewer accounts. One is enough; rotate the code if it ever leaks.

## Design

### Reviewer identity

- Email: `reviewer@maraithon.com` (already in App Store Connect, do not change)
- Bypass code: same value already in App Store Connect; treat it as the magic
  code, not a password. Do not commit the cleartext value.

Both values move into runtime config so they can be rotated without a redeploy:

```elixir
# config/runtime.exs (prod)
config :maraithon, :app_review_bypass,
  email: System.get_env("APP_REVIEW_BYPASS_EMAIL"),
  code:  System.get_env("APP_REVIEW_BYPASS_CODE")
```

Set both env vars on Fly. Leave them unset in dev/test — the bypass MUST no-op
unless both are present.

### Backend changes

**`lib/maraithon/accounts.ex`**

1. Add `bypass_config/0` returning `{:ok, %{email, code_hash}}` or `:disabled`.
   `code_hash` uses the same `hash_token/1` already in this module so we never
   keep the cleartext code in memory after boot.
2. In `request_magic_code/2`, if the email matches the configured bypass email
   (case-insensitive, after `normalize_email/1`):
   - Skip the `MagicLink` insert.
   - Return `{:ok, %{user: reviewer_user, code: :bypass, expires_at: ...}}`.
   - `reviewer_user` is created via `get_or_create_user_by_email/1` on first
     hit so the reviewer has a real `User` row, person records, etc.
3. In `consume_magic_code/2`, before the existing DB lookup:
   - Normalize the input with the existing `normalize_magic_code/1`.
   - If `bypass_config/0` is enabled and the normalized code's hash matches
     `code_hash`, look up the bypass user via `get_user_by_email/1` and call
     `create_session_for_user/2`.
   - Return the same `{:ok, %{user, token, session}}` shape the real path
     returns so the controller and mobile client need zero changes.

**`lib/maraithon_web/controllers/mobile_auth_controller.ex`**

- `create_magic_link/2`: if `Accounts.request_magic_code/2` returns
  `code: :bypass`, skip `MagicLinkSender.deliver_code/2` and return the normal
  success payload (`delivery: "email_code"`, same `expires_in_seconds`). The
  reviewer sees the standard "we sent you a code" screen and types the code
  from App Store Connect.

That's it. No new routes, no new controllers, no client changes.

### Reviewer account seeding

The reviewer's session should land them in a populated account, not an empty
shell, so they can actually see Today / Work / People / Chat working.

Add a Mix task `mix maraithon.seed_reviewer` that:

- Calls `get_or_create_user_by_email("reviewer@maraithon.com")`.
- Seeds a small representative dataset: ~5 People (mixed family/colleagues/
  clients), ~3 Projects, ~10 commitments across Today/Work, ~6 prior chat
  messages with assistant replies, and one morning briefing already generated.
- Idempotent: if the data already exists (matched by stable IDs prefixed
  `reviewer-seed-`), it updates in place instead of duplicating.

Run it once after deploy. Do not run on every boot.

### Notes field in App Store Connect

Update the "Notes" field on the version submission with one short paragraph so
the reviewer doesn't have to guess at the flow:

> Sign in with the credentials above. The app uses email-based magic codes;
> the password you have IS the code. Enter the email on the first screen,
> tap continue, then paste the code on the next screen. The seeded account
> includes sample data across Today, Work, People, and Chat so you can
> exercise every feature.

## Safety

- Bypass is disabled unless BOTH env vars are present. CI tests assert that
  with neither set, `request_magic_code/2` for the reviewer email goes through
  the normal Postmark path (i.e., we do not silently bypass).
- Bypass code is rotated by changing the env var. No DB migration needed.
- Code is stored as a hash in the running process; cleartext only lives in the
  env var.
- Rate-limit `consume_magic_code/2` for the bypass path the same as any other
  code so a leaked code can't be brute-forced (the 8-char alphabet already
  gives ~10^12 keyspace, but keep the existing rate limit).
- The reviewer user is a real user with `is_admin: false`. Do not promote.

## Tests

`test/maraithon/accounts_test.exs`:

1. `request_magic_code/2` for the bypass email with bypass enabled returns
   `code: :bypass` and inserts no `MagicLink` row.
2. `consume_magic_code/2` with the bypass code returns a valid session for the
   reviewer user.
3. With bypass disabled (no env vars), both calls fall through to the normal
   path — reviewer email goes through Postmark, reviewer code is rejected as
   `:invalid_or_expired_code`.
4. A non-reviewer email plus the bypass code is rejected — the code is only
   valid in combination with the bypass user lookup.

`test/maraithon_web/controllers/mobile_api_controller_test.exs`:

1. End-to-end: `POST /api/mobile/auth/magic-code` with the reviewer email
   returns 200 without invoking Postmark (assert via Mox or a delivery spy).
2. `POST /api/mobile/auth/magic-code/consume` with the bypass code returns a
   session token.

## Deploy + resubmit checklist

1. Implement backend changes + tests on a branch.
2. Merge, deploy backend to prod with `APP_REVIEW_BYPASS_EMAIL` and
   `APP_REVIEW_BYPASS_CODE` set.
3. Run `mix maraithon.seed_reviewer` against prod.
4. Manually verify on the **prod** mobile build (`20260612050845`) that the
   credentials in App Store Connect actually sign in and surface seeded data.
5. In App Store Connect → App Review → the rejected submission:
   - Reply to the reviewer message with one sentence: "Demo account is now
     working — same credentials. Thanks."
   - Update the "Notes" field with the paragraph above.
   - Confirm `20260612050845` is selected as the build for the version.
6. Tap **Resubmit to App Review**.

## Files touched

- `config/runtime.exs` — new `:app_review_bypass` block.
- `lib/maraithon/accounts.ex` — `bypass_config/0`, branches in
  `request_magic_code/2` and `consume_magic_code/2`.
- `lib/maraithon_web/controllers/mobile_auth_controller.ex` — skip
  `MagicLinkSender.deliver_code/2` when `code: :bypass`.
- `lib/mix/tasks/maraithon.seed_reviewer.ex` — new seed task.
- `test/maraithon/accounts_test.exs` — bypass tests.
- `test/maraithon_web/controllers/mobile_api_controller_test.exs` — controller
  tests.

No mobile (`apps/mobile/`) changes.
