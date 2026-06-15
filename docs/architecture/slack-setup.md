# Slack Integration Setup

How to set up Maraithon's Slack integration so it can read channels (and DMs/MPIMs) **without inviting a bot to each channel**.

## How it works

Maraithon requests **both** bot scopes and user scopes during OAuth. Slack returns two tokens:

- `access_token` (top-level) — bot token (`xoxb-…`), used for posting and Events API
- `authed_user.access_token` — user token (`xoxp-…`), used for reading

API calls made with the user token act **as the authorizing user**, so they succeed in any channel/DM/MPIM that user is already a member of. No bot invite required.

The token resolver (`Maraithon.Tools.SlackHelpers.resolve_access_token/3`) defaults to `token_preference: :auto`, which tries the user token first and falls back to the bot token.

### Where this is wired up

| File | Role |
|------|------|
| `lib/maraithon/oauth/slack.ex` | OAuth helpers; declares `@default_scopes` (bot) + `@default_user_scopes` (user); parses `authed_user.access_token` from the token response |
| `lib/maraithon_web/controllers/oauth_controller.ex` | `slack/2` initiates auth; `slack_callback/2` → `store_slack_user_token/2` persists the user token under provider `slack:{team_id}:user:{authed_user_id}` |
| `lib/maraithon/tools/slack_helpers.ex` | `resolve_access_token/3` — picks user token first, falls back to bot |
| `lib/maraithon/tools/slack_*.ex` | Read tools (`list_messages`, `list_conversations`, `get_thread_replies`, `search_messages`) all run through the user token by default |
| `lib/maraithon/connectors/slack.ex` | Events API webhook (push events from Slack); uses bot scopes |
| `config/runtime.exs` | Reads `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET`, `SLACK_REDIRECT_URI`, `SLACK_SIGNING_SECRET` |

## One-time setup

### 1. Create a Slack app

Go to <https://api.slack.com/apps> → **Create New App** → **From scratch**.

### 2. Configure OAuth & Permissions

Under **OAuth & Permissions**:

**Redirect URL** (must match `SLACK_REDIRECT_URI`):
```
https://maraithon.com/auth/slack/callback
```

**Bot Token Scopes** (Events API + posting):
```
app_mentions:read
channels:history
channels:read
chat:write
groups:history
groups:read
im:history
im:read
mpim:history
mpim:read
reactions:read
users:read
```

**User Token Scopes** (read-as-user — the part that avoids bot invites):
```
channels:history
channels:read
groups:history
groups:read
im:history
im:read
mpim:history
mpim:read
search:read
users:read
```

These match `@default_scopes` and `@default_user_scopes` in `lib/maraithon/oauth/slack.ex`. If you change the lists in code, mirror the change in the Slack app config and have users re-authorize.

### 3. (Optional) Configure Event Subscriptions

If you want Slack to push events to Maraithon:

- **Request URL:** `https://maraithon.com/webhooks/slack`
- **Subscribe to bot events:** `message.channels`, `message.groups`, `message.im`, `message.mpim`, `app_mention`, `reaction_added`, `reaction_removed`, `member_joined_channel`, `member_left_channel`

Slack will hit the URL with a `url_verification` challenge first; `Maraithon.Connectors.Slack.handle_webhook/2` handles it.

### 4. Set environment variables

From the Slack app's **Basic Information** page, copy Client ID, Client Secret, and Signing Secret.

```bash
fly secrets set \
  SLACK_CLIENT_ID=<client_id> \
  SLACK_CLIENT_SECRET=<client_secret> \
  SLACK_REDIRECT_URI=https://maraithon.com/auth/slack/callback \
  SLACK_SIGNING_SECRET=<signing_secret>
```

Local dev: put the same values in your dev env (e.g. `.env`).

### 5. Install to a workspace

Open in a browser:

```
https://maraithon.com/auth/slack?user_id=<maraithon_user_id>
```

This hits `OAuthController.slack/2`, redirects to Slack consent, comes back to `/auth/slack/callback`, and `store_slack_user_token/2` persists the user token.

## Verifying

After install, the user should have two stored tokens:

- `slack:{team_id}` — bot token
- `slack:{team_id}:user:{authed_user_id}` — user token

The Slack read tools (`SlackListMessages`, etc.) call `resolve_access_token` with `token_preference: :auto`, which selects the user token by default. A successful read against a channel the bot is not in confirms the user-token path is working.

## Forcing a specific token

Tools accept an optional `token_preference` arg:

- `"user"` — use only the user token (errors with `slack_user_scope_not_connected` if missing)
- `"bot"` — use only the bot token
- `"auto"` (default) — user first, then bot

Pass `slack_user_id` to disambiguate when a Maraithon user has installed Slack to multiple workspaces or multiple personal accounts.
