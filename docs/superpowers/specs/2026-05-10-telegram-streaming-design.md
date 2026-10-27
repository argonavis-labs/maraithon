# Token streaming: OpenAI Responses API → Telegram progress message

**Date:** 2026-05-10
**Status:** approved, ready for implementation plan
**Goal:** drive perceived Telegram round-trip latency from ~19s to <2s by streaming the assistant's text into the existing progress message as the model writes it.

## Problem

A typical Telegram round-trip today: webhook → ~4s pre-LLM context build → 3 sequential `Calling OpenAI Responses API` calls (3s + 4s + 5s for a tool loop) → final delivery. Total ~19s. Users see no motion until the very end.

`OpenAIProvider.complete/1` blocks on the full response. `LivenessSession` already edits a progress message during tool runs, but only with coarse "checking Gmail…" hints — never with model output.

## Decision summary

- **Stream target:** edit the existing `progress_message_id` in place. One bubble morphs from progress hints into the final answer.
- **Flush cadence:** time-throttled at ~1s between Telegram edits, plus a final flush.
- **Markdown:** plain text mid-stream (parse_mode=nil), MarkdownV2 on the final flush.
- **Architecture:** extend `LivenessSession` as the stream sink — it already owns `progress_message_id` and timer scaffolding, so a single owner avoids races.

## Components

### `Maraithon.LLM.Adapter` — add optional callback

```elixir
@callback stream_complete(params(), on_chunk :: (String.t() -> any())) ::
            {:ok, response()} | {:error, term()}

@optional_callbacks stream_complete: 2
```

Providers that don't implement it fall through to `complete/1`.

### `Maraithon.LLM.OpenAIProvider.stream_complete/2`

- Same request body as `complete/1` plus `stream: true`.
- Use `Req.post(into: collector_fn)` to consume Server-Sent Events.
- For each `response.output_text.delta` event with a `delta` field, invoke `on_chunk.(delta)`.
- Accumulate the full text + usage from the terminal `response.completed` event.
- Return the same shape as `complete/1` so callers don't branch.

Errors: stream connection drop returns `{:error, {:network_error, reason}}`; HTTP 4xx/5xx mapped same as `complete/1`.

### `Maraithon.TelegramAssistant.Client.LLMJson`

- New `next_step/1` codepath that, when `runtime_context[:run_id]` is set, calls `OpenAIProvider.stream_complete/2` with a callback that does:
  ```elixir
  fn delta -> LivenessSession.stream_chunk(run_id, delta) end
  ```
- Tool-call turns and final-text turns both go through the same path. Text deltas are usually empty on tool-call turns, so the cast no-ops naturally.
- Feature-flag fallback: when `Application.get_env(:maraithon, :openai)[:stream_replies]` is false, call `complete/1` instead.

### `Maraithon.TelegramAssistant.LivenessSession` — additions

New state keys:
- `stream_buffer :: String.t()` (default `""`)
- `stream_flush_timer_ref :: reference() | nil`
- `stream_last_flushed_at_ms :: integer() | nil`
- `stream_active? :: boolean` (default `false`)

New API:
- `stream_chunk(run_id, delta) :: :ok` — cast.
- `stream_complete(run_id, final_markdown) :: :ok` — final flush with MarkdownV2.

Behaviour:
- `handle_cast({:stream_chunk, delta}, state)`:
  - Append delta to `stream_buffer`. Set `stream_active? = true`.
  - If no `progress_message_id` yet, send a placeholder ("…") and capture the message_id.
  - If `stream_flush_timer_ref` is nil, schedule `:flush_stream` at `min(now + 1000ms, stream_last_flushed_at_ms + 1000ms)`.
- `handle_info(:flush_stream, state)`:
  - Edit `progress_message_id` with `stream_buffer` as plain text (parse_mode: nil).
  - Update `stream_last_flushed_at_ms`. Clear timer ref.
  - On 429: skip this flush (next chunk will reschedule with the larger buffer).
  - On any other error: log and skip.
- `handle_cast({:stream_complete, final_markdown}, state)`:
  - Cancel any pending flush timer.
  - Edit `progress_message_id` with `final_markdown` rendered as MarkdownV2.
  - Set `stream_active? = false`. Clear `stream_buffer`.
- Coordinate with the existing tool-hint progress edits: `maybe_refresh_progress_message` becomes a no-op while `stream_active?` is true. Once tokens are arriving, status hints stop overwriting them.

## Data flow

```
Telegram webhook
  → runner.run_loop
  → client.next_step(payload, run_id)
       → openai_provider.stream_complete(params, on_chunk)
            ↓ (per SSE delta)
            on_chunk.(delta)
              → LivenessSession.stream_chunk(run_id, delta)
                   → buffer + schedule throttled flush
       ← {:ok, full_response}
  → runner.handle_llm_response
  → if final turn:
       LivenessSession.stream_complete(run_id, markdown_text)
         → final MarkdownV2 edit
  → if tool turn: continue loop
```

## Error handling

| Failure | Behaviour |
|---|---|
| Telegram 429 on edit | Skip this flush; next chunk reschedules with larger buffer |
| Telegram 400 mid-stream edit | Should not occur with parse_mode=nil; logged + skipped if it does |
| Telegram 400 on final MarkdownV2 edit | Falls back to plain text (existing behaviour in delivery path) |
| OpenAI stream drops mid-response | `stream_complete/2` returns `{:error, ...}`; runner uses existing retry/error path; buffer left intact for visibility |
| `stream_replies` flag off | Client falls back to `complete/1`; behaviour matches today |
| Tool-call turn with text deltas | Streams normally; once tool_calls fire, existing tool-hint UX takes over after `stream_active?` resets |

## Feature flag

```elixir
# config/runtime.exs
config :maraithon, :openai, stream_replies: System.get_env("OPENAI_STREAM_REPLIES", "true") == "true"
```

Default true. Set `OPENAI_STREAM_REPLIES=false` to disable instantly without redeploy of the provider code.

## Testing

- **Unit: `Maraithon.LLM.OpenAIProviderTest`** — `stream_complete/2` against a `Bypass` server emitting hand-crafted SSE events. Assert callback invoked per delta; final return shape matches `complete/1`.
- **Unit: `Maraithon.TelegramAssistant.LivenessSessionTest`** — `stream_chunk` casts buffer correctly; flush timer schedules at ~1s; final flush uses MarkdownV2; concurrent tool-hint edits no-op while streaming.
- **Integration: `MaraithonWeb.TelegramStreamingIntegrationTest`** — feed a real-ish SSE fixture through the provider into a stub Telegram client, assert that the number of `edit_message_text` calls is ≤ ⌈stream_duration_ms / 1000⌉ + 1.
- **Smoke (post-deploy):** send a Telegram message, confirm tokens visibly appear in <2s.

## Out of scope (explicit)

- Streaming intermediate tool-emitting turns when they have text (lands in same buffer; refine later if it produces incoherent UX).
- Anthropic provider streaming — no Anthropic provider in prod path.
- Reasoning-text streaming (`output_reasoning.delta`) — Maraithon doesn't render reasoning today.

## Why this is the smallest change

- Provider gains one optional function. Client gains one branch behind a flag. LivenessSession gains ~150 lines but no new processes or supervisors.
- The runner doesn't change at all (it already passes `runtime_context.run_id` through the client).
- Telegram I/O stays in `LivenessSession` — no second writer to `progress_message_id`, no race conditions.
- Falls back to today's behaviour with one config toggle.
