---
status: done
cybrus_task_id: CF6F000D-D8B2-4D8A-8BA9-051749978359
project: Maraithon App
created_by: cybrus
created_at: 2026-05-14T19:01:48Z
---

# Logfire / OpenTelemetry Integration Implementation Plan

Status: Done
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: CF6F000D-D8B2-4D8A-8BA9-051749978359
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

Export diagnostic-quality distributed traces from Maraithon to Pydantic Logfire via OpenTelemetry. Standard Elixir OTel auto-instrumentation covers Phoenix/Bandit/Ecto; a thin `Maraithon.Tracing` wrapper adds hand-rolled spans on the Telegram assistant hot path — currently the least diagnosable part of the system — plus explicit failure recording so silent failure modes like `:assistant_harness_empty_tool_calls` become visible in Logfire even when they never reach stdout.

Exporting is **opt-in by `LOGFIRE_WRITE_TOKEN` presence**: disabled (`:none`) in dev/test by default, a no-op until a token is provisioned.

Spec: `docs/superpowers/specs/2026-05-14-logfire-opentelemetry-integration-design.md`

---

## Assumptions and Decisions

- **Opt-in via env var.** `traces_exporter: :none` is the static default in `config/config.exs`; `config/runtime.exs` flips it to `:otlp` only when `LOGFIRE_WRITE_TOKEN` is present. This keeps dev/test inert with zero ceremony and makes production activation a single secret.
- **Logfire US ingest.** Endpoint defaults to `https://logfire-us.pydantic.dev`, overridable via `LOGFIRE_ENDPOINT`. The exporter appends `/v1/traces` itself — `otlp_endpoint` is a base URL.
- **Auth header has no `Bearer` prefix.** Logfire expects the raw token as the `authorization` header value. This is Logfire-specific and intentional.
- **OTLP over HTTP/protobuf** (`otlp_protocol: :http_protobuf`), `span_processor: :batch` in the exporting path.
- **Scope of custom spans is the assistant hot path only.** HTTP and DB are already covered by auto-instrumentation. Hand-rolled spans go on `run_inbound`, the `run_loop` LLM request step, `run_single_tool_call`, and the LLM provider HTTP calls. `handle_run_failure` records the failure reason on the active span.
- **`Maraithon.Tracing` never alters control flow.** `with_span/3` returns the inner function's value unchanged and re-raises exceptions after recording them; `record_error/1` is safe with no active span and always returns `:ok`.
- **Dep versions** are pinned to current major lines (`opentelemetry_api ~> 1.5`, `opentelemetry ~> 1.7`, `opentelemetry_exporter ~> 1.10`, `opentelemetry_phoenix ~> 2.0`, `opentelemetry_bandit ~> 0.3`, `opentelemetry_ecto ~> 1.2`). If hex resolution fails, bump to the latest published and note it in `mix.lock` / the PR.
- **`service.name` resource** is set to `"maraithon"` in static config.
- **Provider HTTP entry points are discovered, not assumed.** Task 6 includes a `grep` inspection step because the exact request function names in the Anthropic/OpenAI providers are not known from the spec; the wrapping pattern and span attributes are fully specified.
- **Production secret provisioning is an operator action**, noted in the PR description rather than executed by the coding agent.
- Setup order is load-bearing: `OpentelemetryBandit.setup()` must run before `OpentelemetryPhoenix.setup/1`, and both before the supervisor children start.

---

## Implementation Plan

### Task 1 — OpenTelemetry deps and static config
- Add the six `opentelemetry*` deps to `mix.exs` `deps/0`, after `{:telemetry_poller, "~> 1.0"}`.
- `mix deps.get` — resolve and download; bump versions if any are unpublished.
- Append static config to `config/config.exs` after the `LogBuffer` line: `traces_exporter: :none` and `resource: %{service: %{name: "maraithon"}}`.
- `mix compile` — clean (new-dep warnings acceptable, no errors).
- Commit: `Add OpenTelemetry deps and disabled-by-default trace config`.

### Task 2 — Logfire OTLP exporter in runtime config
- Append an `if logfire_token = System.get_env("LOGFIRE_WRITE_TOKEN")` block to `config/runtime.exs`, **outside** any `config_env() == :prod` guard, that sets `traces_exporter: :otlp`, `span_processor: :batch`, and configures `:opentelemetry_exporter` with `otlp_protocol: :http_protobuf`, the endpoint (env-overridable), and the raw-token `authorization` header.
- Verify: `LOGFIRE_WRITE_TOKEN=test-token mix run -e "IO.inspect(Application.get_env(:opentelemetry_exporter, :otlp_endpoint))"` prints the Logfire URL; without the var, `traces_exporter` is `:none`.
- Commit: `Point OTLP exporter at Logfire when LOGFIRE_WRITE_TOKEN is set`.

