defmodule Maraithon.AssistantHarness.ToolLoopClassifier do
  @moduledoc """
  Classifies assistant tool-loop failures from compact tool history.
  """

  @default_window_size 3

  def classify(tool_history, opts \\ [])

  def classify(tool_history, opts) when is_list(tool_history) and is_list(opts) do
    window_size = opts |> Keyword.get(:window_size, @default_window_size) |> positive_integer()

    if window_size <= 1 do
      :ok
    else
      observations =
        tool_history
        |> Enum.map(&tool_observation/1)
        |> Enum.reject(&is_nil/1)

      latest = List.last(observations)

      cond do
        is_nil(latest) ->
          :ok

        loop = unknown_tool_repeat(observations, latest, window_size) ->
          {:loop, loop}

        loop = ping_pong(observations, latest) ->
          {:loop, loop}

        loop = post_compaction_repeat(observations, latest, window_size) ->
          {:loop, loop}

        loop = same_tool_args(observations, latest, window_size) ->
          {:loop, loop}

        loop = polling_no_progress(observations, latest, window_size) ->
          {:loop, loop}

        true ->
          :ok
      end
    end
  end

  def classify(_tool_history, _opts), do: :ok

  defp unknown_tool_repeat(observations, %{unknown_tool?: true} = latest, window_size) do
    count =
      observations
      |> Enum.count(&(&1.tool == latest.tool and &1.unknown_tool?))

    if count >= window_size do
      loop("unknown_tool_repeat", latest.tool, count, latest)
    end
  end

  defp unknown_tool_repeat(_observations, _latest, _window_size), do: nil

  defp ping_pong(observations, latest) do
    recent = observations |> Enum.reverse() |> Enum.take(4) |> Enum.reverse()

    case recent do
      [
        %{tool: tool_a},
        %{tool: tool_b},
        %{tool: tool_c},
        %{tool: tool_d}
      ]
      when tool_a != tool_b and tool_a == tool_c and tool_b == tool_d ->
        loop("ping_pong", latest.tool, length(recent), latest, %{
          partner_tool: tool_b
        })

      _other ->
        nil
    end
  end

  defp post_compaction_repeat(observations, latest, window_size) do
    compacted_repeats =
      observations
      |> Enum.filter(&(&1.tool == latest.tool and &1.compacted?))
      |> length()

    if latest.compacted? and compacted_repeats >= min(window_size, 2) do
      loop("post_compaction_repeat", latest.tool, compacted_repeats, latest)
    end
  end

  defp same_tool_args(observations, latest, window_size) do
    count =
      observations
      |> Enum.count(fn observation ->
        observation.tool == latest.tool and
          observation.arguments_hash == latest.arguments_hash and
          observation.outcome_hash == latest.outcome_hash
      end)

    if count >= window_size do
      loop("same_tool_args", latest.tool, count, latest)
    end
  end

  defp polling_no_progress(observations, latest, window_size) do
    same_tool =
      observations
      |> Enum.filter(&(&1.tool == latest.tool))
      |> Enum.take(-window_size)

    distinct_args = same_tool |> Enum.map(& &1.arguments_hash) |> Enum.uniq() |> length()
    distinct_outcomes = same_tool |> Enum.map(& &1.outcome_hash) |> Enum.uniq()

    if length(same_tool) >= window_size and distinct_args > 1 and
         distinct_outcomes == [latest.outcome_hash] do
      loop("polling_no_progress", latest.tool, length(same_tool), latest)
    end
  end

  defp loop(class, tool, count, latest, metadata \\ %{}) do
    %{
      class: class,
      tool: tool,
      count: count,
      arguments_hash: latest.arguments_hash,
      outcome_hash: latest.outcome_hash,
      metadata: metadata
    }
  end

  defp tool_observation(entry) when is_map(entry) do
    tool = Map.get(entry, "tool") || Map.get(entry, :tool)
    arguments = Map.get(entry, "arguments") || Map.get(entry, :arguments) || %{}
    result = Map.get(entry, "result") || Map.get(entry, :result)
    error = Map.get(entry, "error") || Map.get(entry, :error)

    if is_binary(tool) and (not is_nil(result) or not is_nil(error)) do
      %{
        tool: tool,
        arguments_hash: stable_hash(arguments),
        outcome_hash: stable_hash(if(is_nil(result), do: %{"error" => error}, else: result)),
        unknown_tool?: unknown_tool_error?(error),
        compacted?: compacted_value?(result) or compacted_value?(error)
      }
    end
  end

  defp tool_observation(_entry), do: nil

  defp unknown_tool_error?(error) when is_binary(error) do
    normalized = String.downcase(error)
    String.contains?(normalized, "unknown_tool") or String.contains?(normalized, "unknown tool")
  end

  defp unknown_tool_error?({:assistant_harness_unknown_tool, _tool}), do: true
  defp unknown_tool_error?({:unknown_tool, _tool}), do: true
  defp unknown_tool_error?(_error), do: false

  defp compacted_value?(%{} = value) do
    Enum.any?(value, fn {key, nested} ->
      key_string = to_string(key)
      String.starts_with?(key_string, "_truncated") or compacted_value?(nested)
    end)
  end

  defp compacted_value?(value) when is_list(value), do: Enum.any?(value, &compacted_value?/1)
  defp compacted_value?(_value), do: false

  defp stable_hash(value) do
    value
    |> stable_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stable_json(value) do
    case Jason.encode(compact_hash_value(value)) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value)
    end
  end

  defp compact_hash_value(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Map.new(fn {key, nested_value} -> {to_string(key), compact_hash_value(nested_value)} end)
  end

  defp compact_hash_value(value) when is_list(value), do: Enum.map(value, &compact_hash_value/1)
  defp compact_hash_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp compact_hash_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp compact_hash_value(%Date{} = value), do: Date.to_iso8601(value)
  defp compact_hash_value(%Time{} = value), do: Time.to_iso8601(value)

  defp compact_hash_value(value) when is_struct(value),
    do: value |> Map.from_struct() |> compact_hash_value()

  defp compact_hash_value(value) when is_tuple(value), do: inspect(value)
  defp compact_hash_value(value) when is_pid(value), do: inspect(value)
  defp compact_hash_value(value) when is_reference(value), do: inspect(value)
  defp compact_hash_value(value) when is_function(value), do: inspect(value)
  defp compact_hash_value(value), do: value

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> @default_window_size
    end
  end

  defp positive_integer(_value), do: @default_window_size
end
