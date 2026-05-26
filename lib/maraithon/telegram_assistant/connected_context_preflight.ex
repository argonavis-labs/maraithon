defmodule Maraithon.TelegramAssistant.ConnectedContextPreflight do
  @moduledoc """
  Mechanical connected-context review for person and relationship questions.

  The prompt asks the model to use `review_connected_context`; this module makes
  that behavior deterministic for the high-risk cases where a generic answer is
  worse than waiting briefly for connected evidence.
  """

  alias Maraithon.Tools

  @sources ~w(crm gmail google_contacts calendar slack open_loops memory)
  @preflight_timeout_ms 8_000

  def apply(context, attrs) when is_map(context) and is_map(attrs) do
    with true <- should_review?(context, attrs),
         user_id when is_binary(user_id) <- read_user_id(context, attrs),
         query when is_binary(query) <- review_query(context, attrs),
         true <- String.trim(query) != "" do
      run_review(context, user_id, query)
    else
      _other -> context
    end
  end

  def apply(context, _attrs), do: context

  defp run_review(context, user_id, query) do
    args = %{
      "user_id" => user_id,
      "query" => query,
      "sources" => @sources,
      "max_results" => 5,
      "since_days" => 180,
      "timeout_ms" => @preflight_timeout_ms
    }

    case Tools.execute("review_connected_context", args, %{
           surface: "internal",
           user_id: user_id,
           confirmed?: true
         }) do
      {:ok, result} ->
        maybe_learn_async(user_id, result)

        Map.put(context, :connected_context_review, %{
          "status" => "reviewed",
          "mandatory" => true,
          "query" => query,
          "sources" => Map.get(result, :reviewed_sources) || Map.get(result, "reviewed_sources"),
          "result" => normalize_json_value(result),
          "learning_enqueued" => source_observations(result) != []
        })

      {:error, reason} ->
        Map.put(context, :connected_context_review, %{
          "status" => "failed",
          "mandatory" => true,
          "query" => query,
          "error" => normalize_error(reason)
        })
    end
  rescue
    error ->
      Map.put(context, :connected_context_review, %{
        "status" => "failed",
        "mandatory" => true,
        "query" => query,
        "error" => Exception.message(error)
      })
  end

  defp maybe_learn_async(user_id, result) do
    observations = source_observations(result)

    if observations != [] do
      Task.start(fn ->
        Tools.execute(
          "learn_relationship_context",
          %{
            "user_id" => user_id,
            "observations" => observations,
            "source" => "telegram_connected_context_preflight"
          },
          %{surface: "internal", user_id: user_id, confirmed?: true}
        )
      end)
    end

    :ok
  end

  defp source_observations(result) when is_map(result) do
    result
    |> read_field("source_observations")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp source_observations(_result), do: []

  defp should_review?(context, attrs) do
    focus = request_focus(context, attrs)
    text = latest_text(context, attrs)

    focus == :person_context or
      (focus == :linked_item_context and linked_context_question?(text)) or
      person_context_text?(text)
  end

  defp person_context_text?(text) when is_binary(text) do
    normalized = String.downcase(text)

    Regex.match?(~r/\bwho\s+(is|are)\s+(?!this|that|they|them|he|she|it)\p{L}/u, normalized) or
      Regex.match?(~r/\b(tell|remind)\s+me\s+about\s+\p{L}/u, normalized) or
      Regex.match?(~r/\bwhat\s+do\s+i\s+owe\s+\p{L}/u, normalized) or
      Regex.match?(~r/\bwhat\s+does\s+\p{L}.*\b(need|want|expect)\b/u, normalized) or
      Regex.match?(~r/\bwhat\s+should\s+i\s+know\s+about\s+\p{L}/u, normalized)
  end

  defp person_context_text?(_text), do: false

  defp linked_context_question?(text) when is_binary(text) do
    normalized = String.downcase(text)

    Regex.match?(~r/\bwho\s+(is|are)\s+(this|that|they|them|he|she|it|person)\b/u, normalized) or
      Regex.match?(
        ~r/\b(context|more context|remind me|why does this matter|what is this)\b/u,
        normalized
      )
  end

  defp linked_context_question?(_text), do: false

  defp review_query(context, attrs) do
    text = latest_text(context, attrs)

    named_query(text) ||
      linked_person_query(context) ||
      text
      |> to_string()
      |> String.slice(0, 120)
      |> String.trim()
  end

  defp named_query(text) when is_binary(text) do
    patterns = [
      ~r/\bwho\s+(?:is|are)\s+([^?.!,]+?)(?:\s+(?:again|today|now))?\s*$/iu,
      ~r/\b(?:tell|remind)\s+me\s+about\s+([^?.!,]+?)\s*$/iu,
      ~r/\bwhat\s+do\s+i\s+owe\s+([^?.!,]+?)\s*$/iu,
      ~r/\bwhat\s+should\s+i\s+know\s+about\s+([^?.!,]+?)\s*$/iu
    ]

    patterns
    |> Enum.find_value(fn pattern ->
      case Regex.run(pattern, text) do
        [_full, query] -> clean_query(query)
        _other -> nil
      end
    end)
    |> reject_pronoun_query()
  end

  defp named_query(_text), do: nil

  defp linked_person_query(context) do
    linked = read_field(context, "linked_item") || %{}
    todo = read_field(linked, "todo") || %{}
    insight = read_field(linked, "insight") || %{}

    [
      read_field(todo, "title"),
      read_field(todo, "summary"),
      read_field(todo, "next_action"),
      read_field(insight, "title"),
      read_field(insight, "summary")
    ]
    |> Enum.find_value(&first_person_name/1)
  end

  defp first_person_name(text) when is_binary(text) do
    case Regex.run(~r/\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3}\b/u, text) do
      [name] -> clean_query(name)
      _other -> nil
    end
  end

  defp first_person_name(_text), do: nil

  defp reject_pronoun_query(query) when is_binary(query) do
    if String.downcase(query) in ~w(this that they them he she it person) do
      nil
    else
      query
    end
  end

  defp reject_pronoun_query(_query), do: nil

  defp clean_query(query) when is_binary(query) do
    query
    |> String.replace(~r/\s+/, " ")
    |> String.trim(" .?!,:;-")
    |> case do
      "" -> nil
      value -> String.slice(value, 0, 120)
    end
  end

  defp latest_text(_context, attrs) do
    Map.get(attrs, :text) || Map.get(attrs, "text") || ""
  end

  defp request_focus(context, attrs) do
    (Map.get(attrs, :request_focus) ||
       Map.get(attrs, "request_focus") ||
       get_in(attrs, [:model_profile, :request_focus]) ||
       get_in(attrs, ["model_profile", "request_focus"]) ||
       Map.get(context, :request_focus) ||
       Map.get(context, "request_focus"))
    |> normalize_focus()
  end

  defp normalize_focus(value) when is_atom(value), do: value

  defp normalize_focus(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "linked_item_context" -> :linked_item_context
      "person_context" -> :person_context
      _other -> nil
    end
  end

  defp normalize_focus(_value), do: nil

  defp read_user_id(context, attrs) do
    Map.get(attrs, :user_id) ||
      Map.get(attrs, "user_id") ||
      get_in(context, [:user, :id]) ||
      get_in(context, ["user", "id"])
  end

  defp read_field(%_{} = struct, key), do: read_field(Map.from_struct(struct), key)

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _other ->
          nil
      end)
  end

  defp read_field(_map, _key), do: nil

  defp normalize_json_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp normalize_json_value(%Date{} = date), do: Date.to_iso8601(date)
  defp normalize_json_value(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)

  defp normalize_json_value(value) when is_list(value),
    do: Enum.map(value, &normalize_json_value/1)

  defp normalize_json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_json_value(nested)} end)
  end

  defp normalize_json_value(value), do: value

  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: inspect(reason)
end
