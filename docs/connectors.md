# Connectors

Connectors bridge external services to agents via webhooks.

### OAuth Account Model (Production)

OAuth-backed connectors are modeled as **connected accounts**, not just one token per provider.

- Supports multiple accounts per provider (for example multiple Google inboxes or multiple Slack workspaces).
- Each account has its own provider key (for example `google:you@example.com`, `slack:T12345`).
- Each account surfaces status in the UI (`connected`, `refresh required`, `disconnected`) with account-level `Reconnect` and `Disconnect`.
- Refresh failures that require user action are marked as `oauth_reauth_required`, short-circuited in token usage, and can trigger Telegram reconnect notifications with a direct link back to connectors.

Token refresh is handled as a first-class runtime service:

- Access tokens are refreshed proactively before expiry.
- Refresh token rotation is preserved when providers return new refresh tokens.
- Provider-side revocations (`invalid_grant`, revoked/expired refresh tokens) are detected and promoted to reconnect-required state.

### GitHub (Available)

```bash
# Configure webhook secret and optional admin OAuth app
export GITHUB_WEBHOOK_SECRET="your_secret"
export GITHUB_ACCESS_TOKEN="ghp_xxx" # optional fallback for outbound actions
export GITHUB_CLIENT_ID="your_oauth_app_client_id"
export GITHUB_CLIENT_SECRET="your_oauth_app_client_secret"
export GITHUB_REDIRECT_URI="https://your-domain.com/auth/github/callback"

# Create agent subscribed to a repo
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "Analyze new issues and suggest solutions.",
      "subscribe": ["github:owner/repo"]
    }
  }'

# Configure GitHub webhook:
# URL: https://your-domain.com/webhooks/github
# Content type: application/json
# Secret: your_secret
```

**Supported events**: `issue_opened`, `issue_closed`, `pr_opened`, `pr_merged`, `push`, `comment_created`, and more.

**Available tools**: `github_create_issue_comment` (prefers a stored user OAuth grant when `user_id` is provided)

### Google Calendar (Available)

```bash
# Configure Google OAuth
export GOOGLE_CLIENT_ID="your_client_id"
export GOOGLE_CLIENT_SECRET="your_client_secret"
export GOOGLE_REDIRECT_URI="https://your-domain.com/auth/google/callback"
export GOOGLE_CALENDAR_WEBHOOK_URL="https://your-domain.com/webhooks/google/calendar"

# User authorizes via OAuth
# Visit: /auth/google?scopes=calendar&user_id=user_123

# Create agent subscribed to user's calendar
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "Help me manage my schedule. Alert me about upcoming meetings.",
      "subscribe": ["calendar:user_123"]
    }
  }'
```

**Supported events**: `calendar_sync`, `calendar_event_created`, `calendar_event_updated`, `calendar_event_deleted`

### Gmail (Available)

```bash
# Additional config for Gmail (requires Cloud Pub/Sub)
export GOOGLE_PUBSUB_TOPIC="projects/your-project/topics/gmail-push"

# User authorizes via OAuth
# Visit: /auth/google?scopes=gmail&user_id=user_123
# Or both: /auth/google?scopes=calendar,gmail&user_id=user_123

# Create agent subscribed to user's email
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "Summarize important emails and flag urgent ones.",
      "subscribe": ["email:user_123"]
    }
  }'
```

**Supported events**: `email_sync`, `email_received`, `email_changed`

When used by `founder_followthrough_agent`, Gmail candidates are adjudicated with an LLM reasoning pass that explicitly filters out low-signal transactional receipts and keeps only unresolved, high-confidence commitments worth interrupting on.

### Google Contacts (Available via OAuth)

```bash
# Google Contacts uses the same Google OAuth app as Gmail/Calendar
# Visit: /auth/google?scopes=contacts&user_id=user_123
# Or connect all Google services at once:
# Visit: /auth/google?scopes=gmail,calendar,contacts&user_id=user_123
```

This stores an encrypted server-side Google grant with the `contacts.readonly` scope so future agent tools can read your contact graph without handling local tokens.

