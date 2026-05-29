defmodule Maraithon.ContextEngine.Telegram do
  @moduledoc """
  Default context engine for the Telegram assistant.
  """

  @behaviour Maraithon.ContextEngine

  alias Maraithon.SourceFreshness
  alias Maraithon.TelegramAssistant.{Context, Toolbox}

  @default_budget %{
    source_evidence: %{max_items: 25, fields: [:connected_accounts, :source_freshness]},
    tool_results: %{max_items: 20, fields: []},
    memory: %{max_items: 12, fields: [:deep_memory, :operator_memory, :user_memory]},
    crm: %{max_items: 20, fields: [:relationships]},
    open_loops: %{max_items: 20, fields: [:open_loops, :todos, :open_insights]},
    projects: %{max_items: 25, fields: [:projects, :active_agents]},
    conversation: %{max_items: 16, fields: [:recent_turns]}
  }

  @field_categories @default_budget
                    |> Enum.flat_map(fn {category, %{fields: fields}} ->
                      Enum.map(fields, &{&1, category})
                    end)
                    |> Map.new()

  @impl true
  def build_context(attrs) when is_map(attrs) do
    raw_context = Context.build(attrs)
    budget = budget(raw_context)
    {context, diagnostics} = compact(raw_context, budget)

    Map.put(context, :context_diagnostics, diagnostics)
  end

  @impl true
  def tool_catalog(context) when is_map(context), do: Toolbox.tool_definitions(context)

  @impl true
  def memory_context(context) when is_map(context) do
    %{
      preference_memory: read(context, :preference_memory, %{}),
      operator_memory: read(context, :operator_memory, %{}),
      user_memory: read(context, :user_memory, %{}),
      deep_memory: read(context, :deep_memory, [])
    }
  end

  @impl true
  def open_loop_context(context) when is_map(context) do
    %{
      open_loops: read(context, :open_loops, %{}),
      todos: read(context, :todos, []),
      open_insights: read(context, :open_insights, [])
    }
  end

  @impl true
  def budget(_context), do: configured_budget()

  @impl true
  def compact(context, budget) when is_map(context) and is_map(budget) do
    limits = field_limits(budget)

    {compacted, field_diagnostics} =
      context
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.reduce({%{}, %{}}, fn {key, value}, {acc, diagnostics} ->
        field = normalize_key(key)
        limit = Map.get(limits, field)
        {next_value, field_diagnostic} = compact_value(field, value, limit)

        next_acc = Map.put(acc, key, next_value)

        next_diagnostics =
          if field_diagnostic do
            Map.put(diagnostics, field, field_diagnostic)
          else
            diagnostics
          end

        {next_acc, next_diagnostics}
      end)

    diagnostics = build_diagnostics(compacted, budget, field_diagnostics)
    {compacted, diagnostics}
  end

  @impl true
  def diagnostics(context) when is_map(context) do
    read(context, :context_diagnostics) || build_diagnostics(context, budget(context), %{})
  end

  defp compact_value(field, value, limit) when is_list(value) and is_integer(limit) do
    count = length(value)
    compacted = Enum.take(value, limit)
    omitted = max(count - length(compacted), 0)

    diagnostic = %{
      category: Map.get(@field_categories, field, :uncategorized),
      original_count: count,
      included_count: length(compacted),
      omitted_count: omitted,
      truncated?: omitted > 0
    }

    {compacted, diagnostic}
  end

  defp compact_value(field, value, _limit) when is_list(value) do
    count = length(value)

    {value,
     %{
       category: Map.get(@field_categories, field, :uncategorized),
       original_count: count,
       included_count: count,
       omitted_count: 0,
       truncated?: false
     }}
  end

  defp compact_value(_field, value, _limit), do: {value, nil}

  defp build_diagnostics(context, budget, field_diagnostics) do
    freshness = read(context, :source_freshness, [])

    %{
      engine: "telegram",
      budget_version: 1,
      budgets: summarize_budget(budget),
      fields: stringify_field_diagnostics(field_diagnostics),
      source_freshness: %{
        aggregate_status: SourceFreshness.aggregate_status(freshness),
        stale_or_broken: stale_or_broken_sources(freshness)
      }
    }
  end

  defp configured_budget do
    configured =
      :maraithon
      |> Application.get_env(Maraithon.ContextEngine, [])
      |> Keyword.get(:budget, %{})

    deep_merge_budget(@default_budget, configured)
  end

  defp field_limits(budget) do
    budget
    |> Enum.flat_map(fn {_category, settings} ->
      max_items = read(settings, :max_items)
      fields = read(settings, :fields, [])
      Enum.map(fields, &{normalize_key(&1), max_items})
    end)
    |> Map.new()
  end

  defp summarize_budget(budget) do
    Map.new(budget, fn {category, settings} ->
      {to_string(category),
       %{
         "max_items" => read(settings, :max_items),
         "fields" => Enum.map(read(settings, :fields, []), &to_string/1)
       }}
    end)
  end

  defp stringify_field_diagnostics(field_diagnostics) do
    Map.new(field_diagnostics, fn {field, diagnostic} ->
      {to_string(field),
       %{
         "category" => diagnostic.category |> to_string(),
         "original_count" => diagnostic.original_count,
         "included_count" => diagnostic.included_count,
         "omitted_count" => diagnostic.omitted_count,
         "truncated" => diagnostic.truncated?
       }}
    end)
  end

  defp stale_or_broken_sources(freshness) when is_list(freshness) do
    freshness
    |> Enum.filter(fn source ->
      status = read(source, :status)
      status in ["stale", "reauth_required", "error", "unknown", "never_synced"]
    end)
    |> Enum.map(fn source ->
      %{
        "provider" => read(source, :provider),
        "account_label" => read(source, :account_label),
        "status" => read(source, :status),
        "stale_reason" => read(source, :stale_reason)
      }
    end)
    |> Enum.map(&compact_map/1)
  end

  defp stale_or_broken_sources(_freshness), do: []

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp deep_merge_budget(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, normalize_budget_override(override), fn _key, left, right ->
      if is_map(left) and is_map(right), do: Map.merge(left, right), else: right
    end)
  end

  defp normalize_budget_override(override) when is_map(override) do
    Map.new(override, fn {category, settings} ->
      {normalize_key(category), normalize_budget_settings(settings)}
    end)
  end

  defp normalize_budget_override(_override), do: %{}

  defp normalize_budget_settings(settings) when is_map(settings) do
    settings
    |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
    |> Map.update(:fields, [], fn fields ->
      if is_list(fields), do: Enum.map(fields, &normalize_key/1), else: []
    end)
  end

  defp normalize_budget_settings(_settings), do: %{}

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize_key(key), do: key

  defp read(map, key, default \\ nil)

  defp read(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp read(_map, _key, default), do: default
end
