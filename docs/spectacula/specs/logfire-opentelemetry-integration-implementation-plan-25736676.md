---
created_at: 2026-05-14T18:57:48Z
created_by: cybrus
cybrus_task_id: 25736676-4F6A-4007-869B-0D8322CA9479
project: Maraithon App
status: done
---
# Logfire / OpenTelemetry Integration Implementation Plan

Status: Done
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 25736676-4F6A-4007-869B-0D8322CA9479
- Workflow: WORKFLOW.md

## Dependencies

- None

## Notes

No additional notes were attached to this task.

## Workflow Context

Deterministic Cybrus configuration:
- Execution mode: local Codex CLI with full local workspace access.
- Task source: Orchestrator/Cybrus task queue.
- Workflow file: WORKFLOW.md
- Workflow file found: no
- Human handoff: produce proof of work, then Cybrus writes a local review packet.

Repository workflow instructions:
No repository workflow instructions were found. Use the existing codebase conventions.

## Objective

Export diagnostic-quality distributed traces from Maraithon to Pydantic Logfire via OpenTelemetry. Standard Elixir OTel auto-instrumentation covers Phoenix/Bandit/Ecto; a thin `Maraithon.Tracing` wrapper adds hand-rolled spans on the Telegram assistant hot path and the LLM provider HTTP calls, with explicit failure recording so silent runner failures (e.g. `:assistant_harness_empty_tool_calls`) become visible in Logfire.

Exporting is **opt-in by `LOGFIRE_WRITE_TOKEN` presence** — `traces_exporter: :none` in dev/test by default, so the integration is inert until a token is provisioned.

Spec: `docs/superpowers/specs/2026-05-14-logfire-opentelemetry-integration-design.md`

---

## Assumptions and Decisions

- **Opt-in export.** No token → `:none` exporter → all span code is a no-op that still returns wrapped values unchanged and never raises into caller code. This keeps dev/test green with zero config.
- **Logfire OTLP specifics.** Endpoint is a base URL (`https://logfire-us.pydantic.dev`); the exporter appends `/v1/traces`. Auth header is the **raw token with no `Bearer ` prefix** — Logfire-specific. Protocol is `http_protobuf`.
- **Scope of custom spans.** Only the assistant hot path and LLM provider HTTP calls are hand-instrumented — that is the currently un-diagnosable area. HTTP ingress and DB are left to auto-instrumentation.
- **Setup ordering matters.** `OpentelemetryBandit.setup()` must run before `OpentelemetryPhoenix.setup/1`, and both before the supervisor starts, so `:telemetry` handlers attach before the first request.
- **Attribute hygiene.** OTel attribute values must be primitives or lists of primitives; `Maraithon.Tracing` coerces atoms to strings and anything else via `inspect/1`.
- **Dep versions.** Use the `~>` ranges below; if hex resolution fails, bump to the latest published version and note the change in the PR.
- **Production secret is an operator action.** `fly secrets set LOGFIRE_WRITE_TOKEN=…` is documented in the PR description, not executed by the coding agent.
- **TDD for the wrapper.** `Maraithon.Tracing` is the only new module with branching logic, so it gets a unit test written first.

---

## Implementation Plan

### Task 1 — OpenTelemetry deps and static config
- Add to `mix.exs` `deps/0`, after `{:telemetry_poller, "~> 1.0"}`:
  `opentelemetry_api ~> 1.5`, `opentelemetry ~> 1.7`, `opentelemetry_exporter ~> 1.10`, `opentelemetry_phoenix ~> 2.0`, `opentelemetry_bandit ~> 0.3`, `opentelemetry_ecto ~> 1.2`.
- `mix deps.get` — resolve the six packages; bump versions if unavailable.
- Append to `config/config.exs` after the `LogBuffer` line:
  ```elixir
  config :opentelemetry,
    traces_exporter: :none,
    resource: %{service: %{name: "maraithon"}}
  ```
- `mix compile` clean; commit.

