defmodule Maraithon.Telemetry.OtelSampler do
  @moduledoc """
  Root-span sampler that keeps Logfire signal-dense.

  Background pollers (Scheduler, EffectRunner, BackgroundJobRunner) hit the
  database every few seconds, and `opentelemetry_ecto` emits a span for every
  one of those queries. Those queries run with no parent span, so they surface
  as root `*.repo.query:*` spans — a firehose of noise that buries the traces
  worth reading: HTTP requests, assistant runs, briefing failures.

  This sampler drops root-level Ecto query spans and keeps everything else. It
  is wrapped in `:parent_based` (see `config/config.exs`) so that Ecto queries
  which *are* part of a real trace — a query inside an HTTP request or an
  assistant run — follow their sampled parent and are kept. Only the orphan
  background-poll queries are dropped.
  """

  @behaviour :otel_sampler

  @impl true
  def setup(_opts), do: []

  @impl true
  def description(_config), do: "MaraithonRootSampler"

  @impl true
  def should_sample(ctx, _trace_id, _links, span_name, _span_kind, _attributes, _config) do
    tracestate = ctx |> :otel_tracer.current_span_ctx() |> :otel_span.tracestate()

    if ecto_query_span?(span_name) do
      {:drop, [], tracestate}
    else
      {:record_and_sample, [], tracestate}
    end
  end

  @doc false
  # opentelemetry_ecto names spans either `maraithon.repo.query:<table>` or, when
  # no single source is resolved, bare `maraithon.repo.query` — match both.
  def ecto_query_span?(name) when is_binary(name), do: String.contains?(name, ".repo.query")

  def ecto_query_span?(name) when is_atom(name) and name not in [nil],
    do: ecto_query_span?(Atom.to_string(name))

  def ecto_query_span?(_name), do: false
end
