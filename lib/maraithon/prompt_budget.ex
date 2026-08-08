defmodule Maraithon.PromptBudget do
  @moduledoc """
  Shared deterministic, byte-safe helpers for building bounded model prompts.
  """

  @ellipsis "…"
  @replacement "�"
  @default_string_bytes 500
  @default_list_items 20
  @default_map_entries 20
  @default_max_depth 3
  @default_key_bytes 64
  @max_string_bytes 64_000
  @max_list_items 100
  @max_map_entries 100
  @max_depth 8
  @max_key_bytes 256
  @max_input_map_entries 20_000
  @max_input_key_bytes 4_096

  @doc """
  Truncate a UTF-8 string to at most `max_bytes` without splitting a codepoint.

  Invalid byte sequences are replaced, and an ellipsis is appended when it
  fits inside the same byte budget.
  """
  def truncate_utf8(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes >= 0 do
    cond do
      max_bytes < byte_size(@ellipsis) ->
        value |> take_sanitized_prefix(max_bytes, []) |> elem(0)

      byte_size(value) > max_bytes ->
        prefix_bytes = max_bytes - byte_size(@ellipsis)
        {prefix, _truncated?} = take_sanitized_prefix(value, prefix_bytes, [])
        prefix <> @ellipsis

      true ->
        case take_sanitized_prefix(value, max_bytes, []) do
          {sanitized, false} ->
            sanitized

          {_over_budget, true} ->
            prefix_bytes = max_bytes - byte_size(@ellipsis)
            {prefix, _truncated?} = take_sanitized_prefix(value, prefix_bytes, [])
            prefix <> @ellipsis
        end
    end
  end

  @doc """
  Truncate a string so its stable JSON encoding fits in `max_bytes`.
  """
  def encoded_string(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes >= 2 do
    value = truncate_utf8(value, max(max_bytes - 2, 0))

    if encoded_bytes(value) <= max_bytes do
      value
    else
      fit_encoded_string(value, max_bytes, 0, byte_size(value), "")
    end
  end

  @doc """
  Deterministically compact a nested value while preserving valid structure.
  """
  def compact(value, opts \\ []) when is_list(opts) do
    do_compact(value, 0, compact_settings(opts))
  end

  @doc """
  Compact a value and fit its stable JSON encoding within `max_bytes`.

  Nested collections are reduced recursively. Oversized entries are skipped
  rather than raw-byte truncating JSON or allowing one pathological entry to
  starve later entries.
  """
  def bounded(value, max_bytes, opts \\ [])
      when is_integer(max_bytes) and max_bytes >= 0 and is_list(opts) do
    compact_value = compact(value, opts)

    case fit_value(compact_value, max_bytes) do
      {:ok, fitted} -> fitted
      :drop -> nil
    end
  end

  @doc """
  Project ordered fields from a context map into one structurally valid JSON
  object whose stable encoding is no larger than `max_bytes`.

  A field may be a key or `{key, field_max_bytes}`. Earlier fields have higher
  priority, while per-field caps reserve room for later semantic sections.
  Oversized fields are skipped and projection continues. Budgets below the
  two-byte empty-object encoding return `nil` as an explicit drop sentinel.
  """
  def project_fields(context, fields, max_bytes, opts \\ [])

  def project_fields(context, fields, max_bytes, opts)
      when is_map(context) and is_list(fields) and max_bytes in 0..1 and is_list(opts),
      do: nil

  def project_fields(context, fields, max_bytes, opts)
      when is_map(context) and is_list(fields) and is_integer(max_bytes) and max_bytes >= 0 and
             is_list(opts) do
    Enum.reduce(fields, %{}, fn field, acc ->
      {key, field_max_bytes} = normalize_field(field, max_bytes)

      case read_field(context, key) do
        nil ->
          acc

        value ->
          case bounded(value, min(field_max_bytes, max_bytes), opts) do
            nil ->
              acc

            projected_value ->
              candidate = Map.put(acc, key, projected_value)
              if encoded_bytes(candidate) <= max_bytes, do: candidate, else: acc
          end
      end
    end)
  end

  def project_fields(_context, _fields, _max_bytes, _opts), do: %{}

  @doc "Return the stable JSON byte size used by prompt projectors."
  def encoded_bytes(value), do: value |> Jason.encode!() |> byte_size()

  defp compact_settings(opts) do
    %{
      string_bytes:
        opts
        |> Keyword.get(:string_bytes)
        |> positive_integer(@default_string_bytes)
        |> min(@max_string_bytes),
      list_items:
        opts
        |> Keyword.get(:list_items)
        |> non_negative_integer(@default_list_items)
        |> min(@max_list_items),
      map_entries:
        opts
        |> Keyword.get(:map_entries)
        |> non_negative_integer(@default_map_entries)
        |> min(@max_map_entries),
      max_depth:
        opts
        |> Keyword.get(:max_depth)
        |> non_negative_integer(@default_max_depth)
        |> min(@max_depth),
      key_bytes:
        opts
        |> Keyword.get(:key_bytes)
        |> positive_integer(@default_key_bytes)
        |> min(@max_key_bytes)
    }
  end

  defp do_compact(value, _depth, settings) when is_binary(value) do
    truncate_utf8(value, settings.string_bytes)
  end

  defp do_compact(%DateTime{} = value, _depth, _settings), do: DateTime.to_iso8601(value)

  defp do_compact(%NaiveDateTime{} = value, _depth, _settings),
    do: NaiveDateTime.to_iso8601(value)

  defp do_compact(%Date{} = value, _depth, _settings), do: Date.to_iso8601(value)
  defp do_compact(%Time{} = value, _depth, _settings), do: Time.to_iso8601(value)

  defp do_compact(value, depth, settings)
       when is_list(value) and depth >= settings.max_depth,
       do: []

  defp do_compact(value, depth, settings) when is_list(value) do
    value
    |> Enum.take(settings.list_items)
    |> Enum.map(&do_compact(&1, depth + 1, settings))
  end

  defp do_compact(value, depth, settings) when is_map(value) do
    if depth < settings.max_depth and map_size(value) <= @max_input_map_entries do
      value
      |> select_map_entries(settings.map_entries, settings.key_bytes)
      |> Map.new(fn {key, nested} ->
        {key, do_compact(nested, depth + 1, settings)}
      end)
    else
      %{}
    end
  end

  defp do_compact(value, _depth, _settings) when is_integer(value) do
    if value >= -9_223_372_036_854_775_808 and value <= 9_223_372_036_854_775_807,
      do: value,
      else: nil
  end

  defp do_compact(value, _depth, _settings)
       when is_float(value) or is_boolean(value) or is_nil(value),
       do: value

  defp do_compact(value, _depth, settings) do
    value
    |> inspect(pretty: false, limit: 20, printable_limit: settings.string_bytes)
    |> truncate_utf8(settings.string_bytes)
  end

  defp fit_value(value, max_bytes) do
    if encoded_bytes(value) <= max_bytes do
      {:ok, value}
    else
      do_fit_value(value, max_bytes)
    end
  end

  defp do_fit_value(value, max_bytes) when is_binary(value) and max_bytes >= 2 do
    {:ok, encoded_string(value, max_bytes)}
  end

  defp do_fit_value(value, max_bytes) when is_list(value) and max_bytes >= 2 do
    item_count = length(value)

    fitted_by_index =
      value
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {item, index}, acc ->
        fixed_bytes = encoded_indexed_list_bytes(Map.put(acc, index, nil)) - encoded_bytes(nil)
        available_bytes = max(max_bytes - fixed_bytes, 0)
        remaining_items = max(item_count - index, 1)
        item_budget = div(available_bytes, remaining_items)

        case fit_value(item, item_budget) do
          {:ok, fitted_item} ->
            candidate = Map.put(acc, index, fitted_item)

            if encoded_indexed_list_bytes(candidate) <= max_bytes,
              do: candidate,
              else: acc

          :drop ->
            acc
        end
      end)

    # Reclaim unused fair-share room in smallest-original-first order. Every
    # admitted item keeps its initial share while compact items get restored
    # before a pathological large item can consume the remainder.
    fitted_by_index =
      value
      |> Enum.with_index()
      |> Enum.sort_by(fn {item, index} -> {encoded_bytes(item), index} end)
      |> Enum.reduce(fitted_by_index, fn {item, index}, acc ->
        fixed_bytes = encoded_indexed_list_bytes(Map.put(acc, index, nil)) - encoded_bytes(nil)
        item_budget = max(max_bytes - fixed_bytes, 0)

        case fit_value(item, item_budget) do
          {:ok, fitted_item} ->
            candidate = Map.put(acc, index, fitted_item)

            if encoded_indexed_list_bytes(candidate) <= max_bytes,
              do: candidate,
              else: acc

          :drop ->
            acc
        end
      end)

    fitted = indexed_list(fitted_by_index)
    if encoded_bytes(fitted) <= max_bytes, do: {:ok, fitted}, else: :drop
  end

  defp do_fit_value(value, max_bytes) when is_map(value) and max_bytes >= 2 do
    entries = Enum.sort_by(value, fn {key, _nested} -> key end)
    entry_count = max(length(entries), 1)
    fair_entry_bytes = max(div(max_bytes, entry_count), 2)

    {fitted, _dropped} =
      Enum.reduce(entries, {%{}, []}, fn {key, nested} = entry, {acc, dropped} ->
        fixed_bytes = encoded_bytes(%{key => nil}) - encoded_bytes(nil)
        value_budget = max(fair_entry_bytes - fixed_bytes, 0)

        case fit_value(nested, value_budget) do
          {:ok, fitted_nested} ->
            candidate = Map.put(acc, key, fitted_nested)

            if encoded_bytes(candidate) <= max_bytes,
              do: {candidate, dropped},
              else: {acc, [entry | dropped]}

          :drop ->
            {acc, [entry | dropped]}
        end
      end)

    # Reclaim unused fair-share space by upgrading or adding intact values in
    # deterministic order. Never truncate an early pathological value into all
    # remaining space during this pass, so later independently fitting keys
    # still get a turn.
    fitted =
      entries
      |> Enum.sort_by(fn {key, nested} -> {encoded_bytes(nested), key} end)
      |> Enum.reduce(fitted, fn {key, nested}, acc ->
        fixed_bytes = encoded_bytes(Map.put(acc, key, nil)) - encoded_bytes(nil)
        value_budget = max(max_bytes - fixed_bytes, 0)

        case fit_value(nested, value_budget) do
          {:ok, fitted_nested} ->
            candidate = Map.put(acc, key, fitted_nested)
            if encoded_bytes(candidate) <= max_bytes, do: candidate, else: acc

          :drop ->
            acc
        end
      end)

    fitted = if fitted == %{}, do: fit_one_map_entry(entries, max_bytes), else: fitted
    if encoded_bytes(fitted) <= max_bytes, do: {:ok, fitted}, else: :drop
  end

  defp do_fit_value(_value, _max_bytes), do: :drop

  defp encoded_indexed_list_bytes(indexed), do: indexed |> indexed_list() |> encoded_bytes()

  defp indexed_list(indexed) do
    indexed
    |> Enum.sort_by(fn {index, _value} -> index end)
    |> Enum.map(fn {_index, value} -> value end)
  end

  defp fit_one_map_entry(entries, max_bytes) do
    Enum.find_value(entries, %{}, fn {key, nested} ->
      fixed_bytes = encoded_bytes(%{key => nil}) - encoded_bytes(nil)
      value_budget = max(max_bytes - fixed_bytes, 0)

      case fit_value(nested, value_budget) do
        {:ok, fitted_nested} ->
          candidate = %{key => fitted_nested}
          if encoded_bytes(candidate) <= max_bytes, do: candidate

        :drop ->
          nil
      end
    end)
  end

  defp fit_encoded_string(value, max_bytes, low, high, best) when low <= high do
    midpoint = div(low + high, 2)
    candidate = truncate_utf8(value, midpoint)

    if encoded_bytes(candidate) <= max_bytes do
      fit_encoded_string(value, max_bytes, midpoint + 1, high, candidate)
    else
      fit_encoded_string(value, max_bytes, low, midpoint - 1, best)
    end
  end

  defp fit_encoded_string(_value, _max_bytes, _low, _high, best), do: best

  defp normalize_field({key, field_max_bytes}, default_max_bytes) do
    {normalize_field_key(key), non_negative_integer(field_max_bytes, default_max_bytes)}
  end

  defp normalize_field(key, default_max_bytes) do
    {normalize_field_key(key), default_max_bytes}
  end

  defp normalize_field_key(key) when is_binary(key), do: key
  defp normalize_field_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_field_key(key), do: key |> inspect(pretty: false, limit: 5) |> truncate_utf8(64)

  defp read_field(%_{} = struct, key), do: read_field(Map.from_struct(struct), key)

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> fetch_existing_atom_key(map, key)
    end
  end

  defp read_field(_map, _key), do: nil

  defp fetch_existing_atom_key(map, key) do
    case Map.fetch(map, String.to_existing_atom(key)) do
      {:ok, value} -> value
      :error -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp select_map_entries(_value, 0, _key_bytes), do: []

  defp select_map_entries(value, limit, key_bytes) do
    value
    |> Enum.reduce([], fn {original_key, nested}, selected ->
      if unsupported_prompt_key?(original_key) do
        selected
      else
        key = prompt_key(original_key, key_bytes)
        entry = {key, prompt_key_tiebreaker(original_key), nested}
        insert_selected_map_entry(selected, entry, limit)
      end
    end)
    |> Enum.map(fn {key, _tiebreaker, nested} -> {key, nested} end)
  end

  defp unsupported_prompt_key?(key) when is_binary(key),
    do: byte_size(key) > @max_input_key_bytes

  defp unsupported_prompt_key?(key) when is_integer(key),
    do: key < -9_223_372_036_854_775_808 or key > 9_223_372_036_854_775_807

  defp unsupported_prompt_key?(key), do: not is_atom(key)

  defp insert_selected_map_entry(selected, {key, tiebreaker, nested} = entry, limit) do
    selected =
      case Enum.split_with(selected, fn {selected_key, _selected_tiebreaker, _nested} ->
             selected_key == key
           end) do
        {[], _rest} ->
          [entry | selected]

        {[{^key, selected_tiebreaker, _selected_nested}], rest} ->
          if tiebreaker < selected_tiebreaker,
            do: [{key, tiebreaker, nested} | rest],
            else: selected
      end

    selected
    |> Enum.sort_by(fn {selected_key, selected_tiebreaker, _nested} ->
      {selected_key, selected_tiebreaker}
    end)
    |> Enum.take(limit)
  end

  defp prompt_key_tiebreaker(key) when is_binary(key),
    do: {0, :crypto.hash(:sha256, key), key}

  defp prompt_key_tiebreaker(key) when is_atom(key), do: {1, <<>>, Atom.to_string(key)}

  defp prompt_key_tiebreaker(key) when is_integer(key),
    do: {2, <<>>, Integer.to_string(key)}

  defp prompt_key_tiebreaker(key),
    do: {3, <<>>, key |> inspect(pretty: false, limit: 5, printable_limit: 64)}

  defp prompt_key(key, max_bytes) when is_binary(key), do: truncate_utf8(key, max_bytes)

  defp prompt_key(key, max_bytes) when is_atom(key),
    do: key |> Atom.to_string() |> truncate_utf8(max_bytes)

  defp prompt_key(key, max_bytes) when is_integer(key),
    do: key |> Integer.to_string() |> truncate_utf8(max_bytes)

  defp prompt_key(key, max_bytes) do
    key
    |> inspect(pretty: false, limit: 5, printable_limit: max_bytes)
    |> truncate_utf8(max_bytes)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp take_sanitized_prefix("", _remaining, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), false}
  end

  defp take_sanitized_prefix(_value, 0, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), true}
  end

  defp take_sanitized_prefix(value, remaining, acc) do
    {codepoint, rest} = String.next_codepoint(value)
    sanitized = if String.valid?(codepoint), do: codepoint, else: @replacement

    if byte_size(sanitized) <= remaining do
      take_sanitized_prefix(rest, remaining - byte_size(sanitized), [sanitized | acc])
    else
      {acc |> Enum.reverse() |> IO.iodata_to_binary(), true}
    end
  end
end
