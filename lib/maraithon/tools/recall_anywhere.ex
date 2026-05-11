defmodule Maraithon.Tools.RecallAnywhere do
  @moduledoc """
  Unified open-ended search across every local source the companion mirrors
  (iMessage, Notes, Voice Memos, Calendar, Reminders, Files, Browser History)
  plus the durable remote/internal sources (deep Memory, CRM people).

  Each per-source search runs concurrently with a strict 3-second budget so a
  slow or temporarily unavailable source can't stall the whole call — slow
  sources are reported in `partial_sources` and dropped from results.

  Returns a uniform shape per hit:

      %{
        source: "...",
        id: "...",
        title: "...",
        snippet: "...",
        timestamp: %DateTime{} | nil,
        score: 0.0..1.0
      }

  Ranking and scoring lives in
  `Maraithon.Tools.RecallAnywhereHelpers`. See that module's docs for the
  formula.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Tools.RecallAnywhereHelpers

  @default_limit 20
  @max_limit 50
  # Total budget for the whole tool call, in ms. Each per-source task is
  # capped at this so a single slow source can't stall recall_anywhere.
  @source_timeout_ms 3_000

  @doc false
  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, query} <- required_string(args, "query") do
      limit = normalize_limit(args, @default_limit, @max_limit)
      sources = RecallAnywhereHelpers.normalize_sources(optional_list(args, "sources"))

      started_at = System.monotonic_time(:millisecond)
      now = DateTime.utc_now()

      {hits, completed_sources, partial_sources} = run_sources(user_id, query, sources)

      scored = Enum.map(hits, &RecallAnywhereHelpers.score_hit(&1, now))

      ranked =
        scored
        |> RecallAnywhereHelpers.rank()
        |> Enum.take(limit)

      latency_ms = System.monotonic_time(:millisecond) - started_at

      :telemetry.execute(
        [:maraithon, :tools, :recall_anywhere],
        %{
          query_length: String.length(query),
          result_count: length(ranked),
          latency_ms: latency_ms
        },
        %{
          user_id: user_id,
          sources_searched: completed_sources,
          partial_sources: partial_sources
        }
      )

      {:ok,
       %{
         source: "recall_anywhere",
         query: query,
         count: length(ranked),
         results: ranked,
         sources_searched: completed_sources,
         partial_sources: partial_sources,
         latency_ms: latency_ms
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp run_sources(user_id, query, sources) do
    # Per-source opts: keep a generous over-fetch ceiling so ranking has
    # enough candidates, but the response still clamps to `limit`.
    opts = [limit: @max_limit]

    stream =
      Task.async_stream(
        sources,
        fn source_name ->
          fun = RecallAnywhereHelpers.source_function(source_name)

          try do
            {source_name, fun.(user_id, query, opts)}
          rescue
            _ -> {source_name, []}
          catch
            _, _ -> {source_name, []}
          end
        end,
        timeout: @source_timeout_ms,
        on_timeout: :kill_task,
        max_concurrency: max(length(sources), 1),
        ordered: false
      )

    Enum.reduce(stream, {[], [], []}, fn
      {:ok, {source_name, raw_hits}}, {hits_acc, completed_acc, partial_acc} ->
        normalized = raw_hits |> List.wrap() |> Enum.filter(&is_map/1)
        {hits_acc ++ normalized, [source_name | completed_acc], partial_acc}

      {:exit, :timeout}, {hits_acc, completed_acc, partial_acc} ->
        partial =
          determine_partial(sources, completed_acc, partial_acc)

        {hits_acc, completed_acc, partial}

      {:exit, _reason}, {hits_acc, completed_acc, partial_acc} ->
        partial =
          determine_partial(sources, completed_acc, partial_acc)

        {hits_acc, completed_acc, partial}
    end)
    |> finalize_sources(sources)
  end

  # We can't know which source the exit-reason belongs to inside async_stream
  # without ordered: true. Cheaper to compute partial = requested - completed
  # at the end.
  defp determine_partial(_sources, _completed_acc, partial_acc), do: partial_acc

  defp finalize_sources({hits, completed, _partial}, sources) do
    completed_set = MapSet.new(completed)
    partial = sources |> Enum.reject(&MapSet.member?(completed_set, &1)) |> Enum.sort()
    {hits, Enum.sort(completed), partial}
  end

  defp optional_list(args, key) when is_map(args) and is_binary(key) do
    case Map.get(args, key) do
      list when is_list(list) -> list
      _ -> nil
    end
  end

  defp normalize_limit(args, default, max_limit) when is_map(args) do
    case Map.get(args, "limit") do
      value when is_integer(value) and value > 0 -> min(value, max_limit)
      value when is_binary(value) -> parse_limit(value, default, max_limit)
      _ -> default
    end
  end

  defp parse_limit(value, default, max_limit) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed, max_limit)
      _ -> default
    end
  end
end
