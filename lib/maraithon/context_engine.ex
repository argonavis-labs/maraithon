defmodule Maraithon.ContextEngine do
  @moduledoc """
  Contract and facade for assistant context assembly.

  Engines own context construction, tool catalogs, evidence budgets, compaction,
  and diagnostics. The default implementation wraps the current Telegram
  assistant context builder so the product can add budgeted surfaces without
  changing call sites.
  """

  alias Maraithon.DurablePayload
  alias Maraithon.PromptBudget

  @snapshot_bytes 96_000

  @callback build_context(map()) :: map()
  @callback tool_catalog(map()) :: list()
  @callback memory_context(map()) :: map()
  @callback open_loop_context(map()) :: map()
  @callback budget(map()) :: map()
  @callback compact(map(), map()) :: {map(), map()}
  @callback diagnostics(map()) :: map()

  def build_context(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    engine(opts).build_context(attrs)
  end

  def tool_catalog(context, opts \\ []) when is_map(context) and is_list(opts) do
    engine(opts).tool_catalog(context)
  end

  def memory_context(context, opts \\ []) when is_map(context) and is_list(opts) do
    engine(opts).memory_context(context)
  end

  def open_loop_context(context, opts \\ []) when is_map(context) and is_list(opts) do
    engine(opts).open_loop_context(context)
  end

  def budget(context \\ %{}, opts \\ []) when is_map(context) and is_list(opts) do
    engine(opts).budget(context)
  end

  def compact(context, budget, opts \\ []) when is_map(context) and is_map(budget) do
    engine(opts).compact(context, budget)
  end

  def diagnostics(context, opts \\ []) when is_map(context) and is_list(opts) do
    engine(opts).diagnostics(context)
  end

  def prompt_snapshot(context) when is_map(context) do
    case DurablePayload.prepare_map(context, @snapshot_bytes, max_depth: 12) do
      {:ok, snapshot} ->
        snapshot

      {:error, :invalid_payload} ->
        context
        |> PromptBudget.bounded(@snapshot_bytes - 100,
          max_depth: 8,
          list_items: 20,
          map_entries: 64,
          string_bytes: 16_384
        )
        |> Map.put("snapshot_compacted", true)
    end
  end

  defp engine(opts) do
    Keyword.get(opts, :engine) ||
      :maraithon
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:engine, Maraithon.ContextEngine.Telegram)
  end
end
