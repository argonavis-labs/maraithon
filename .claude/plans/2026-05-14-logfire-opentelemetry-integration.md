---
status: done
---
# Logfire / OpenTelemetry Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export diagnostic-quality distributed traces from Maraithon to Pydantic Logfire via OpenTelemetry, with custom spans on the Telegram assistant hot path and explicit failure recording.

**Architecture:** Standard Elixir OpenTelemetry stack (auto-instrumentation for Phoenix/Bandit/Ecto) plus a thin `Maraithon.Tracing` wrapper for hand-rolled spans. The OTLP exporter targets Logfire's US ingest endpoint. Exporting is opt-in by `LOGFIRE_WRITE_TOKEN` presence — disabled (`:none`) in dev/test by default, so it is a no-op until a token is provided.

**Tech Stack:** Elixir, Phoenix 1.8 + Bandit, Ecto, OpenTelemetry (`opentelemetry*` hex packages), OTLP/HTTP, Pydantic Logfire.

Spec: `docs/superpowers/specs/2026-05-14-logfire-opentelemetry-integration-design.md`

---

### Task 1: Add OpenTelemetry dependencies and static config

**Files:**
- Modify: `mix.exs` (deps list, ~line 53 near `telemetry_*`)
- Modify: `config/config.exs` (append after the existing logger config block)

- [x] **Step 1: Add deps to `mix.exs`**

In the `deps/0` list, after the `{:telemetry_poller, "~> 1.0"}` line, add:

```elixir
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.10"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.3"},
      {:opentelemetry_ecto, "~> 1.2"},
```

- [x] **Step 2: Fetch deps**

Run: `mix deps.get`
Expected: resolves and downloads the six `opentelemetry*` packages with no version conflicts. If a version is unavailable, bump to the latest published on hex and note it.

- [x] **Step 3: Add static OTel config to `config/config.exs`**

After the `config :maraithon, Maraithon.LogBuffer, max_entries: 500` line, add:

```elixir
# OpenTelemetry — traces export is disabled by default and turned on in
# config/runtime.exs only when LOGFIRE_WRITE_TOKEN is present.
config :opentelemetry,
  traces_exporter: :none,
  resource: %{service: %{name: "maraithon"}}
```

- [x] **Step 4: Verify compile**

Run: `mix compile`
Expected: compiles clean (warnings from new deps are acceptable; no errors).

- [x] **Step 5: Commit**

```bash
git add mix.exs mix.lock config/config.exs
git commit -m "Add OpenTelemetry deps and disabled-by-default trace config"
```

---

### Task 2: Wire the Logfire OTLP exporter in runtime config

**Files:**
- Modify: `config/runtime.exs`

- [x] **Step 1: Add the exporter block to `config/runtime.exs`**

At the end of `config/runtime.exs` (outside any `if config_env() == :prod` block — this must apply in any env where the token is set), add:

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

Note: `otlp_endpoint` is a base URL — the exporter appends `/v1/traces`. The
auth header value is the raw token with NO `Bearer ` prefix (Logfire-specific).

- [x] **Step 2: Verify runtime config loads**

Run: `mix compile` then `LOGFIRE_WRITE_TOKEN=test-token mix run -e "IO.inspect(Application.get_env(:opentelemetry_exporter, :otlp_endpoint))"`
Expected: prints `"https://logfire-us.pydantic.dev"`. Without the env var, `mix run -e "IO.inspect(Application.get_env(:opentelemetry, :traces_exporter))"` prints `:none`.

- [x] **Step 3: Commit**

```bash
git add config/runtime.exs
git commit -m "Point OTLP exporter at Logfire when LOGFIRE_WRITE_TOKEN is set"
```

---

### Task 3: Set up auto-instrumentation in the application supervisor

**Files:**
- Modify: `lib/maraithon/application.ex:9` (top of `start/2`)

- [x] **Step 1: Add setup calls to `start/2`**

