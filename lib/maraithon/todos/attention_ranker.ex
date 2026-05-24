defmodule Maraithon.Todos.AttentionRanker do
  @moduledoc """
  Small deterministic attention hints for open-loop ordering.

  This is intentionally not the semantic decision layer. It gives the model and
  Telegram renderers a stable first pass that reflects the product priority
  stack: personal/family first, strong relationships waiting, active business
  obligations, intros, meetings, then everything else.
  """

  @family_terms ~w(
    family personal home household school child children kid kids daughter son spouse wife
    husband parent teacher camp health doctor dentist medication birthday anniversary
  )
  @waiting_terms ~w(
    waiting blocked unblock owe owes owed committed promise promised follow-up followup
    reply respond response delivery deliver eta deadline due customer client project
    objective decision approve approval pricing status artifact
  )
  @intro_terms ~w(intro introduction introduce connect)
  @meeting_terms ~w(meeting meet call schedule scheduling book booking calendar time availability)
  @company_keys ~w(company organization org employer workplace account customer customer_company)
  @relationship_keys ~w(relationship relationship_context relationship_note role title)
  @why_keys ~w(why_it_matters context context_brief project project_name)

  @bucket_order %{
    "personal_family" => 0,
    "strong_relationship_waiting" => 1,
    "business_project_waiting" => 2,
    "intro_request" => 3,
    "meeting_request" => 4,
    "other" => 5
  }

  def sort(todos, opts \\ []) when is_list(todos) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Enum.sort_by(todos, fn todo ->
      profile = profile(todo, now: now)

      {
        Map.get(@bucket_order, profile["bucket"], 99),
        -profile["score"],
        due_sort_value(read_field(todo, "due_at")),
        -timestamp_sort_value(first_datetime(todo))
      }
    end)
  end

  def profile(todo, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    metadata = metadata(todo)
    text = text_blob(todo, metadata)
    priority = clamp(read_integer(todo, "priority", 50), 0, 100)
    relationship_strength = relationship_strength(todo, metadata)

    personal_family? = personal_family?(text, metadata)
    waiting? = waiting?(text, metadata)
    intro? = contains_any?(text, @intro_terms)
    meeting? = contains_any?(text, @meeting_terms)
    business? = business_project?(text, metadata)
    stale? = stale?(todo, now)

    bucket =
      cond do
        personal_family? -> "personal_family"
        relationship_strength >= 60 and waiting? -> "strong_relationship_waiting"
        waiting? or business? -> "business_project_waiting"
        intro? -> "intro_request"
        meeting? -> "meeting_request"
        true -> "other"
      end

    score =
      bucket_base(bucket) +
        relationship_score(relationship_strength) +
        priority +
        due_bonus(read_field(todo, "due_at"), now) +
        freshness_bonus(first_datetime(todo), now) -
        stale_penalty(stale?, bucket, priority)

    %{
      "bucket" => bucket,
      "bucket_rank" => Map.get(@bucket_order, bucket, 99),
      "score" => clamp(score, 0, 1_000),
      "relationship_strength" => relationship_strength,
      "interaction_count" => interaction_count(metadata),
      "communication_frequency" => communication_frequency(metadata),
      "personal_family" => personal_family?,
      "actively_waiting" => waiting?,
      "business_project" => business?,
      "intro_request" => intro?,
      "meeting_request" => meeting?,
      "stale_confirmation_candidate" => stale_confirmation_candidate?(stale?, bucket, priority),
      "age_days" => age_days(first_datetime(todo), now),
      "context" => context_summary(todo, metadata)
    }
  end

  defp bucket_base("personal_family"), do: 600
  defp bucket_base("strong_relationship_waiting"), do: 500
  defp bucket_base("business_project_waiting"), do: 400
  defp bucket_base("intro_request"), do: 300
  defp bucket_base("meeting_request"), do: 220
  defp bucket_base(_), do: 100

  defp relationship_score(value), do: min(value || 0, 100)

  defp due_bonus(%DateTime{} = due_at, %DateTime{} = now) do
    hours_until = DateTime.diff(due_at, now, :hour)

    cond do
      hours_until < 0 -> 80
      hours_until <= 24 -> 70
      hours_until <= 72 -> 35
      true -> 0
    end
  end

  defp due_bonus(_due_at, _now), do: 0

  defp freshness_bonus(%DateTime{} = occurred_at, %DateTime{} = now) do
    hours_old = max(DateTime.diff(now, occurred_at, :hour), 0)

    cond do
      hours_old <= 6 -> 40
      hours_old <= 24 -> 25
      hours_old <= 72 -> 10
      true -> 0
    end
  end

  defp freshness_bonus(_occurred_at, _now), do: 0

  defp stale_penalty(true, bucket, priority)
       when bucket not in ["personal_family", "strong_relationship_waiting"] and priority < 85,
       do: 120

  defp stale_penalty(_stale?, _bucket, _priority), do: 0

  defp stale_confirmation_candidate?(true, bucket, priority)
       when bucket not in ["personal_family", "strong_relationship_waiting"] and priority < 85,
       do: true

  defp stale_confirmation_candidate?(_stale?, _bucket, _priority), do: false

  defp stale?(todo, now) do
    case first_datetime(todo) do
      %DateTime{} = datetime -> DateTime.diff(now, datetime, :hour) >= 72
      _ -> false
    end
  end

  defp age_days(%DateTime{} = datetime, %DateTime{} = now),
    do: div(max(DateTime.diff(now, datetime, :second), 0), 86_400)

  defp age_days(_datetime, _now), do: nil

  defp first_datetime(todo) do
    [
      read_datetime(todo, "source_occurred_at"),
      read_datetime(todo, "inserted_at"),
      read_datetime(todo, "updated_at")
    ]
    |> Enum.find(&match?(%DateTime{}, &1))
  end

  defp due_sort_value(%DateTime{} = due_at), do: DateTime.to_unix(due_at, :second)
  defp due_sort_value(_due_at), do: 4_102_444_800

  defp timestamp_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :second)
  defp timestamp_sort_value(_datetime), do: 0

  defp personal_family?(text, metadata) do
    domain =
      [
        read_metadata(metadata, "life_domain"),
        read_metadata(metadata, "suggested_life_domain"),
        read_metadata(metadata, "omni_project")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(domain, "personal") or String.contains?(domain, "home") or
      String.contains?(domain, "family") or contains_any?(text, @family_terms)
  end

  defp waiting?(text, metadata) do
    direction = read_metadata(metadata, "commitment_direction")

    direction in ["i_owe", "asked_of_me", "pending_reply"] or contains_any?(text, @waiting_terms)
  end

  defp business_project?(text, metadata) do
    tags =
      metadata
      |> read_metadata_list("source_tags")
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(tags, "runner") or String.contains?(tags, "customer") or
      String.contains?(tags, "project") or
      contains_any?(text, ~w(customer client project launch pricing eta delivery business))
  end

  defp contains_any?(text, terms) when is_binary(text) do
    Enum.any?(terms, fn term -> String.contains?(text, term) end)
  end

  defp contains_any?(_text, _terms), do: false

  defp relationship_strength(todo, metadata) do
    [
      read_integer(metadata, "relationship_strength", nil),
      read_integer(metadata, "relationshipStrength", nil),
      metadata |> read_metadata("record") |> read_integer("relationship_strength", nil),
      metadata |> read_metadata("record") |> read_integer("relationshipStrength", nil),
      read_integer(todo, "relationship_strength", nil),
      metadata |> read_metadata_list("crm_people") |> strongest_person_score(),
      metadata |> read_metadata_list("people") |> strongest_person_score()
    ]
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  defp strongest_person_score(people) when is_list(people) do
    people
    |> Enum.map(fn
      %{} = person ->
        read_integer(
          person,
          "relationship_strength",
          read_integer(person, "relationshipStrength", 0)
        )

      _ ->
        0
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp context_summary(todo, metadata) do
    %{}
    |> maybe_put("person", person_label(todo, metadata))
    |> maybe_put("company", first_metadata_value(metadata, @company_keys))
    |> maybe_put("relationship", first_metadata_value(metadata, @relationship_keys))
    |> maybe_put("why", first_metadata_value(metadata, @why_keys) || record_context(metadata))
    |> maybe_put("source_account", read_field(todo, "source_account_label"))
  end

  defp interaction_count(metadata) do
    [
      read_integer(metadata, "interaction_count", nil),
      metadata |> read_metadata("record") |> read_integer("interaction_count", nil)
    ]
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  defp communication_frequency(metadata) do
    read_metadata(metadata, "communication_frequency") ||
      metadata |> read_metadata("record") |> read_metadata("communication_frequency")
  end

  defp person_label(todo, metadata) do
    [
      read_metadata(metadata, "person"),
      metadata |> read_metadata("record") |> read_metadata("person"),
      read_field(todo, "owner_label"),
      first_person_name(read_metadata_list(metadata, "crm_people")),
      first_person_name(read_metadata_list(metadata, "people"))
    ]
    |> Enum.find(&present?/1)
  end

  defp first_person_name([%{} = person | _]) do
    [
      read_field(person, "display_name"),
      [read_field(person, "first_name"), read_field(person, "last_name")]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
    ]
    |> Enum.find(&present?/1)
  end

  defp first_person_name(_people), do: nil

  defp first_metadata_value(metadata, keys) do
    Enum.find_value(keys, fn key ->
      read_metadata(metadata, key) ||
        metadata |> read_metadata("record") |> read_metadata(key)
    end)
  end

  defp record_context(metadata) do
    record = read_metadata(metadata, "record")

    [
      read_metadata(record, "ask"),
      read_metadata(record, "commitment"),
      read_metadata(record, "summary")
    ]
    |> Enum.find(&present?/1)
  end

  defp text_blob(todo, metadata) do
    [
      read_field(todo, "title"),
      read_field(todo, "summary"),
      read_field(todo, "next_action"),
      read_field(todo, "notes"),
      read_field(todo, "action_plan"),
      read_metadata(metadata, "why_now"),
      read_metadata(metadata, "context"),
      read_metadata(metadata, "context_brief"),
      read_metadata(metadata, "relationship"),
      read_metadata(metadata, "company"),
      metadata |> read_metadata("record") |> read_metadata("commitment"),
      metadata |> read_metadata("record") |> read_metadata("summary"),
      metadata |> read_metadata("record") |> read_metadata("ask"),
      metadata |> read_metadata_list("source_tags") |> Enum.join(" ")
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp metadata(todo) do
    case read_field(todo, "metadata") do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_metadata(nil, _key), do: nil
  defp read_metadata(value, _key) when not is_map(value), do: nil
  defp read_metadata(map, key), do: read_field(map, key)

  defp read_metadata_list(map, key) when is_map(map) do
    case read_field(map, key) do
      values when is_list(values) -> values
      value when is_map(value) -> [value]
      value when is_binary(value) and value != "" -> [value]
      _ -> []
    end
  end

  defp read_metadata_list(_map, _key), do: []

  defp read_field(%_{} = struct, key), do: read_field(Map.from_struct(struct), key)

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _ ->
          nil
      end)
  end

  defp read_field(_map, _key), do: nil

  defp read_integer(map, key, default) do
    case read_field(map, key) do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        round(value)

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_datetime(map, key) do
    case read_field(map, key) do
      %DateTime{} = datetime ->
        datetime

      %NaiveDateTime{} = naive ->
        DateTime.from_naive!(naive, "Etc/UTC")

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
