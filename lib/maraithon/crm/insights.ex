defmodule Maraithon.Crm.Insights do
  @moduledoc """
  Deterministic CRM insight suggestions for operator review.

  This module is intentionally request-path safe: it scans existing CRM rows
  and observations without calling an LLM, then returns bounded suggestions
  that the UI can render as review cards.
  """

  import Ecto.Query

  alias Maraithon.Crm
  alias Maraithon.Crm.{Observation, Person, PersonLink}
  alias Maraithon.Repo

  @default_people_limit 100
  @default_observation_limit 250
  @default_link_limit 250
  @default_suggestion_limit 25

  @contact_kinds [
    {"emails", "email"},
    {"phones", "phone"},
    {"slack_ids", "Slack id"},
    {"telegram_ids", "Telegram id"}
  ]

  @relationship_labels [
    %{label: "wife", pattern: "wife"},
    %{label: "husband", pattern: "husband"},
    %{label: "spouse", pattern: "spouse"},
    %{label: "daughter", pattern: "daughter"},
    %{label: "son", pattern: "son"},
    %{label: "mother-in-law", pattern: "mother[- ]?in[- ]?law"},
    %{label: "father-in-law", pattern: "father[- ]?in[- ]?law"}
  ]

  def list_for_user(user_id, opts \\ [])

  def list_for_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    people_limit =
      opts |> Keyword.get(:people_limit, @default_people_limit) |> clamp_limit(1, 100)

    observation_limit =
      opts |> Keyword.get(:observation_limit, @default_observation_limit) |> clamp_limit(1, 500)

    link_limit = opts |> Keyword.get(:link_limit, @default_link_limit) |> clamp_limit(1, 500)

    suggestion_limit =
      opts |> Keyword.get(:suggestion_limit, @default_suggestion_limit) |> clamp_limit(1, 100)

    people = Crm.list_people(user_id, limit: people_limit)
    person_ids = Enum.map(people, & &1.id)
    links = list_recent_links(user_id, person_ids, link_limit)
    observations = list_recent_observations(user_id, observation_limit)

    duplicate_suggestions =
      people
      |> duplicate_suggestions()
      |> Enum.take(suggestion_limit)

    relationship_suggestions =
      people
      |> relationship_suggestions(links, observations)
      |> Enum.take(suggestion_limit)

    %{
      duplicate_suggestions: duplicate_suggestions,
      relationship_suggestions: relationship_suggestions,
      total_count: length(duplicate_suggestions) + length(relationship_suggestions)
    }
  end

  def list_for_user(_user_id, _opts) do
    %{duplicate_suggestions: [], relationship_suggestions: [], total_count: 0}
  end

  defp list_recent_links(_user_id, [], _limit), do: []

  defp list_recent_links(user_id, person_ids, limit) do
    PersonLink
    |> where([link], link.user_id == ^user_id and link.person_id in ^person_ids)
    |> order_by([link], desc: link.updated_at, desc: link.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp list_recent_observations(user_id, limit) do
    Observation
    |> where([observation], observation.user_id == ^user_id)
    |> order_by([observation], desc: observation.occurred_at, desc: observation.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp duplicate_suggestions(people) do
    (duplicate_groups_by_name(people) ++ duplicate_groups_by_contact(people))
    |> merge_duplicate_groups()
    |> Enum.map(&build_duplicate_suggestion/1)
    |> Enum.sort_by(fn suggestion -> {-suggestion.confidence, suggestion.title} end)
  end

  defp duplicate_groups_by_name(people) do
    people
    |> Enum.group_by(&normalize_name(&1.display_name))
    |> Enum.reject(fn {name, group} -> blank?(name) or length(group) < 2 end)
    |> Enum.map(fn {_name, group} ->
      display_name = common_display_name(group)

      %{
        people: sort_people(group),
        confidence: 0.78,
        evidence: [
          evidence(
            "CRM",
            "Exact name match",
            "#{length(group)} active CRM people are named #{display_name}."
          )
        ]
      }
    end)
  end

  defp duplicate_groups_by_contact(people) do
    people
    |> Enum.flat_map(&contact_entries/1)
    |> Enum.group_by(fn entry -> {entry.kind, entry.normalized_value} end)
    |> Enum.reject(fn {_key, entries} ->
      entries
      |> Enum.map(& &1.person.id)
      |> Enum.uniq()
      |> length()
      |> Kernel.<(2)
    end)
    |> Enum.map(fn {{_kind, _normalized_value}, entries} ->
      people =
        entries
        |> Enum.map(& &1.person)
        |> Enum.uniq_by(& &1.id)
        |> sort_people()

      first_entry = List.first(entries)

      %{
        people: people,
        confidence: 0.9,
        evidence: [
          evidence(
            "CRM",
            "Shared #{first_entry.label}",
            "#{first_entry.value} appears on #{people_label(people)}."
          )
        ]
      }
    end)
  end

  defp merge_duplicate_groups(groups) do
    groups
    |> Enum.reduce(%{}, fn group, acc ->
      key = group.people |> Enum.map(& &1.id) |> Enum.sort()

      Map.update(acc, key, group, fn existing ->
        %{
          existing
          | confidence: max(existing.confidence, group.confidence),
            evidence: unique_evidence(existing.evidence ++ group.evidence)
        }
      end)
    end)
    |> Map.values()
  end

  defp build_duplicate_suggestion(group) do
    people = sort_people(group.people)
    search_query = common_display_name(people)

    %{
      id:
        stable_id(["duplicate", Enum.map(people, & &1.id), Enum.map(group.evidence, & &1.detail)]),
      type: :duplicate,
      title: "Possible duplicate: #{search_query}",
      summary:
        "Maraithon found #{length(people)} active CRM records that may represent the same person: #{people_label(people)}.",
      confidence: group.confidence,
      evidence: group.evidence,
      people: people,
      person_ids: Enum.map(people, & &1.id),
      action: %{label: "Review in People", path: people_search_path(search_query)}
    }
  end

  defp relationship_suggestions(people, links, observations) do
    links_by_person = Enum.group_by(links, & &1.person_id)
    observations_by_person = observations_by_person(observations)

    people
    |> Enum.reject(&present?(&1.relationship))
    |> Enum.flat_map(fn person ->
      sources =
        relationship_sources(
          person,
          Map.get(links_by_person, person.id, []),
          Map.get(observations_by_person, person.id, [])
        )

      build_relationship_suggestions(person, sources)
    end)
    |> Enum.sort_by(fn suggestion -> {-suggestion.confidence, suggestion.title} end)
  end

  defp observations_by_person(observations) do
    Enum.reduce(observations, %{}, fn observation, acc ->
      observation.resolved_person_ids
      |> List.wrap()
      |> Enum.reduce(acc, fn person_id, inner_acc ->
        Map.update(inner_acc, person_id, [observation], &[observation | &1])
      end)
    end)
  end

  defp relationship_sources(%Person{} = person, links, observations) do
    note_sources =
      if present?(person.notes) do
        [%{source: "Person notes", text: person.notes}]
      else
        []
      end

    note_sources ++ link_sources(links) ++ observation_sources(observations)
  end

  defp link_sources(links) do
    Enum.flat_map(links, fn link ->
      [
        {"Linked #{link.resource_type}", link.title},
        {"Linked #{link.resource_type}", link.summary},
        {"Linked #{link.resource_type}", link.relationship_note},
        {"Linked #{link.resource_type}", link.evidence_quote},
        {"Linked #{link.resource_type}", link.model_rationale}
      ]
      |> Enum.filter(fn {_source, text} -> present?(text) end)
      |> Enum.map(fn {source, text} -> %{source: source, text: text} end)
    end)
  end

  defp observation_sources(observations) do
    Enum.flat_map(observations, fn observation ->
      texts =
        [
          observation.subject,
          observation.excerpt
        ] ++ metadata_texts(observation.metadata)

      texts
      |> Enum.filter(&present?/1)
      |> Enum.map(fn text -> %{source: "CRM observation", text: text} end)
    end)
  end

  defp build_relationship_suggestions(%Person{} = person, sources) do
    sources
    |> Enum.flat_map(&relationship_matches(person, &1))
    |> Enum.group_by(& &1.relationship)
    |> Enum.map(fn {relationship, matches} ->
      matches = Enum.sort_by(matches, &(-&1.confidence))
      best = List.first(matches)
      evidence = matches |> Enum.map(& &1.evidence) |> unique_evidence() |> Enum.take(3)

      %{
        id: stable_id(["relationship", person.id, relationship, Enum.map(evidence, & &1.detail)]),
        type: :relationship,
        person: person,
        person_id: person.id,
        relationship: relationship,
        title: "I think #{person.display_name} is your #{relationship}",
        summary: "Maraithon found relationship language tied to #{person.display_name}.",
        confidence: best.confidence,
        evidence: evidence,
        action: %{label: "Apply relationship", person_id: person.id, relationship: relationship},
        review_path: person_review_path(person)
      }
    end)
  end

  defp relationship_matches(%Person{} = person, %{text: text, source: source})
       when is_binary(text) do
    normalized_text = normalize_phrase(text)
    names = name_variants(person)

    @relationship_labels
    |> Enum.flat_map(fn relationship ->
      Enum.flat_map(names, fn name ->
        if relationship_phrase?(normalized_text, name, relationship.pattern) do
          [
            %{
              relationship: relationship.label,
              confidence: relationship_confidence(person, name, normalized_text),
              evidence:
                evidence(
                  source,
                  relationship_evidence_label(relationship.label),
                  evidence_snippet(text)
                )
            }
          ]
        else
          []
        end
      end)
    end)
    |> Enum.uniq_by(fn match -> {match.relationship, match.evidence.detail} end)
  end

  defp relationship_matches(_person, _source), do: []

  defp relationship_phrase?(text, name, relationship_pattern) do
    name = Regex.escape(normalize_phrase(name))

    [
      ~r/\b#{name}\b.{0,80}\b(?:is|looks like|seems like|might be|may be)\s+(?:my|your)\s+#{relationship_pattern}\b/u,
      ~r/\b#{name}\b.{0,80}\b(?:my|your)\s+#{relationship_pattern}\b/u,
      ~r/\b(?:my|your)\s+#{relationship_pattern}\b.{0,80}\b#{name}\b/u,
      ~r/\b#{relationship_pattern}\b.{0,80}\b#{name}\b/u
    ]
    |> Enum.any?(&Regex.match?(&1, text))
  end

  defp relationship_confidence(%Person{} = person, name, text) do
    full_name = person.display_name |> normalize_phrase()

    cond do
      present?(full_name) and String.contains?(text, full_name) -> 0.9
      String.length(name) >= 4 -> 0.82
      true -> 0.72
    end
  end

  defp contact_entries(%Person{contact_details: contact_details} = person)
       when is_map(contact_details) do
    Enum.flat_map(@contact_kinds, fn {key, label} ->
      contact_details
      |> Map.get(key)
      |> List.wrap()
      |> Enum.filter(&present?/1)
      |> Enum.map(fn value ->
        %{
          person: person,
          kind: key,
          label: label,
          value: to_string(value),
          normalized_value: normalize_contact_value(key, value)
        }
      end)
      |> Enum.reject(&blank?(&1.normalized_value))
    end)
  end

  defp contact_entries(_person), do: []

  defp normalize_contact_value("phones", value) when is_binary(value) do
    value
    |> String.replace(~r/[^\d+]/, "")
    |> normalize_text()
  end

  defp normalize_contact_value(_kind, value) when is_binary(value) do
    value
    |> String.downcase()
    |> normalize_text()
  end

  defp normalize_contact_value(_kind, value),
    do: normalize_contact_value("text", to_string(value))

  defp name_variants(%Person{} = person) do
    [person.display_name, person.first_name]
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> normalize_text()
  end

  defp normalize_name(_value), do: nil

  defp normalize_phrase(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[_\n\r\t]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp normalize_phrase(_value), do: ""

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_value), do: nil

  defp metadata_texts(value),
    do: value |> do_metadata_texts([]) |> Enum.reverse() |> Enum.take(20)

  defp do_metadata_texts(value, acc) when is_binary(value), do: [value | acc]

  defp do_metadata_texts(value, acc) when is_list(value) do
    Enum.reduce(value, acc, &do_metadata_texts/2)
  end

  defp do_metadata_texts(value, acc) when is_map(value) do
    value
    |> Map.values()
    |> Enum.reduce(acc, &do_metadata_texts/2)
  end

  defp do_metadata_texts(_value, acc), do: acc

  defp evidence(source, label, detail) do
    %{source: source, label: label, detail: detail}
  end

  defp unique_evidence(evidence) do
    Enum.uniq_by(evidence, fn item -> {item.source, item.label, item.detail} end)
  end

  defp relationship_evidence_label(relationship) do
    "Relationship phrase: #{relationship}"
  end

  defp evidence_snippet(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
    |> truncate(220)
  end

  defp sort_people(people), do: Enum.sort_by(people, &String.downcase(&1.display_name || ""))

  defp people_label(people) do
    people
    |> Enum.map(& &1.display_name)
    |> Enum.reject(&blank?/1)
    |> Enum.join(", ")
  end

  defp common_display_name([%Person{} = person | _people]),
    do: person.display_name || "unknown person"

  defp common_display_name(_people), do: "unknown person"

  defp people_search_path(query) do
    "/operator/people?" <> URI.encode_query(%{"q" => query})
  end

  defp person_review_path(%Person{} = person) do
    "/operator/people?" <>
      URI.encode_query(%{"person_id" => person.id, "q" => person.display_name})
  end

  defp stable_id(parts) do
    payload =
      parts
      |> List.wrap()
      |> List.flatten()
      |> Enum.map_join(":", &to_string/1)

    hash =
      :crypto.hash(:sha256, payload)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "crm-#{hash}"
  end

  defp truncate(value, max_length) when is_binary(value) do
    if String.length(value) > max_length do
      value
      |> String.slice(0, max_length - 3)
      |> Kernel.<>("...")
    else
      value
    end
  end

  defp truncate(value, _max_length), do: value

  defp clamp_limit(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)
  defp clamp_limit(_value, min, _max), do: min

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp blank?(value), do: not present?(value)
end