In `lib/maraithon/application.ex`, change the start of `start/2` from:

```elixir
  def start(_type, _args) do
    children = [
```

to:

```elixir
  def start(_type, _args) do
    # OpenTelemetry auto-instrumentation. Must run before the supervisor starts
    # so :telemetry handlers are attached before the first request. No-op for
    # export when traces_exporter is :none (default dev/test).
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:maraithon, :repo])

    children = [
```

Order is required: `OpentelemetryBandit.setup()` before `OpentelemetryPhoenix.setup/1`.

- [x] **Step 2: Verify the app boots**

Run: `mix compile` then `mix run --no-start -e ":ok"` and `MIX_ENV=test mix test test/maraithon_web --max-failures 1` (any existing web test as a smoke check that the endpoint still boots).
Expected: compiles clean; smoke test boots the app and passes.

- [x] **Step 3: Commit**

```bash
git add lib/maraithon/application.ex
git commit -m "Set up Phoenix/Bandit/Ecto OpenTelemetry instrumentation"
```

---

### Task 4: `Maraithon.Tracing` helper module (TDD)

**Files:**
- Create: `lib/maraithon/tracing.ex`
- Test: `test/maraithon/tracing_test.exs`

- [x] **Step 1: Write the failing test**

Create `test/maraithon/tracing_test.exs`:

```elixir
defmodule Maraithon.TracingTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tracing

  test "with_span/3 returns the inner function's value unchanged" do
    assert Tracing.with_span("test.span", %{foo: "bar"}, fn -> :inner_result end) ==
             :inner_result
  end

  test "with_span/3 returns the value even with empty attributes" do
    assert Tracing.with_span("test.span", %{}, fn -> 42 end) == 42
  end

  test "with_span/3 re-raises exceptions from the inner function" do
    assert_raise RuntimeError, "boom", fn ->
      Tracing.with_span("test.span", %{}, fn -> raise "boom" end)
    end
  end

  test "record_error/1 does not raise when there is no active span" do
    assert Tracing.record_error(:some_reason) == :ok
  end

  test "record_error/1 does not raise inside a span" do
    Tracing.with_span("test.span", %{}, fn ->
      assert Tracing.record_error({:assistant_harness_empty_tool_calls, []}) == :ok
    end)
  end
end
```

- [x] **Step 2: Run test to verify it fails**

Run: `mix test test/maraithon/tracing_test.exs`
Expected: FAIL — `Maraithon.Tracing` is undefined.

- [x] **Step 3: Write the implementation**

Create `lib/maraithon/tracing.ex`:

```elixir
defmodule Maraithon.Tracing do
  @moduledoc """
  Thin wrapper over OpenTelemetry span macros.

  Centralises the OTel API surface so the rest of the codebase has one small,
  testable interface. When the OTel exporter is disabled (`:none`, the default
  in dev/test), span operations are effectively no-ops; this module still
  returns the wrapped value unchanged and never raises into caller code.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Run `fun` inside a span named `name` with `attributes`.

  Returns `fun`'s value unchanged. Exceptions are recorded on the span and
  re-raised so control flow is never altered.
  """
  @spec with_span(String.t(), map(), (-> result)) :: result when result: term()
  def with_span(name, attributes, fun)
      when is_binary(name) and is_map(attributes) and is_function(fun, 0) do
    Tracer.with_span name, %{attributes: normalize_attributes(attributes)} do
      try do
        fun.()
      rescue
        exception ->
          Tracer.record_exception(exception, __STACKTRACE__)
          Tracer.set_status(OpenTelemetry.status(:error, Exception.message(exception)))
          reraise exception, __STACKTRACE__
      end
    end
  end

  @doc """
  Mark the current span as failed and attach `reason` as a span event.

  Safe to call when there is no active span. Always returns `:ok`.
  """
  @spec record_error(term()) :: :ok
  def record_error(reason) do
    description = inspect(reason)
    Tracer.add_event("error", %{"reason" => description})
    Tracer.set_status(OpenTelemetry.status(:error, description))
    :ok
  rescue
    _ -> :ok
  end

  # OTel attribute values must be primitives (or lists of primitives); coerce
  # anything else to an inspected string.
  defp normalize_attributes(attributes) do
    Map.new(attributes, fn {key, value} -> {key, normalize_value(value)} end)
  end

  defp normalize_value(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value),
       do: value

  defp normalize_value(value) when is_atom(value), do: to_string(value)
  defp normalize_value(value), do: inspect(value)
end
```