### Task 2 — Logfire OTLP exporter in runtime config
- Append to `config/runtime.exs` (outside any `:prod` guard) a block gated on `System.get_env("LOGFIRE_WRITE_TOKEN")` that sets `traces_exporter: :otlp`, `span_processor: :batch`, and configures `:opentelemetry_exporter` with `otlp_protocol: :http_protobuf`, `otlp_endpoint` (env-overridable, default `https://logfire-us.pydantic.dev`), and `otlp_headers: [{"authorization", token}]`.
- Verify: with token set, `otlp_endpoint` reads back correctly; without it, `traces_exporter` is `:none`. Commit.

### Task 3 — Auto-instrumentation in the supervisor
- At the top of `start/2` in `lib/maraithon/application.ex` (before `children = [`), add `OpentelemetryBandit.setup()`, `OpentelemetryPhoenix.setup(adapter: :bandit)`, `OpentelemetryEcto.setup([:maraithon, :repo])` — in that order.
- Verify app boots (`mix run --no-start`, plus one existing web test as smoke check). Commit.

### Task 4 — `Maraithon.Tracing` helper (TDD)
- Write `test/maraithon/tracing_test.exs` first: `with_span/3` returns inner value unchanged (incl. empty attrs), re-raises inner exceptions; `record_error/1` returns `:ok` with and without an active span. Run → fails (module undefined).
- Implement `lib/maraithon/tracing.ex`:
  - `with_span(name, attributes, fun)` — wraps `OpenTelemetry.Tracer.with_span`, records exceptions + sets error status, reraises with original stacktrace, returns `fun`'s value.
  - `record_error(reason)` — adds an `"error"` span event + sets error status; rescue-guarded to always return `:ok`.
  - `normalize_attributes/1` — coerce non-primitive values (atoms → strings, else `inspect/1`).
- Run → all tests pass. Commit.

### Task 5 — Instrument the Telegram assistant run loop
File: `lib/maraithon/telegram_assistant/runner.ex`. Add `alias Maraithon.Tracing`.
- `run_inbound/1` → wrap in root span `telegram_assistant.run_inbound` (attrs: `chat_id`, `trigger_type`); original body moves to `do_run_inbound/1`.
- `run_loop/4` `:ok` branch → wrap the LLM `with` in span `telegram_assistant.llm_request` (attrs: `run_id`, `iteration`, `llm_turns`, `model`); body moves to `do_run_loop_step/6`.
- `run_single_tool_call/4` → wrap in span `telegram_assistant.tool_call` (attrs: `run_id`, `tool`, `sequence`); body moves to `do_run_single_tool_call/6` with `_ = tool_call` to silence unused warning.
- `handle_run_failure/4` → add `_ = Tracing.record_error(reason)` as the first line — the core gap-closer.
- Verify with `mix compile --warnings-as-errors` (confirms `end`/block balance) and the existing runner/assistant tests. Commit.

### Task 6 — Instrument LLM provider HTTP calls
Files: `lib/maraithon/llm/anthropic_provider.ex`, `lib/maraithon/llm/openai_provider.ex`. Add `alias Maraithon.Tracing` to each.
- `grep -n "def \|Req\.\|Finch\.\|post\|complete"` both modules to find the single function that issues the HTTP request and returns `{:ok,_}`/`{:error,_}`.
- Wrap that function body in `Tracing.with_span("llm.request", %{provider: …, model: model}, fn -> … end)` — Anthropic `provider: "anthropic"`, OpenAI `provider: "openai"`. Derive `model` from the existing local var or `Map.get(params, "model") || Map.get(params, :model)`. Do not change return values.
- OpenAI has streaming + non-streaming paths; wrap the common HTTP entry point, or both if separate — streaming span gets extra attr `streaming: true`.
- Verify `mix compile --warnings-as-errors` and `mix test test/maraithon/llm`. Commit.

### Task 7 — Final verification
- `mix precommit` — formatter, credo, full suite all green. Do not commit over a red suite.
- Manual export smoke test (optional until token provisioned): with a real token, `mix phx.server`, send a Telegram message, confirm nested spans `run_inbound → llm_request → tool_call / llm.request` in Logfire; trigger a failing run, confirm `run_inbound` shows `status: error` with the reason.
- Document the operator action `fly secrets set LOGFIRE_WRITE_TOKEN=<token>` in the PR description.

---

## Files and Interfaces

