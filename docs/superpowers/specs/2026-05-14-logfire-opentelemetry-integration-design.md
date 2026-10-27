---
status: design
date: 2026-05-14
---
# Logfire / OpenTelemetry Integration — Design

## Context & goal

The long-term goal is for Maraithon to **diagnose (and eventually fix) itself by
inspecting its own telemetry**. That is a pipeline of independent subsystems:

1. **Observe** — rich, queryable telemetry exists. *(this spec)*
2. **Access** — the app can query its own telemetry programmatically (Logfire API/SQL).
3. **Diagnose** — an agent/skill correlates traces and errors into root-cause reports.
4. **Fix** — diagnosis drives an implementation run / PR against the `maraithon` repo.

This spec covers **only sub-project 1**. Sub-projects 2–4 are deferred; the user
("Kent") will drive resolution manually from the Logfire UI for now. Each later
sub-project gets its own spec → plan → implementation cycle.

The decisive motivation: today the app's most important failures never reach the
logs at all. The Telegram run that produced "I hit an internal issue…" failed with
`:assistant_harness_empty_tool_calls`, but `Runner.handle_run_failure/4`
(`lib/maraithon/telegram_assistant/runner.ex:357`) persists the reason to the DB
and **never logs it**. `fly logs` showed no trace of the failure — the root cause
was only recoverable by querying the production `telegram_assistant_runs` table.
You cannot diagnose from logs that do not exist. This integration closes that gap
by making failures first-class span events.

## Scope decision

**In scope:** distributed traces + custom spans, exported via OTLP/HTTP to Logfire.

**Out of scope (deliberately):** forwarding Elixir `Logger` output as OTel logs
(the Elixir OTel logs handler is still experimental), and piping `telemetry_metrics`
to OTLP. The existing `Maraithon.LogFormatter` / `Maraithon.LogBuffer` pipeline is
untouched. If traces alone prove insufficient for diagnosis, error-level log
forwarding is the natural Phase 1.5.

## Approach

Logfire has **no native Elixir SDK** (`pydantic/logfire` is the Python SDK), but
Logfire is fully OpenTelemetry-native. The integration is the standard Elixir
OpenTelemetry stack with the OTLP exporter pointed at Logfire's ingest endpoint.

**Opt-in by token presence.** When `LOGFIRE_WRITE_TOKEN` is unset (default in dev
and test), `traces_exporter` stays `:none` — nothing is exported, no overhead, no
test changes. Setting the secret in production turns it on. Dev can opt in via a
local `.env` token.

## Components

### 1. Dependencies (`mix.exs`)

Add (verify latest at implementation time; versions are a floor):

- `opentelemetry_api ~> 1.5`
- `opentelemetry ~> 1.7`
- `opentelemetry_exporter ~> 1.10`
- `opentelemetry_phoenix ~> 2.0`
- `opentelemetry_bandit ~> 0.3` — this app runs Bandit (`bandit ~> 1.5`), **not** Cowboy
- `opentelemetry_ecto ~> 1.2`

### 2. Static config (`config/config.exs`)

```elixir
config :opentelemetry,
  traces_exporter: :none,
  resource: %{service: %{name: "maraithon"}}
```

Default off everywhere; `runtime.exs` flips it on when a token is present.

### 3. Runtime config (`config/runtime.exs`)

```elixir
if logfire_token = System.get_env("LOGFIRE_WRITE_TOKEN") do
  config :opentelemetry,
    traces_exporter: :otlp,
    span_processor: :batch

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: System.get_env("LOGFIRE_ENDPOINT", "https://logfire-us.pydantic.dev"),
    otlp_headers: [{"authorization", logfire_token}]
end
```

Notes:
- `otlp_endpoint` is a **base URL**; the exporter appends `/v1/traces`. Do not
  include the path.
- The auth header is the **raw write token with no `Bearer ` prefix** — this is
  Logfire-specific; third-party blog posts that prepend `Bearer` are wrong.
