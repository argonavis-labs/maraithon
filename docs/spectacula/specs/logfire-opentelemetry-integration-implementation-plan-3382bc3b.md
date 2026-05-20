---
created_at: 2026-05-14T18:41:34Z
created_by: cybrus
cybrus_task_id: 3382BC3B-6FBA-453F-98BC-8E771AC3ACEC
project: Maraithon App
status: done
---
# Logfire / OpenTelemetry Integration Implementation Plan

Status: Done
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 3382BC3B-6FBA-453F-98BC-8E771AC3ACEC
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

# Logfire / OpenTelemetry Integration — Implementation Plan

Export diagnostic-quality distributed traces from Maraithon to Pydantic Logfire via OpenTelemetry, with custom spans on the Telegram assistant hot path and explicit failure recording.

Spec: `docs/superpowers/specs/2026-05-14-logfire-opentelemetry-integration-design.md`

---

## Objective

Make the Telegram assistant run loop **diagnosable in production**. Today a run can fail (e.g. `:assistant_harness_empty_tool_calls`) without that reason reaching stdout logs, leaving no trail. After this work:

- Phoenix, Bandit, and Ecto are auto-instrumented for HTTP and DB spans.
- The assistant hot path (`run_inbound` → `llm_request` → `tool_call` / `llm.request`) emits nested custom spans.
- Run failures record their reason on the active span with `status: error`.
- Traces export to Pydantic Logfire's US OTLP ingest endpoint, **opt-in** via `LOGFIRE_WRITE_TOKEN` — a complete no-op in dev/test until a token is provided.

---

## Assumptions and Decisions

- **Opt-in by token presence.** `traces_exporter` is `:none` by default (set in `config/config.exs`); `config/runtime.exs` flips it to `:otlp` only when `LOGFIRE_WRITE_TOKEN` is set. This keeps dev/test inert with zero config and avoids a separate feature flag.
- **Runtime config sits outside the `:prod` guard.** The exporter block in `runtime.exs` is gated solely on the env var so a developer can opt in locally for debugging.
- **Logfire auth is a raw token, no `Bearer ` prefix.** This is Logfire-specific; the `authorization` header value is the token verbatim.
- **`otlp_endpoint` is a base URL.** The exporter appends `/v1/traces`. Default `https://logfire-us.pydantic.dev`, overridable via `LOGFIRE_ENDPOINT`.
- **Only the assistant hot path gets hand-rolled spans.** HTTP/DB are covered by auto-instrumentation; instrumenting the run loop + LLM providers closes the actual diagnostic gap without span sprawl.
- **`Maraithon.Tracing` is a thin, testable wrapper.** It centralises the OTel API surface, returns wrapped values unchanged, and never raises into caller code — so callers are unaffected whether export is on or off.
- **Span namespace:** `telegram_assistant.*` for run-loop spans, `llm.*` for provider calls.
- **Setup order is load-bearing:** `OpentelemetryBandit.setup()` must run before `OpentelemetryPhoenix.setup/1`, and both before the supervisor starts.
- **Provider HTTP entry points are not known from the spec.** Task 6 includes an explicit inspection step; the wrapping pattern and attributes are fully specified, only the function name is discovered at implementation time.
- **Production secret provisioning is an operator action**, noted in the PR description, not run by the coding agent.

---

## Implementation Plan

Execute task-by-task. Each task ends with its own commit. Use `superpowers:subagent-driven-development` or `superpowers:executing-plans`.

### Task 1 — Add OpenTelemetry deps and disabled-by-default config

- **Step 1:** In `mix.exs` `deps/0`, after `{:telemetry_poller, "~> 1.0"}`, add:
  ```elixir
  {:opentelemetry_api, "~> 1.5"},
  {:opentelemetry, "~> 1.7"},
  {:opentelemetry_exporter, "~> 1.10"},
  {:opentelemetry_phoenix, "~> 2.0"},
  {:opentelemetry_bandit, "~> 0.3"},
  {:opentelemetry_ecto, "~> 1.2"},
  ```
