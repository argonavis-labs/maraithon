defmodule Maraithon.Todos.FeedbackTrainer do
  @moduledoc """
  Model-backed training for todo relevance feedback.

  The trainer turns one explicit "see less like this" action into a durable
  negative memory. It asks the model to infer the general pattern instead of
  hard-coding sender, title, or source-text suppression rules in Elixir.
  """

  alias Maraithon.{LLM, Memory}
  alias Maraithon.Todos.AttentionRanker
  alias Maraithon.Todos.Todo

  @sentinel "TODO_SEE_LESS_TRAINING_JSON_V1"
  @default_max_tokens 2_000
  @default_timeout_ms 120_000

  def sentinel, do: @sentinel

  def train_see_less(user_id, todo, opts \\ [])

  def train_see_less(user_id, %Todo{} = todo, opts) when is_binary(user_id) do
    source = normalized_source(Keyword.get(opts, :source, "todo_surface"))
    now = Keyword.get(opts, :now, DateTime.utc_now())
    prompt = build_prompt(user_id, todo, source, now)

    with llm_complete when is_function(llm_complete, 1) <- llm_complete(opts),
         {:ok, response} <- llm_complete.(prompt),
         {:ok, decoded} <- decode_response(response),
         {:ok, training} <- normalize_training(decoded, todo, source, now),
         {:ok, memory} <- Memory.write(user_id, memory_attrs(training, todo, source, now)) do
      {:ok, %{memory: memory, training: training}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :todo_see_less_training_failed}
    end
  end

  def train_see_less(_user_id, _todo, _opts), do: {:error, :invalid_todo}

  defp build_prompt(user_id, %Todo{} = todo, source, now) do
    payload = %{
      "user_id" => user_id,
      "feedback" => "see_less",
      "source" => source,
      "generated_at" => normalize_json_value(now),
      "todo" => todo_snapshot(todo),
      "attention_profile" => AttentionRanker.profile(todo, now: now)
    }

    """
    #{@sentinel}

    Maraithon's operator marked this todo as "see less like this".

    Infer the durable negative todo-relevance pattern that should steer future
    todo creation. Do not create brittle rules based on exact title text, exact
    sender, exact thread id, or source name alone. Use semantic judgment over
    actionability, ask/no-ask, owner, relationship, urgency, life domain, source
    evidence, and whether someone is actually waiting on Kent.

    Return ONLY valid JSON:
    {
      "title": "See less: short pattern title",
      "summary": "one sentence summary",
      "content": "durable instruction for future todo surfacing",
      "pattern_key": "stable_snake_case_pattern_key",
      "categories": ["short", "tags"],
      "negative_signals": ["signals that indicate this should be suppressed"],
      "exceptions": ["signals that should still allow surfacing"],
      "confidence": 0.85,
      "reasoning": "why this todo teaches that pattern"
    }

    Rules:
    - Prefer a pattern narrow enough to avoid hiding genuinely important work.
    - If the selected todo is only weak evidence, say so in reasoning and use
      lower confidence rather than inventing a broad rule.
    - Content should be written as a user preference the todo-intelligence model
      can apply later.
    - Include exception signals for personal/family impact, a close relationship,
      an explicit deadline, a customer/user impact, or a direct ask when relevant.

    TODO_FEEDBACK_PAYLOAD_JSON:
    #{Jason.encode!(normalize_json_value(payload))}
    """
  end

  defp llm_complete(opts) do
    Keyword.get(opts, :llm_complete) || configured_llm_complete(opts)
  end

  defp configured_llm_complete(opts) do
    config = Application.get_env(:maraithon, :todos, [])

    case Keyword.get(config, :see_less_llm_complete) || Keyword.get(config, :llm_complete) do
      fun when is_function(fun, 1) -> fun
      _other -> &default_llm_complete(&1, opts)
    end
  end

  defp default_llm_complete(prompt, opts) when is_binary(prompt) do
    config = Application.get_env(:maraithon, :todos, [])

    params = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" =>
        Keyword.get(
          opts,
          :max_tokens,
          Keyword.get(config, :see_less_max_tokens, @default_max_tokens)
        ),
      "temperature" => 0.1,
      "reasoning_effort" =>
        Keyword.get(
          opts,
          :reasoning_effort,
          Keyword.get(config, :reasoning_effort, LLM.intelligence())
        ),
      "timeout_ms" =>
        Keyword.get(opts, :timeout_ms, Keyword.get(config, :timeout_ms, @default_timeout_ms))
    }

    case LLM.complete(params) do
      {:error, {:llm_provider_not_configured, _message}} = error ->
        if mock_when_unconfigured?() do
          Maraithon.LLM.MockProvider.complete(params)
        else
          error
        end

      result ->
        result
    end
  end

  defp mock_when_unconfigured? do
    :maraithon
    |> Application.get_env(:todos, [])
    |> Keyword.get(:mock_llm_when_unconfigured, false)
  end

  defp decode_response(%{content: content}), do: decode_response(content)
  defp decode_response(%{"content" => content}), do: decode_response(content)

  defp decode_response(content) when is_binary(content) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> {:error, :todo_see_less_training_invalid_json}
    end
  end

  defp decode_response(_response), do: {:error, :todo_see_less_training_invalid_json}

  defp normalize_training(decoded, %Todo{} = todo, source, now) when is_map(decoded) do
    title =
      decoded
      |> read_string("title", "See less: #{short_text(todo.title || todo.summary, 96)}")
      |> truncate(220)

    summary =
      read_string(
        decoded,
        "summary",
        "Show fewer todos that match this low-value pattern."
      )

    content =
      read_string(
        decoded,
        "content",
        "Show fewer todos like #{todo.title || "this item"} unless fresh evidence makes them actionable."
      )

    pattern_key =
      decoded
      |> read_string("pattern_key", title)
      |> slug_key()

    training =
      %{
        "title" => title,
        "summary" => truncate(summary, 2_000),
        "content" => truncate(content, 10_000),
        "pattern_key" => pattern_key,
        "categories" => read_string_list(decoded, "categories"),
        "negative_signals" => read_string_list(decoded, "negative_signals"),
        "exceptions" => read_string_list(decoded, "exceptions"),
        "confidence" => read_float(decoded, "confidence", 0.85),
        "reasoning" =>
          read_string(decoded, "reasoning", "The operator asked to see fewer todos like this."),
        "source" => source,
        "trained_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

    {:ok, training}
  end

  defp normalize_training(_decoded, _todo, _source, _now) do
    {:error, :todo_see_less_training_invalid_json}
  end

  defp memory_attrs(training, %Todo{} = todo, source, now) do
    %{
      "kind" => "relevance_feedback",
      "scope" => "user",
      "title" => training["title"],
      "content" => training["content"],
      "summary" => training["summary"],
      "source" => "todo_see_less",
      "source_ref_type" => "todo",
      "source_ref_id" => todo.id,
      "author_type" => "user",
      "tags" => memory_tags(training),
      "importance" => 85,
      "confidence" => training["confidence"],
      "polarity" => "negative",
      "dedupe_key" => "todo_see_less:#{training["pattern_key"]}",
      "metadata" => %{
        "trainer" => @sentinel,
        "feedback" => "see_less",
        "feedback_source" => source,
        "pattern_key" => training["pattern_key"],
        "categories" => training["categories"],
        "negative_signals" => training["negative_signals"],
        "exceptions" => training["exceptions"],
        "reasoning" => training["reasoning"],
        "todo" => todo_snapshot(todo),
        "evidence" => %{
          "quote" => evidence_quote(todo),
          "source" => "todo:#{todo.id}"
        },
        "recorded_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }
    }
  end

  defp memory_tags(training) do
    (["todo_relevance", "see_less", "negative_feedback"] ++ training["categories"])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&slug_key/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp todo_snapshot(%Todo{} = todo) do
    %{
      "id" => todo.id,
      "source" => todo.source,
      "source_account_id" => todo.source_account_id,
      "source_account_label" => todo.source_account_label,
      "kind" => todo.kind,
      "attention_mode" => todo.attention_mode,
      "status" => todo.status,
      "title" => todo.title,
      "summary" => todo.summary,
      "next_action" => todo.next_action,
      "due_at" => normalize_json_value(todo.due_at),
      "notes" => todo.notes,
      "action_plan" => todo.action_plan,
      "owner_user_id" => todo.owner_user_id,
      "owner_label" => todo.owner_label,
      "priority" => todo.priority,
      "source_item_id" => todo.source_item_id,
      "source_occurred_at" => normalize_json_value(todo.source_occurred_at),
      "dedupe_key" => todo.dedupe_key,
      "metadata" => todo.metadata || %{},
      "inserted_at" => normalize_json_value(todo.inserted_at),
      "updated_at" => normalize_json_value(todo.updated_at)
    }
    |> compact_map()
  end

  defp evidence_quote(%Todo{} = todo) do
    [
      todo.title,
      todo.summary,
      todo.next_action
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" | ")
    |> case do
      "" -> "Todo #{todo.id}"
      text -> truncate(text, 500)
    end
  end

  defp read_string(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      _other ->
        default
    end
  end

  defp read_string_list(attrs, key) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(12)

      value when is_binary(value) ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(12)

      _other ->
        []
    end
  end

  defp read_float(attrs, key, default) when is_map(attrs) do
    case fetch_attr(attrs, key) do
      value when is_float(value) ->
        clamp_float(value)

      value when is_integer(value) ->
        clamp_float(value / 1)

      value when is_binary(value) ->
        case Float.parse(String.trim(value)) do
          {parsed, ""} -> clamp_float(parsed)
          _other -> default
        end

      _other ->
        default
    end
  end

  defp clamp_float(value), do: value |> max(0.0) |> min(1.0)

  defp fetch_attr(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        case existing_atom_key(key) do
          atom_key when is_atom(atom_key) -> Map.get(attrs, atom_key)
          _other -> nil
        end
    end
  end

  defp slug_key(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9:_-]+/u, "_")
    |> String.trim("_")
    |> truncate(160)
  end

  defp slug_key(_value), do: ""

  defp short_text(value, max_length) when is_binary(value), do: truncate(value, max_length)
  defp short_text(_value, _max_length), do: "this todo"

  defp truncate(value, max_length) when is_binary(value) do
    if String.length(value) > max_length do
      value
      |> String.slice(0, max_length)
      |> String.trim()
    else
      value
    end
  end

  defp truncate(value, _max_length), do: value

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp normalize_json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_json_value(%Time{} = value), do: Time.to_iso8601(value)

  defp normalize_json_value(value) when is_list(value),
    do: Enum.map(value, &normalize_json_value/1)

  defp normalize_json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_json_value(nested)} end)
  end

  defp normalize_json_value(value), do: value

  defp normalized_source(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "todo_surface"
      source -> source
    end
  end

  defp normalized_source(_value), do: "todo_surface"

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