### Task 3 — Auto-instrumentation in the application supervisor
- At the top of `start/2` in `lib/maraithon/application.ex` (before `children = [`), call `OpentelemetryBandit.setup()`, `OpentelemetryPhoenix.setup(adapter: :bandit)`, `OpentelemetryEcto.setup([:maraithon, :repo])` — in that order.
- Verify: `mix compile`; `mix run --no-start -e ":ok"`; a `maraithon_web` smoke test boots the endpoint and passes.
- Commit: `Set up Phoenix/Bandit/Ecto OpenTelemetry instrumentation`.

### Task 4 — `Maraithon.Tracing` helper module (TDD)
- Write `test/maraithon/tracing_test.exs` first: `with_span/3` returns inner value (with attrs and with empty attrs), re-raises inner exceptions; `record_error/1` is safe with and without an active span.
- Run the test — confirm it fails (module undefined).
- Implement `lib/maraithon/tracing.ex`: `with_span/3` wraps `OpenTelemetry.Tracer.with_span`, records exceptions + sets error status + reraises, normalizes attribute values to OTel-safe primitives; `record_error/1` adds an `"error"` event, sets error status, rescues to `:ok`.
- Run the test — confirm 5 green.
- Commit: `Add Maraithon.Tracing OpenTelemetry span helper`.

### Task 5 — Instrument the Telegram assistant run loop
File: `lib/maraithon/telegram_assistant/runner.ex`
- Add `alias Maraithon.Tracing`.
- Wrap `run_inbound/1` in a root span `telegram_assistant.run_inbound` (attrs: `chat_id`, `trigger_type`); move the existing body into `do_run_inbound/1`.
- Wrap the `run_loop/4` LLM request step in span `telegram_assistant.llm_request` (attrs: `run_id`, `iteration`, `llm_turns`, `model`); extract the `:ok`-branch `with` block into `do_run_loop_step/6`.
- Wrap `run_single_tool_call/4` in span `telegram_assistant.tool_call` (attrs: `run_id`, `tool`, `sequence`); extract the body into `do_run_single_tool_call/6`.
- In `handle_run_failure/4`, add `_ = Tracing.record_error(reason)` as the first line — the core gap-closer.
- Verify: `mix compile --warnings-as-errors` (confirms `end`/block balance after the extractions); `mix test test/maraithon/telegram_assistant_test.exs test/maraithon/telegram_assistant`.
- Commit: `Add OpenTelemetry spans + failure recording to the assistant run loop`.

### Task 6 — Instrument the LLM provider HTTP calls
Files: `lib/maraithon/llm/anthropic_provider.ex`, `lib/maraithon/llm/openai_provider.ex`
- `grep -n "def \|Req\.\|Finch\.\|post\|complete"` both modules; identify the single function per module that issues the HTTP request and returns `{:ok,_}`/`{:error,_}`.
- Add `alias Maraithon.Tracing` to each.
- Wrap the request function body in span `llm.request` with `%{provider: "anthropic"|"openai", model: model}`. Derive `model` from the existing local or `Map.get(params, "model") || Map.get(params, :model)`. Do not change return values.
- OpenAI: if streaming and non-streaming are separate functions, wrap both; add `streaming: true` to the streaming span's attributes.
- Verify: `mix compile --warnings-as-errors`; `mix test test/maraithon/llm`.
- Commit: `Add OpenTelemetry spans around LLM provider HTTP calls`.

### Task 7 — Final verification
- `mix precommit` — formatter, credo, full test suite all green. Do not commit over a red suite.
- Optional manual smoke (once a real token exists): `mix phx.server`, send a Telegram message, confirm the nested trace `run_inbound → llm_request → tool_call / llm.request` in the Logfire UI; trigger a failing run and confirm `status: error` with the reason on the `run_inbound` span.
- Operator action (note in PR, do not run): `fly secrets set LOGFIRE_WRITE_TOKEN=<token>`.
- Final commit if verification produced fixes.

---

## Files and Interfaces

**New**
- `lib/maraithon/tracing.ex` — `Maraithon.Tracing`
  - `with_span(name :: String.t(), attributes :: map(), fun :: (-> result)) :: result` — runs `fun` in a named span; returns its value unchanged; records + re-raises exceptions; normalizes attribute values to primitives.
  - `record_error(reason :: term()) :: :ok` — marks the current span failed with `reason` as an event; safe with no active span.
- `test/maraithon/tracing_test.exs` — 5 unit tests for the above.