- [x] **Step 4: Run test to verify it passes**

Run: `mix test test/maraithon/tracing_test.exs`
Expected: PASS — all 5 tests green.

- [x] **Step 5: Commit**

```bash
git add lib/maraithon/tracing.ex test/maraithon/tracing_test.exs
git commit -m "Add Maraithon.Tracing OpenTelemetry span helper"
```

---

### Task 5: Instrument the Telegram assistant run loop

**Files:**
- Modify: `lib/maraithon/telegram_assistant/runner.ex` — `run_inbound/1` (line 21), `run_loop/4` (line 139), `run_single_tool_call/4` (line 258), `handle_run_failure/4` (line 357)

Only the assistant hot path is instrumented — that is the area that is currently
un-diagnosable. Auto-instrumentation already covers HTTP and DB.

- [x] **Step 1: Add the alias**

In `lib/maraithon/telegram_assistant/runner.ex`, after `alias Maraithon.Tools` (line 16), add:

```elixir
  alias Maraithon.Tracing
```

- [x] **Step 2: Wrap `run_inbound/1` in a root span**

Change the body of `run_inbound/1` so the existing logic runs inside a span. Replace:

```elixir
  def run_inbound(attrs) when is_map(attrs) do
    context = ContextEngine.build_context(attrs)
    conversation = Map.get(attrs, :conversation)

    case start_run(attrs, context) do
```

with:

```elixir
  def run_inbound(attrs) when is_map(attrs) do
    Tracing.with_span(
      "telegram_assistant.run_inbound",
      %{
        chat_id: Map.get(attrs, :chat_id),
        trigger_type: trigger_type(attrs)
      },
      fn -> do_run_inbound(attrs) end
    )
  end

  defp do_run_inbound(attrs) do
    context = ContextEngine.build_context(attrs)
    conversation = Map.get(attrs, :conversation)

    case start_run(attrs, context) do
```

The rest of the original function body is unchanged — it now lives in
`do_run_inbound/1`. Verify the `end` that closed `run_inbound/1` now closes
`do_run_inbound/1`.

- [x] **Step 3: Wrap `run_loop/4`'s LLM request in a span**

In `run_loop/4`, the `:ok` branch builds `request_payload` and calls
`next_step`. Wrap the `with` expression that starts at
`with {:ok, llm_request_step} <-` in a span. Replace:

```elixir
      :ok ->
        request_payload =
          runtime_context
          |> Map.put(:tools, ContextEngine.tool_catalog(runtime_context.context))
          |> AssistantHarness.build_loop_request_payload(state, runner_policy_opts())
          |> Map.put(:_stream_target, runtime_context.run_id)

        now = DateTime.utc_now()

        with {:ok, llm_request_step} <-
```

with:

```elixir
      :ok ->
        request_payload =
          runtime_context
          |> Map.put(:tools, ContextEngine.tool_catalog(runtime_context.context))
          |> AssistantHarness.build_loop_request_payload(state, runner_policy_opts())
          |> Map.put(:_stream_target, runtime_context.run_id)

        now = DateTime.utc_now()

        Tracing.with_span(
          "telegram_assistant.llm_request",
          %{
            run_id: run.id,
            iteration: state.iteration,
            llm_turns: state.llm_turns,
            model: TelegramAssistant.model_name()
          },
          fn -> do_run_loop_step(run, runtime_context, state, started_monotonic_ms, request_payload, now) end
        )
    end
  end

  defp do_run_loop_step(run, runtime_context, state, started_monotonic_ms, request_payload, now) do
        with {:ok, llm_request_step} <-
```