### Slack (Available)

```bash
# Configure Slack app
export SLACK_CLIENT_ID="your_client_id"
export SLACK_CLIENT_SECRET="your_client_secret"
export SLACK_REDIRECT_URI="https://your-domain.com/auth/slack/callback"
export SLACK_SIGNING_SECRET="your_signing_secret"

# Install app to workspace via OAuth
# Visit: /auth/slack?user_id=user_123

# Create agent subscribed to workspace
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "Monitor team discussions and summarize important updates.",
      "subscribe": ["slack:T01234567:C01234567"]
    }
  }'
```

**Supported events**: `message`, `message_changed`, `message_deleted`, `reaction_added`, `reaction_removed`, `app_mention`, `member_joined`, `member_left`

**Available tools**: `slack_post_message`

Slack OAuth stores both workspace bot access and user-scoped access (when granted) so agents can analyze channels and personal DMs without repeated reauthentication.

### Notaui MCP (Available)

```bash
# Configure Notaui OAuth client credentials
export NOTAUI_BASE_URL="https://api.notaui.com"
export NOTAUI_CLIENT_ID="your_notaui_client_id"
export NOTAUI_CLIENT_SECRET="your_notaui_client_secret"
export NOTAUI_SCOPE="tasks:read tasks:write projects:read projects:write tags:write"

# Pull + publish a Notaui task snapshot to PubSub
curl -X POST http://localhost:4000/api/v1/integrations/notaui/sync \
  -H "Content-Type: application/json" \
  -d '{
    "topic": "notaui:tasks",
    "filter": {"statuses": ["inbox", "available"], "limit": 50}
  }'

# Create an agent that reviews and acts on Notaui tasks
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "Review Notaui tasks, prioritize important ones, and complete tasks when done.",
      "subscribe": ["notaui:tasks"],
      "tools": ["notaui_list_tasks", "notaui_update_task", "notaui_complete_task"]
    }
  }'
```

**Available tools**: `notaui_list_tasks`, `notaui_update_task`, `notaui_complete_task`

### WhatsApp (Available)

```bash
# Configure WhatsApp (Meta Business API)
export WHATSAPP_VERIFY_TOKEN="your_verify_token"
export WHATSAPP_APP_SECRET="your_app_secret"
export WHATSAPP_ACCESS_TOKEN="your_access_token"
export WHATSAPP_PHONE_NUMBER_ID="your_phone_number_id"

# Create agent subscribed to WhatsApp messages
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "You are a helpful assistant. Respond to user messages.",
      "subscribe": ["whatsapp:1234567890"]
    }
  }'
```

**Supported events**: `message_received`, `image_received`, `audio_received`, `document_received`, `location_received`, `message_status`

### Linear (Available)

```bash
# Configure Linear OAuth
export LINEAR_CLIENT_ID="your_client_id"
export LINEAR_CLIENT_SECRET="your_client_secret"
export LINEAR_REDIRECT_URI="https://your-domain.com/auth/linear/callback"
export LINEAR_WEBHOOK_SECRET="your_webhook_secret"

# User authorizes via OAuth
# Visit: /auth/linear?user_id=user_123

# Create agent subscribed to Linear issues
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "When new issues are created, analyze them and suggest implementation plans.",
      "subscribe": ["linear:eng"]
    }
  }'
```

**Supported events**: `issue_created`, `issue_updated`, `issue_removed`, `comment_created`, `comment_updated`, `project_created`, `cycle_created`

**Available tools**: `linear_create_comment`, `linear_create_issue`, `linear_update_issue_state`

### Notion (OAuth Ready)

```bash
# Configure Notion public integration OAuth
export NOTION_CLIENT_ID="your_client_id"
export NOTION_CLIENT_SECRET="your_client_secret"
export NOTION_REDIRECT_URI="https://your-domain.com/auth/notion/callback"

# User authorizes via OAuth
# Visit: /auth/notion?user_id=user_123
```