- **Step 2:** `mix deps.get` — resolves the six packages. If a version is unavailable, bump to the latest published on hex and note the change.
- **Step 3:** In `config/config.exs`, after `config :maraithon, Maraithon.LogBuffer, max_entries: 500`, add:
  ```elixir
  # OpenTelemetry — traces export is disabled by default and turned on in
  # config/runtime.exs only when LOGFIRE_WRITE_TOKEN is present.
  config :opentelemetry,
    traces_exporter: :none,
    resource: %{service: %{name: "maraithon"}}
  ```
- **Step 4:** `mix compile` — clean (new-dep warnings acceptable, no errors).
- **Step 5:** Commit: `git add mix.exs mix.lock config/config.exs` → `"Add OpenTelemetry deps and disabled-by-default trace config"`

### Task 2 — Wire the Logfire OTLP exporter in runtime config

- **Step 1:** At the end of `config/runtime.exs`, **outside any `config_env() == :prod` block**, add:
  ```elixir
  # =============================================================================
  # Observability — Pydantic Logfire (OpenTelemetry / OTLP)
  # =============================================================================
  # Opt-in: when LOGFIRE_WRITE_TOKEN is set, traces export to Logfire. When it is
  # absent (default dev/test), the exporter stays :none and nothing is sent.
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
- **Step 2:** Verify: `LOGFIRE_WRITE_TOKEN=test-token mix run -e "IO.inspect(Application.get_env(:opentelemetry_exporter, :otlp_endpoint))"` prints `"https://logfire-us.pydantic.dev"`; without the var, `mix run -e "IO.inspect(Application.get_env(:opentelemetry, :traces_exporter))"` prints `:none`.
- **Step 3:** Commit: `git add config/runtime.exs` → `"Point OTLP exporter at Logfire when LOGFIRE_WRITE_TOKEN is set"`

### Task 3 — Set up auto-instrumentation in the application supervisor

- **Step 1:** In `lib/maraithon/application.ex`, at the top of `start/2` (before `children = [`):
  ```elixir
  # OpenTelemetry auto-instrumentation. Must run before the supervisor starts
  # so :telemetry handlers are attached before the first request. No-op for
  # export when traces_exporter is :none (default dev/test).
  OpentelemetryBandit.setup()
  OpentelemetryPhoenix.setup(adapter: :bandit)
  OpentelemetryEcto.setup([:maraithon, :repo])
  ```
  Order required: `OpentelemetryBandit.setup()` before `OpentelemetryPhoenix.setup/1`.
- **Step 2:** Verify: `mix compile` clean; `mix run --no-start -e ":ok"`; `MIX_ENV=test mix test test/maraithon_web --max-failures 1` boots the endpoint and passes.
- **Step 3:** Commit: `git add lib/maraithon/application.ex` → `"Set up Phoenix/Bandit/Ecto OpenTelemetry instrumentation"`

### Task 4 — `Maraithon.Tracing` helper module (TDD)

- **Step 1:** Write the failing test `test/maraithon/tracing_test.exs` covering: `with_span/3` returns inner value unchanged (with attributes and with empty attributes); re-raises inner exceptions; `record_error/1` returns `:ok` both with no active span and inside a span.
- **Step 2:** `mix test test/maraithon/tracing_test.exs` — FAIL (`Maraithon.Tracing` undefined).
- **Step 3:** Implement `lib/maraithon/tracing.ex` with:
  - `with_span(name, attributes, fun)` — runs `fun` inside a `Tracer.with_span`, records exceptions via `Tracer.record_exception/2` + `set_status(:error, …)` and re-raises, returns `fun`'s value unchanged.
  - `record_error(reason)` — adds an `"error"` span event, sets span status to `:error` with `inspect(reason)`, always returns `:ok`, rescues internally so it never raises.
  - `normalize_attributes/1` — coerces non-primitive attribute values to strings (atoms → `to_string`, everything else → `inspect`).
  (Full reference implementation in the prior plan revision.)
- **Step 4:** `mix test test/maraithon/tracing_test.exs` — PASS (5 green).
- **Step 5:** Commit: `git add lib/maraithon/tracing.ex test/maraithon/tracing_test.exs` → `"Add Maraithon.Tracing OpenTelemetry span helper"`

### Task 5 — Instrument the Telegram assistant run loop

File: `lib/maraithon/telegram_assistant/runner.ex`.

- **Step 1:** After `alias Maraithon.Tools` (~line 16), add `alias Maraithon.Tracing`.
- **Step 2:** Wrap `run_inbound/1` in a root span `telegram_assistant.run_inbound` with attributes `chat_id`, `trigger_type`; move the original body into a new `do_run_inbound/1`.
- **Step 3:** In `run_loop/4`'s `:ok` branch, wrap the `with {:ok, llm_request_step} <- …` block in a `telegram_assistant.llm_request` span with attributes `run_id`, `iteration`, `llm_turns`, `model`; extract the block into `do_run_loop_step/6`. Re-check `end`/block balance.
- **Step 4:** Wrap `run_single_tool_call/4` in a `telegram_assistant.tool_call` span with attributes `run_id`, `tool`, `sequence`; extract the body into `do_run_single_tool_call/6` (keep `tool_call` arg, `_ = tool_call` to silence unused warning).
- **Step 5:** In `handle_run_failure/4`, immediately after the function head, add `_ = Tracing.record_error(reason)` — the core gap-closer.
- **Step 6:** Verify: `mix compile --warnings-as-errors` (confirms block balance from Steps 2–4); `mix test test/maraithon/telegram_assistant_test.exs test/maraithon/telegram_assistant`.
- **Step 7:** Commit: `git add lib/maraithon/telegram_assistant/runner.ex` → `"Add OpenTelemetry spans + failure recording to the assistant run loop"`

### Task 6 — Instrument the LLM provider HTTP calls

Files: `lib/maraithon/llm/anthropic_provider.ex`, `lib/maraithon/llm/openai_provider.ex`.

- **Step 1:** `grep -n "def \|Req\.\|Finch\.\|post\|complete" lib/maraithon/llm/anthropic_provider.ex lib/maraithon/llm/openai_provider.ex` — identify the single function per module that issues the HTTP request and returns `{:ok, _}` / `{:error, _}`.
- **Step 2:** Add `alias Maraithon.Tracing` to each module.
- **Step 3:** Anthropic — wrap the request function body in a `llm.request` span with `%{provider: "anthropic", model: model}`. Use the existing local model var, or derive `Map.get(params, "model") || Map.get(params, :model)`. Do not change return values.
- **Step 4:** OpenAI — same with `%{provider: "openai", model: model}`. If streaming (`do_stream_complete/*`) and non-streaming paths are separate, wrap both; add `streaming: true` to the streaming span's attributes.
- **Step 5:** Verify: `mix compile --warnings-as-errors`; `mix test test/maraithon/llm`.
- **Step 6:** Commit: `git add lib/maraithon/llm/anthropic_provider.ex lib/maraithon/llm/openai_provider.ex` → `"Add OpenTelemetry spans around LLM provider HTTP calls"`

### Task 7 — Final verification

- **Step 1:** `mix precommit` — formatter, credo, full test suite all pass. Do not commit over a red suite.
- **Step 2:** *(Manual, optional until token provisioned)* With a real `LOGFIRE_WRITE_TOKEN`, run `mix phx.server`, send a Telegram message, confirm the nested trace appears in Logfire; trigger a failing run and confirm `run_inbound` shows `status: error` with the reason.
- **Step 3:** *(Operator action — note in PR, do not run)* `fly secrets set LOGFIRE_WRITE_TOKEN=<token>`.
- **Step 4:** Final commit if verification produced fixes.

---

## Files and Interfaces

**Modified**
- `mix.exs` / `mix.lock` — six `opentelemetry*` deps.
- `config/config.exs` — `config :opentelemetry, traces_exporter: :none, resource: …`.
- `config/runtime.exs` — token-gated `:otlp` exporter block.
- `lib/maraithon/application.ex` — `OpentelemetryBandit/Phoenix/Ecto.setup` at top of `start/2`.
- `lib/maraithon/telegram_assistant/runner.ex` — spans on `run_inbound/1`, `run_loop/4`, `run_single_tool_call/4`; `record_error/1` in `handle_run_failure/4`; new private fns `do_run_inbound/1`, `do_run_loop_step/6`, `do_run_single_tool_call/6`.
- `lib/maraithon/llm/anthropic_provider.ex`, `lib/maraithon/llm/openai_provider.ex` — `llm.request` span around the HTTP entry point.

**Created**
- `lib/maraithon/tracing.ex` — `Maraithon.Tracing`.
- `test/maraithon/tracing_test.exs` — unit tests.

**Public interface — `Maraithon.Tracing`**
- `with_span(name :: String.t(), attributes :: map(), fun :: (-> result)) :: result` — runs `fun` in a span, records + re-raises exceptions, returns `fun`'s value unchanged.
- `record_error(reason :: term()) :: :ok` — marks the current span errored with `inspect(reason)`; safe with no active span; never raises.

**Environment variables**
- `LOGFIRE_WRITE_TOKEN` — presence enables export; value is the raw `authorization` header (no `Bearer `).
- `LOGFIRE_ENDPOINT` — optional base URL override, default `https://logfire-us.pydantic.dev`.

**Span tree**
```
telegram_assistant.run_inbound
└─ telegram_assistant.llm_request
   ├─ telegram_assistant.tool_call
   └─ llm.request   (provider, model)
```

---

## Acceptance Checks

- `mix deps.get` resolves all six `opentelemetry*` packages with no conflicts.
- `mix compile --warnings-as-errors` is clean after every task.
- With no `LOGFIRE_WRITE_TOKEN`: `Application.get_env(:opentelemetry, :traces_exporter)` is `:none`.
- With `LOGFIRE_WRITE_TOKEN` set: `traces_exporter` is `:otlp` and `Application.get_env(:opentelemetry_exporter, :otlp_endpoint)` is the Logfire base URL.
- `mix test test/maraithon/tracing_test.exs` — 5 tests pass.
- Existing suites pass with exporter inert: `test/maraithon_web`, `test/maraithon/telegram_assistant*`, `test/maraithon/llm`.
- `mix precommit` — formatter, credo, full test suite all green.
- *(Manual, post-token)* A live Telegram message produces the nested span tree in Logfire; a failing run shows `run_inbound` with `status: error` and the failure reason.

---

## Proof of Work Expectations

For the Cybrus review packet, capture:

- `git log --oneline` showing the seven scoped commits (one per task).
- `git diff` for the full change set.
- Terminal output of `mix deps.get`, `mix compile --warnings-as-errors`, and `mix precommit` (all passing).
- `mix test test/maraithon/tracing_test.exs` output — 5 passing.
- Output of the two `runtime.exs` verification commands (Task 2 Step 2) showing `:none` vs `:otlp` / endpoint.
- Confirmation that `lib/maraithon/application.ex` calls the three `setup` functions in the required order.
- A note in the PR description that `fly secrets set LOGFIRE_WRITE_TOKEN=<token>` is a pending operator action and that live-export smoke testing (Task 7 Step 2) is deferred until the token is provisioned.
- If any dep version was bumped from the planned constraint, note the actual version and why.

---

## Risks

- **Dep version drift.** The pinned `~>` versions may not all be co-installable or current. Mitigation: bump to latest published on hex, record the change in proof of work; watch for `opentelemetry_phoenix 2.x` requiring a specific `opentelemetry_api` range.
- **`opentelemetry_phoenix`/`opentelemetry_bandit` API surface.** `setup/1` arity and the `adapter: :bandit` option vary across major versions. Mitigation: confirm against the installed version's docs; the setup-order requirement (Bandit before Phoenix) is the most likely breakage point.
- **Block-balance errors in `runner.ex`.** Tasks 5 Steps 2–4 extract three private functions by relocating `end`s. Mitigation: `mix compile --warnings-as-errors` after the task; review brace/`end` balance per step before compiling.
- **Provider HTTP entry point ambiguity.** Function names in the LLM providers are discovered via `grep`, not known from the spec. Mitigation: Task 6 Step 1 is an explicit inspection step; if streaming/non-streaming paths diverge, wrap both.
- **Batch processor on shutdown.** `span_processor: :batch` can drop spans if the VM exits before flush. Acceptable for this diagnostic use case; revisit if traces are missing around deploys.
- **Token handling.** `LOGFIRE_WRITE_TOKEN` is a secret in `otlp_headers`; ensure it is never logged. Auto-instrumentation does not capture it, but confirm no config dump exposes it.
- **Auto-instrumentation overhead.** Ecto span-per-query can be noisy under load. Low risk at current scale; the exporter being `:none` by default means zero overhead until explicitly enabled.