The remainder of the original `:ok` branch (the `with`/`else` block) becomes the
body of `do_run_loop_step/6`. Remove the now-duplicated `end` that closed the
`case` and `run_loop/4` — `do_run_loop_step/6` ends where the original `with`
block ended. Re-check brace/`end` balance carefully after this edit.

- [x] **Step 4: Wrap `run_single_tool_call/4` in a span**

Replace:

```elixir
  defp run_single_tool_call(run, runtime_context, tool_call, sequence) do
    tool_name = Map.get(tool_call, "tool")
    arguments = Map.get(tool_call, "arguments", %{})
    now = DateTime.utc_now()

    with {:ok, tool_step} <-
```

with:

```elixir
  defp run_single_tool_call(run, runtime_context, tool_call, sequence) do
    tool_name = Map.get(tool_call, "tool")
    arguments = Map.get(tool_call, "arguments", %{})
    now = DateTime.utc_now()

    Tracing.with_span(
      "telegram_assistant.tool_call",
      %{run_id: run.id, tool: tool_name, sequence: sequence},
      fn -> do_run_single_tool_call(run, runtime_context, tool_call, tool_name, arguments, now) end
    )
  end

  defp do_run_single_tool_call(run, runtime_context, tool_call, tool_name, arguments, now) do
    _ = tool_call

    with {:ok, tool_step} <-
```

The original `with` block body becomes `do_run_single_tool_call/6`. The
`tool_call` argument is kept only so the signature is explicit; `_ = tool_call`
silences the unused warning since the body uses `tool_name`/`arguments`.

- [x] **Step 5: Record the failure reason on the span in `handle_run_failure/4`**

In `handle_run_failure/4`, immediately after the function head, add a
`Tracing.record_error/1` call. Replace:

```elixir
  defp handle_run_failure(run, reason, state, attrs) do
    {:ok, %{delivery: delivery, summary: liveness_summary}} =
      TelegramAssistant.prepare_final_delivery(run.id)
```

with:

```elixir
  defp handle_run_failure(run, reason, state, attrs) do
    _ = Tracing.record_error(reason)

    {:ok, %{delivery: delivery, summary: liveness_summary}} =
      TelegramAssistant.prepare_final_delivery(run.id)
```

This is the core gap-closer: a run failing with `:assistant_harness_empty_tool_calls`
now records that reason on the active `run_inbound` span, visible in Logfire even
though it never reaches stdout logs.

- [x] **Step 6: Verify compile and existing tests**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean — confirms the `end`/block balance from Steps 2-4 is correct.

Run: `mix test test/maraithon/telegram_assistant_test.exs test/maraithon/telegram_assistant`
Expected: existing runner/assistant tests still pass (OTel exporter is `:none` in test, so spans are inert).

- [x] **Step 7: Commit**

```bash
git add lib/maraithon/telegram_assistant/runner.ex
git commit -m "Add OpenTelemetry spans + failure recording to the assistant run loop"
```

---

### Task 6: Instrument the LLM provider HTTP calls

**Files:**
- Modify: `lib/maraithon/llm/anthropic_provider.ex`
- Modify: `lib/maraithon/llm/openai_provider.ex`

Wrap the outbound HTTP request to each provider so latency, model, and outcome
are visible per call. The exact public entry function differs per provider —
find the function that performs the HTTP request (the one that builds the body
and calls `Req`/`Finch`) and wrap its body.

- [x] **Step 1: Inspect both provider modules**

Run: `grep -n "def \|Req\.\|Finch\.\|post\|complete" lib/maraithon/llm/anthropic_provider.ex lib/maraithon/llm/openai_provider.ex`
Identify the single function per module that issues the HTTP request and returns
`{:ok, _}` / `{:error, _}`.