- `LOGFIRE_ENDPOINT` is overridable for region flexibility (default US region).
- `LOGFIRE_WRITE_TOKEN` is provisioned via `fly secrets set` in production and a
  local `.env` for dev. Never committed.

### 4. Application setup (`lib/maraithon/application.ex`)

Instrumentation setup runs at the top of `start/2`, **before**
`Supervisor.start_link/2`, so `:telemetry` handlers are attached before the first
request:

```elixir
def start(_type, _args) do
  OpentelemetryBandit.setup()
  OpentelemetryPhoenix.setup(adapter: :bandit)
  OpentelemetryEcto.setup([:maraithon, :repo])

  children = [ ... ]
  Supervisor.start_link(children, opts)
end
```

Order matters: `OpentelemetryBandit.setup()` **before** `OpentelemetryPhoenix.setup/1`,
otherwise the parent HTTP span can be dropped. This is a no-op for traces when the
exporter is `:none`, so it is safe to run unconditionally in all environments.

### 5. `Maraithon.Tracing` helper

A thin module wrapping the OTel tracer macros so the rest of the codebase has one
small, testable interface and is insulated from OTel API churn.

- `with_span(name, attributes, fun)` — opens a span, runs `fun`, sets attributes,
  records exceptions, returns `fun`'s result unchanged.
- `record_error(reason)` — sets the current span status to error and attaches the
  reason as a span event/attribute.
- When OTel is disabled (no exporter), the macros are effectively no-ops; the
  helper must still return the inner value unchanged and never raise.

### 6. Custom spans on the Telegram assistant hot path

The auto-instrumentation (Phoenix/Bandit/Ecto) covers all HTTP and DB activity.
Custom spans add the assistant reasoning loop — the exact area that is currently
un-diagnosable:

- `TelegramAssistant.Runner.run_inbound/1` — one root span per run. Attributes:
  `run_id`, `chat_id`, `conversation_id`, `trigger_type`.
- `Runner.run_loop/4` — span per LLM request iteration. Attributes: `iteration`,
  `llm_turns`, `model`.
- `Runner.run_single_tool_call/4` — span per tool call. Attributes: tool name,
  `ok` / `error` outcome.
- LLM provider HTTP calls (`AnthropicProvider`, `OpenAIProvider`) — span around the
  request. Attributes: `provider`, `model`, token usage, HTTP status.
- **Failure recording:** in `Runner.handle_run_failure/4` and the `run_loop`
  `{:error, run, reason, state}` path, call `Tracing.record_error/1` with the
  `reason`. This is the core gap-closer — `:assistant_harness_empty_tool_calls`
  and friends become visible in Logfire without depending on stdout logs.

## Error handling

- The integration is fail-open: a missing/invalid token, an unreachable Logfire
  endpoint, or exporter errors must never affect request handling. The batch span
  processor isolates export from the request path; exporter failures are logged by
  the OTel library and dropped.
- `Maraithon.Tracing` never raises into caller code — a span failure must not
  convert a working code path into a failing one.

## Testing

- Test env has no `LOGFIRE_WRITE_TOKEN`, so the exporter is `:none` — no telemetry
  is sent and no existing test changes.
- `setup` calls in `application.ex` run in test but are inert with the exporter
  off; assert the app still boots.
- Unit tests for `Maraithon.Tracing`:
  - `with_span/3` returns the inner function's value unchanged.
  - `with_span/3` is a clean no-op (no raise) when OTel is disabled.
  - `record_error/1` does not raise when there is no active span.
- `mix precommit` (formatter + credo + tests) passes.

## Verification

- `mix precommit` green.
- Boot the app locally with a real `LOGFIRE_WRITE_TOKEN` set, exercise a Telegram
  message, and confirm traces (HTTP → assistant run → LLM call → tool calls) and a
  deliberately-failed run appear in the Logfire UI with the error reason attached.