Maraithon stores the resulting workspace token encrypted on the server and exposes it in the admin control center, even before dedicated Notion agent tools are added.

### Telegram (Available)

```bash
# Configure Telegram bot
export TELEGRAM_BOT_TOKEN="123456789:ABC..."
export TELEGRAM_WEBHOOK_SECRET="random_secret_string"

# Set webhook (call once). set_webhook includes TELEGRAM_WEBHOOK_SECRET as
# Telegram's secret_token, which Telegram returns in its dedicated header.
# Telegram.set_webhook("https://your-domain.com/webhooks/telegram")

# Create agent subscribed to Telegram messages
curl -X POST http://localhost:4000/api/v1/agents \
  -d '{
    "behavior": "prompt_agent",
    "config": {
      "prompt": "You are a helpful assistant. Respond to user messages.",
      "subscribe": ["telegram:123456789:-100123456"]
    }
  }'
```

Telegram ingress is intentionally narrow: only `POST /webhooks/telegram` is accepted, the request must contain exactly one matching `X-Telegram-Bot-Api-Secret-Token`, and authenticated requests must use a single valid `Content-Length` of at most 600 KB. HTTP/1 `Transfer-Encoding` is rejected before body parsing and every early rejection closes the connection. Accepted updates become permanent deduplicated receipts; work is executed durably in ascending update-id order per bot, and terminal receipts retain their identity while scrubbing event payloads.

`Telegram.set_webhook/2` always registers `max_connections: 1` and rejects unsafe concurrency overrides. That provider-side serialization is the ordering contract for update rows that do not yet exist in the database; a one-second `TELEGRAM_INGRESS_ORDERING_GRACE_MS` (configurable) additionally lets overlapping admitted requests become visible before claiming a per-bot head. Database head selection orders all visible receipts but, by itself, cannot prove that a lower unseen update will never arrive.

Durable domain checkpoints prevent retries from replaying committed feedback, todo, and prepared-action mutations; retries drain only missing result delivery or callback acknowledgement when that state is known. A delivered conversation turn also backs up the compact prepared-action delivery marker. Telegram `sendMessage` has no idempotency key, so provider acceptance followed by failure of the local turn write remains an inherent at-least-once partition: the receipt stays retryable and a duplicate Telegram message is possible rather than falsely recording success. The same boundary applies to a confirmed external action whose provider accepts work before its local executed checkpoint can commit when that provider offers no usable idempotency key.

Non-webhook JSON and urlencoded requests have independent 8 MiB compressed and inflated ceilings so Companion voice-memo batches can carry a high-entropy 5 MiB M4A after base64 encoding. Signed webhook connectors retain bounded wire bytes for signature verification; other routes do not retain a second raw copy.

**Supported events**: `message`, `photo`, `document`, `voice`, `video`, `location`, `callback_query`, `edited_message`, `member_joined`, `member_left`

### Connector Status

| Connector | Status | Topic Format |
|-----------|--------|--------------|
| GitHub | Available | `github:{owner}/{repo}` |
| Google Calendar | Available | `calendar:{user_id}` |
| Gmail | Available | `email:{user_id}` |
| Slack | Available | `slack:{team_id}:{channel_id}` |
| Notaui MCP | Available | `notaui:{stream}` (default `notaui:tasks`) |
| WhatsApp | Available | `whatsapp:{phone_number_id}` |
| Linear | Available | `linear:{team_key}` |
| Notion | OAuth Ready | N/A (grant stored for future tools) |
| Telegram | Available | `telegram:{bot_id}:{chat_id}` |
| Discord | Planned | `discord:{server}:{channel}` |

### Building Custom Connectors

```elixir
defmodule MyApp.Connectors.Custom do
  @behaviour Maraithon.Connectors.Connector

  @impl true
  def verify_signature(conn, raw_body) do
    # Verify webhook signature
  end

  @impl true
  def handle_webhook(conn, params) do
    # Parse webhook, return normalized event
    {:ok, "custom:topic", %{type: "event_type", ...}}
  end
end
```