- [x] **Step 2: Add the alias to each provider**

At the top of each module, with the other aliases, add:

```elixir
  alias Maraithon.Tracing
```

- [x] **Step 3: Wrap the request function body — Anthropic**

In `lib/maraithon/llm/anthropic_provider.ex`, wrap the body of the HTTP request
function identified in Step 1 with:

```elixir
    Tracing.with_span(
      "llm.request",
      %{provider: "anthropic", model: model},
      fn ->
        # ... existing function body ...
      end
    )
```

Use whatever local variable already holds the model name (commonly `model` from
the params map); if none exists, derive it with
`Map.get(params, "model") || Map.get(params, :model)`. Do not change return
values.

- [x] **Step 4: Wrap the request function body — OpenAI**

Repeat Step 3 in `lib/maraithon/llm/openai_provider.ex` with
`%{provider: "openai", model: model}`. The OpenAI provider has both a streaming
and non-streaming path (`do_stream_complete/*` and a non-streaming sibling) —
wrap whichever single function is the common HTTP entry point; if they are
separate, wrap both, naming the streaming span `"llm.request"` with an extra
attribute `streaming: true`.

- [x] **Step 5: Verify compile and tests**

Run: `mix compile --warnings-as-errors`
Expected: clean.

Run: `mix test test/maraithon/llm`
Expected: existing LLM provider tests pass (spans inert in test).

- [x] **Step 6: Commit**

```bash
git add lib/maraithon/llm/anthropic_provider.ex lib/maraithon/llm/openai_provider.ex
git commit -m "Add OpenTelemetry spans around LLM provider HTTP calls"
```

---

### Task 7: Final verification

- [x] **Step 1: Run the full precommit suite**

Run: `mix precommit`
Expected: formatter, credo, and the full test suite all pass. Fix any failures
before proceeding — do not commit over a red suite.

- [x] **Step 2: Smoke-test export wiring (manual, optional until token is provisioned)**

With a real `LOGFIRE_WRITE_TOKEN` exported, run `mix phx.server`, send a Telegram
message to the bot, and confirm in the Logfire UI that a trace appears with the
nested spans `telegram_assistant.run_inbound` → `telegram_assistant.llm_request`
→ `telegram_assistant.tool_call` / `llm.request`. Trigger a failing run and
confirm the `run_inbound` span shows `status: error` with the reason.

- [x] **Step 3: Provision the production secret**

Once the write token is available:

```bash
fly secrets set LOGFIRE_WRITE_TOKEN=<token>
```

(This is an operator action — note it in the PR description rather than running
it as part of implementation.)

- [x] **Step 4: Final commit if anything changed during verification**

```bash
git add -A
git commit -m "Logfire/OpenTelemetry integration: final verification fixes"
```

---

## Self-Review

**Spec coverage:** deps (T1) · static config `:none` default (T1) · runtime
exporter block + endpoint/header rules (T2) · application setup order (T3) ·
`Maraithon.Tracing` with `with_span`/`record_error` + disabled-safe behaviour
(T4) · custom spans on `run_inbound`/`run_loop`/`run_single_tool_call` (T5) ·
failure recording in `handle_run_failure` (T5) · LLM provider spans (T6) ·
testing gated-off in test env + Tracing unit tests + `mix precommit` (T4, T7).
Resource `service.name` set in T1. All spec sections map to a task.

**Placeholders:** none — Task 6 intentionally requires a `grep` inspection step
because the provider HTTP entry-point function names are not known from the spec;
the wrapping pattern and attributes are fully specified.

**Type consistency:** `Tracing.with_span/3` and `Tracing.record_error/1`
signatures are identical across T4 (definition), T5, and T6 (uses). Span names
use a consistent `telegram_assistant.*` / `llm.*` namespace.