**Modified**
- `mix.exs` / `mix.lock` — six `opentelemetry*` deps.
- `config/config.exs` — static `:opentelemetry` config: `traces_exporter: :none`, `resource` with `service.name`.
- `config/runtime.exs` — token-gated `:otlp` exporter block (endpoint, protocol, auth header, batch processor).
- `lib/maraithon/application.ex` — `start/2`: three `Opentelemetry*.setup` calls before `children`.
- `lib/maraithon/telegram_assistant/runner.ex` — spans on `run_inbound/1`, `run_loop/4` LLM step, `run_single_tool_call/4`; `record_error/1` in `handle_run_failure/4`; new private `do_*` extraction functions.
- `lib/maraithon/llm/anthropic_provider.ex`, `lib/maraithon/llm/openai_provider.ex` — `llm.request` span around the HTTP entry point(s).

**Span namespace:** `telegram_assistant.run_inbound`, `telegram_assistant.llm_request`, `telegram_assistant.tool_call`, `llm.request`.

**Env vars:** `LOGFIRE_WRITE_TOKEN` (required to enable export), `LOGFIRE_ENDPOINT` (optional override).

---

## Acceptance Checks

- `mix deps.get` resolves the six packages with no version conflicts.
- `mix compile --warnings-as-errors` is clean after every code task.
- Without `LOGFIRE_WRITE_TOKEN`: `Application.get_env(:opentelemetry, :traces_exporter)` is `:none`.
- With `LOGFIRE_WRITE_TOKEN=test-token`: `Application.get_env(:opentelemetry_exporter, :otlp_endpoint)` is `"https://logfire-us.pydantic.dev"`.
- `mix test test/maraithon/tracing_test.exs` — 5 tests pass.
- Existing suites still pass: `test/maraithon_web` smoke test, `test/maraithon/telegram_assistant*`, `test/maraithon/llm`.
- `mix precommit` — formatter, credo, full suite all green.
- App boots: `mix run --no-start -e ":ok"` and the web smoke test succeed with setup calls in place.
- Manual (token-gated, optional): a Telegram message produces a nested trace in Logfire; a failing run shows `status: error` + reason on the `run_inbound` span.

---

## Proof of Work Expectations

For the review packet, capture:
- `git log --oneline` showing the seven scoped commits (one per task).
- `mix deps.get` output confirming resolved versions; any version bumps from the planned `~>` constraints called out explicitly.
- `mix compile --warnings-as-errors` clean output.
- `mix test test/maraithon/tracing_test.exs` output — 5 passing.
- `mix precommit` full output — formatter, credo, suite all green.
- The two `Application.get_env` verification commands (with and without the token) and their output.
- `grep` output from Task 6 Step 1 identifying the chosen provider HTTP functions, plus the resulting diff for each provider.
- Diff summary for `runner.ex` showing the `do_*` extractions and that the original logic is unchanged apart from being wrapped.
- PR description noting the operator action `fly secrets set LOGFIRE_WRITE_TOKEN=<token>` as outstanding.
- If the manual Logfire smoke test was run, a screenshot or trace link showing the nested spans and an error-status run.

---

## Risks

- **Hex version drift.** The pinned `~>` constraints may not match what's currently published, especially `opentelemetry_bandit ~> 0.3` (pre-1.0, fast-moving). Mitigation: bump to latest published, note it, re-verify compile.
- **`run_loop/4` / `run_single_tool_call/4` block-balance.** Extracting `with` blocks into new `do_*` functions is error-prone around `case`/`end` nesting. Mitigation: `mix compile --warnings-as-errors` immediately after Task 5; re-check `end` balance per the plan's explicit notes.
- **Bandit/Phoenix setup order.** Calling `OpentelemetryPhoenix.setup/1` before `OpentelemetryBandit.setup()` silently breaks request spans. Mitigation: order fixed and commented in `application.ex`.
- **`opentelemetry_phoenix ~> 2.0` API.** The 2.x line changed the setup signature; `adapter: :bandit` is assumed correct. If it rejects the option, consult the 2.x docs and adjust — auto-instrumentation only, no custom-span impact.
- **Logfire auth format.** Raw token, no `Bearer` prefix, is Logfire-specific; an OTLP-generic assumption would 401. Mitigation: documented inline in `runtime.exs`; manual smoke test confirms ingestion.
- **Provider HTTP entry point ambiguity.** If a provider splits request logic across several private functions, "wrap the single entry point" may be unclear. Mitigation: Task 6's `grep` step; wrap the common entry, or both streaming/non-streaming functions if genuinely separate.
- **Batch processor on shutdown.** `span_processor: :batch` can drop in-flight spans on abrupt exit — acceptable for diagnostics, not billing-critical. No mitigation needed; noted for awareness.
- **Attribute normalization gaps.** Non-primitive span attributes are `inspect/1`-stringified; large or sensitive values (tokens, message bodies) could leak into traces. Mitigation: attributes are restricted to IDs, counts, names, and model strings — no payloads — by design.

---

*Assumption of note: all tasks in the source plan are already checkbox-complete (`- [x]`). This refinement treats the plan as the design of record and restructures it into the required executable format; the coding agent should still run every verification step fresh rather than trusting the pre-checked boxes.*