**Modified**
- `mix.exs` / `mix.lock` — six `opentelemetry*` deps.
- `config/config.exs` — static `:opentelemetry` config, `:none` default, `service.name` resource.
- `config/runtime.exs` — token-gated OTLP exporter block.
- `lib/maraithon/application.ex` — `OpentelemetryBandit/Phoenix/Ecto.setup` at top of `start/2`.
- `lib/maraithon/telegram_assistant/runner.ex` — spans on `run_inbound/1`, `run_loop/4`, `run_single_tool_call/4`; `record_error` in `handle_run_failure/4`.
- `lib/maraithon/llm/anthropic_provider.ex`, `lib/maraithon/llm/openai_provider.ex` — `llm.request` span around HTTP call.

**Created**
- `lib/maraithon/tracing.ex` — `with_span/3`, `record_error/1`.
- `test/maraithon/tracing_test.exs` — 5+ unit tests.

**Public interface**
- `Maraithon.Tracing.with_span(name :: String.t(), attributes :: map(), fun :: (-> result)) :: result` — returns inner value unchanged; records + re-raises exceptions.
- `Maraithon.Tracing.record_error(reason :: term()) :: :ok` — safe with or without an active span.

Span namespace: `telegram_assistant.*` and `llm.*`.

---

## Acceptance Checks

- `mix deps.get` resolves all six packages with no conflicts.
- `mix compile --warnings-as-errors` passes after every code task.
- `mix test test/maraithon/tracing_test.exs` — all `Maraithon.Tracing` tests green.
- With `LOGFIRE_WRITE_TOKEN` unset: `Application.get_env(:opentelemetry, :traces_exporter)` is `:none`; existing test suite passes unchanged (spans inert).
- With `LOGFIRE_WRITE_TOKEN` set: `Application.get_env(:opentelemetry_exporter, :otlp_endpoint)` returns the Logfire base URL.
- Existing runner/assistant and LLM provider test suites still pass.
- `mix precommit` (format + credo + full suite) is green.
- Manual: a Telegram message produces a Logfire trace with nested `run_inbound → llm_request → tool_call / llm.request` spans; a failing run shows `status: error` with the failure reason on the `run_inbound` span.

---

## Proof of Work Expectations

- Per-task commit history matching the seven tasks, each with a clear message.
- Pasted output of `mix compile --warnings-as-errors`, `mix test test/maraithon/tracing_test.exs`, the runner/assistant + LLM test runs, and the final `mix precommit` — all green.
- Output of the runtime-config verification commands showing `:none` default and the Logfire endpoint when the token is set.
- Diff summary of the eight touched/created files.
- PR description noting the operator action `fly secrets set LOGFIRE_WRITE_TOKEN=<token>` and, if performed, a screenshot or description of the Logfire trace from the manual smoke test (otherwise explicitly marked as pending token provisioning).

---

## Risks

- **Hex version drift.** The pinned `~>` ranges may not resolve; mitigation is to bump to the latest published version and note it. The `opentelemetry_bandit ~> 0.3` package is pre-1.0 and most likely to shift API.
- **Setup ordering / adapter mismatch.** Wrong order or wrong `adapter:` value yields missing or duplicated HTTP spans. Bandit smoke test in Task 3 catches a non-booting app but not silent span loss — the Task 7 manual check is the real guard.
- **`end`/block balance in `runner.ex`.** Tasks 5.2–5.4 extract function bodies into new private functions; mis-balanced `end`s are likely. `mix compile --warnings-as-errors` is the gate.
- **LLM provider entry-point ambiguity.** Task 6 depends on a `grep` inspection because the exact HTTP-issuing function names aren't known from the spec; OpenAI's streaming/non-streaming split may need two wraps.
- **Logfire auth quirk.** Raw token with no `Bearer ` prefix — easy to get wrong; a 401 at ingest is the symptom, only visible during the manual smoke test.
- **Batch processor on shutdown.** `span_processor: :batch` can drop spans if the VM exits before flush; acceptable for diagnostics, noted as a known limitation.
- **Attribute coercion gaps.** Non-primitive attribute values that slip past `normalize_value/1` could cause exporter-side errors; the rescue guards in `Tracing` prevent caller-side crashes but such spans may be dropped silently.
