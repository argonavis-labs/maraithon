defmodule Maraithon.Crm.PersonDeduper do
  @moduledoc """
  Deterministic, high-confidence CRM person dedupe.

  This intentionally only auto-merges records connected by durable identifiers
  or exact full-name person duplicates. Single-token name collisions and
  organization-looking labels stay out of the automatic path.
  """

  import Ecto.Query

  alias Maraithon.Crm
  alias Maraithon.Crm.Person
  alias Maraithon.Repo

  @default_people_limit 5_000
  @default_group_limit 100
  @default_max_merges 50
  @identifier_kinds ~w(apple_contact_ids emails phones slack_ids telegram_ids)
  @organization_name_tokens ~w(
    bank canada capital co coinbase company corp corporation foundation group holdings inc
    labs limited linkedin llc ltd realty school university
  )

  def run(user_id, opts \\ [])

  def run(user_id, opts) when is_binary(user_id) and is_list(opts) do
    people_limit = opts |> Keyword.get(:people_limit, @default_people_limit) |> clamp(1, 10_000)
    group_limit = opts |> Keyword.get(:group_limit, @default_group_limit) |> clamp(1, 500)
    max_merges = opts |> Keyword.get(:max_merges, @default_max_merges) |> clamp(0, 500)
    dry_run? = Keyword.get(opts, :dry_run, false)

    people = active_people(user_id, people_limit)
    groups = people |> duplicate_groups() |> Enum.take(group_limit)

    if dry_run? do
      {:ok,
       %{
         source: "person_deduper",
         mode: "dry_run",
         people_scanned: length(people),
         groups_found: length(groups),
         groups: Enum.map(groups, &summarize_group/1)
       }}
    else
      result = merge_groups(user_id, groups, max_merges)

      {:ok,
       %{
         source: "person_deduper",
         people_scanned: length(people),
         groups_found: length(groups),
         groups_checked: result.groups_checked,
         merged: result.merged,
         failed: result.failed,
         skipped: result.skipped,
         failures: result.failures
       }}
    end
  end

  def run(_user_id, _opts), do: {:error, :invalid_person_dedupe}

  defp active_people(user_id, limit) do
    Person
    |> where([person], person.user_id == ^user_id and person.status == "active")
    |> order_by([person],
      desc: person.relationship_strength,
      desc: person.communication_score,
      desc: person.interaction_count,
      desc: person.updated_at
    )
    |> limit(^limit)
    |> Repo.all()
  end

  defp duplicate_groups(people) do
    identifier_groups = identifier_groups(people) ++ exact_name_groups(people)
    people_by_id = Map.new(people, &{&1.id, &1})

    identifier_groups
    |> Enum.map(&MapSet.new(Enum.map(&1.people, fn person -> person.id end)))
    |> merge_components()
    |> Enum.map(fn component ->
      component_people =
        component
        |> MapSet.to_list()
        |> Enum.map(&Map.fetch!(people_by_id, &1))

      evidence =
        identifier_groups
        |> Enum.filter(fn group ->
          group_ids = MapSet.new(group.people, & &1.id)
          group_ids |> MapSet.intersection(component) |> MapSet.size() >= 2
        end)
        |> Enum.map(& &1.evidence)
        |> Enum.uniq()
        |> Enum.sort()

      %{people: sort_people(component_people), evidence: evidence}
    end)
    |> Enum.reject(&(length(&1.people) < 2))
    |> Enum.filter(&safe_name_component?(&1.people))
    |> Enum.sort_by(fn group ->
      survivor = List.first(group.people)
      {-length(group.people), survivor.display_name || ""}
    end)
  end

  defp identifier_groups(people) do
    people
    |> Enum.flat_map(&identifier_entries/1)
    |> Enum.group_by(fn entry -> {entry.kind, entry.key} end)
    |> Enum.flat_map(fn {{kind, _key}, entries} ->
      people = entries |> Enum.map(& &1.person) |> Enum.uniq_by(& &1.id)

      kind
      |> safe_identifier_people_groups(people)
      |> Enum.map(fn grouped_people ->
        %{people: grouped_people, evidence: identifier_evidence(kind, List.first(entries))}
      end)
    end)
  end

  defp identifier_entries(%Person{} = person) do
    contact_details = person.contact_details || %{}

    Enum.flat_map(@identifier_kinds, fn kind ->
      contact_details
      |> Map.get(kind)
      |> List.wrap()
      |> Enum.flat_map(&identifier_entry(person, kind, &1))
    end)
  end

  defp identifier_entry(person, "emails" = kind, value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    if valid_email?(value) do
      [%{person: person, kind: kind, key: value, value: value}]
    else
      []
    end
  end

  defp identifier_entry(person, "phones" = kind, value) when is_binary(value) do
    value = String.trim(value)
    digits = String.replace(value, ~r/\D+/, "")
    name_key = normalize_name(person.display_name)

    if byte_size(digits) >= 10 and name_key != "" do
      [
        %{
          person: person,
          kind: kind,
          key: "last10:#{String.slice(digits, -10, 10)}:name:#{name_key}",
          value: value
        }
      ]
    else
      []
    end
  end

  defp identifier_entry(person, kind, value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      []
    else
      [%{person: person, kind: kind, key: String.downcase(value), value: value}]
    end
  end

  defp identifier_entry(_person, _kind, _value), do: []

  defp safe_identifier_people_groups(_kind, people) when length(people) < 2, do: []

  defp safe_identifier_people_groups(_kind, people) do
    people
    |> compatible_name_components()
    |> Enum.filter(&(length(&1) >= 2 and safe_name_component?(&1)))
  end

  defp identifier_evidence("apple_contact_ids", entry),
    do: "Shared Apple contact id #{entry.value}"

  defp identifier_evidence("emails", entry), do: "Shared email #{entry.value}"

  defp identifier_evidence("phones", entry) do
    digits = String.replace(entry.value, ~r/\D+/, "")
    "Shared phone ending #{String.slice(digits, -4, 4)}"
  end

  defp identifier_evidence("slack_ids", entry), do: "Shared Slack id #{entry.value}"
  defp identifier_evidence("telegram_ids", entry), do: "Shared Telegram id #{entry.value}"

  defp identifier_evidence(kind, entry), do: "Shared #{kind} #{entry.value}"

  defp exact_name_groups(people) do
    people
    |> Enum.group_by(&normalize_name(&1.display_name))
    |> Enum.filter(fn {key, people} -> key != "" and length(people) >= 2 end)
    |> Enum.filter(fn {key, _people} -> specific_person_name_key?(key) end)
    |> Enum.reject(fn {key, _people} -> organization_name_key?(key) end)
    |> Enum.reject(fn {_key, people} ->
      Enum.any?(people, fn person ->
        person.display_name
        |> to_string()
        |> String.contains?("@")
      end)
    end)
    |> Enum.map(fn {key, people} ->
      %{
        people: sort_people(people),
        evidence: "Exact display name #{display_name_for_key(key, people)}"
      }
    end)
  end

  defp display_name_for_key(_key, [%Person{display_name: display_name} | _people])
       when is_binary(display_name),
       do: display_name

  defp display_name_for_key(key, _people), do: key

  defp merge_components(groups) do
    Enum.reduce(groups, [], fn group, components ->
      {overlapping, rest} = Enum.split_with(components, &overlapping?(&1, group))
      merged = Enum.reduce(overlapping, group, &MapSet.union/2)
      [merged | rest]
    end)
  end

  defp overlapping?(left, right) do
    left
    |> MapSet.intersection(right)
    |> MapSet.size()
    |> Kernel.>(0)
  end

  defp compatible_name_components(people) do
    people_by_id = Map.new(people, &{&1.id, &1})

    people
    |> compatible_name_edges()
    |> merge_components()
    |> Enum.map(fn component ->
      component
      |> MapSet.to_list()
      |> Enum.map(&Map.fetch!(people_by_id, &1))
    end)
  end

  defp compatible_name_edges(people) do
    people
    |> Enum.with_index()
    |> Enum.flat_map(fn {left, index} ->
      people
      |> Enum.drop(index + 1)
      |> Enum.flat_map(fn right ->
        if name_compatible?(left, right) do
          [MapSet.new([left.id, right.id])]
        else
          []
        end
      end)
    end)
  end

  defp safe_name_component?(people) do
    people
    |> Enum.with_index()
    |> Enum.all?(fn {left, index} ->
      people
      |> Enum.drop(index + 1)
      |> Enum.all?(&name_compatible?(left, &1))
    end)
  end

  defp name_compatible?(%Person{} = left, %Person{} = right) do
    left_name = normalize_name(left.display_name)
    right_name = normalize_name(right.display_name)

    name_compatible?(left_name, right_name)
  end

  defp name_compatible?(left_name, right_name)
       when is_binary(left_name) and is_binary(right_name) do
    left_tokens = String.split(left_name, " ", trim: true)
    right_tokens = String.split(right_name, " ", trim: true)

    cond do
      left_tokens == [] or right_tokens == [] ->
        false

      left_name == right_name ->
        true

      single_token?(left_tokens) and multi_token?(right_tokens) ->
        List.first(left_tokens) == List.first(right_tokens)

      multi_token?(left_tokens) and single_token?(right_tokens) ->
        List.first(left_tokens) == List.first(right_tokens)

      multi_token?(left_tokens) and multi_token?(right_tokens) ->
        compatible_full_names?(left_tokens, right_tokens)

      true ->
        false
    end
  end

  defp name_compatible?(_left_name, _right_name), do: false

  defp compatible_full_names?(left_tokens, right_tokens) do
    List.last(left_tokens) == List.last(right_tokens) and
      compatible_first_tokens?(List.first(left_tokens), List.first(right_tokens))
  end

  defp compatible_first_tokens?(left, right) when is_binary(left) and is_binary(right) do
    left == right or common_prefix_length(left, right) >= 4
  end

  defp compatible_first_tokens?(_left, _right), do: false

  defp common_prefix_length(left, right) do
    left
    |> String.graphemes()
    |> Enum.zip(String.graphemes(right))
    |> Enum.take_while(fn {left_char, right_char} -> left_char == right_char end)
    |> length()
  end

  defp single_token?([_token]), do: true
  defp single_token?(_tokens), do: false

  defp multi_token?(tokens), do: length(tokens) >= 2

  defp specific_person_name_key?(key) when is_binary(key) do
    key
    |> String.split(" ", trim: true)
    |> multi_token?()
  end

  defp specific_person_name_key?(_key), do: false

  defp organization_name_key?(key) when is_binary(key) do
    key
    |> String.split(" ", trim: true)
    |> Enum.any?(&(&1 in @organization_name_tokens))
  end

  defp organization_name_key?(_key), do: false

  defp merge_groups(user_id, groups, max_merges) do
    initial = %{groups_checked: 0, merged: 0, failed: 0, skipped: 0, failures: []}

    Enum.reduce_while(groups, initial, fn group, acc ->
      remaining = max_merges - acc.merged

      cond do
        remaining <= 0 ->
          {:halt, %{acc | skipped: acc.skipped + mergeable_count(group)}}

        true ->
          {merged, failed, failures} = merge_group(user_id, group, remaining)

          {:cont,
           %{
             acc
             | groups_checked: acc.groups_checked + 1,
               merged: acc.merged + merged,
               failed: acc.failed + failed,
               failures: acc.failures ++ failures
           }}
      end
    end)
  end

  defp mergeable_count(group), do: max(length(group.people) - 1, 0)

  defp merge_group(user_id, group, remaining) do
    [survivor | duplicates] = sort_people(group.people)

    duplicates
    |> Enum.take(remaining)
    |> Enum.reduce({0, 0, []}, fn duplicate, {merged, failed, failures} ->
      attrs = %{
        "evidence" => Enum.join(group.evidence, "; "),
        "model_rationale" =>
          "Automatic high-confidence People dedupe from shared durable contact identifiers or exact full-name matches.",
        "performed_by" => "person_deduper"
      }

      case Crm.merge_people(user_id, survivor.id, duplicate.id, attrs) do
        {:ok, _result} ->
          {merged + 1, failed, failures}

        {:error, reason} ->
          failure = %{
            survivor_id: survivor.id,
            merged_id: duplicate.id,
            reason: inspect(reason)
          }

          {merged, failed + 1, [failure | failures]}
      end
    end)
  end

  defp sort_people(people) do
    Enum.sort_by(people, &survivor_score/1, :desc)
  end

  defp survivor_score(%Person{} = person) do
    [
      person.relationship_strength || 0,
      person.communication_score || 0,
      person.interaction_count || 0,
      contact_value_count(person.contact_details || %{}),
      datetime_score(person.updated_at),
      person.display_name || ""
    ]
  end

  defp contact_value_count(contact_details) do
    contact_details
    |> Map.take(@identifier_kinds)
    |> Map.values()
    |> List.flatten()
    |> Enum.count(&is_binary/1)
  end

  defp datetime_score(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_score(_datetime), do: 0

  defp summarize_group(group) do
    [survivor | duplicates] = sort_people(group.people)

    %{
      survivor: summarize_person(survivor),
      duplicates: Enum.map(duplicates, &summarize_person/1),
      evidence: group.evidence
    }
  end

  defp summarize_person(%Person{} = person) do
    %{
      id: person.id,
      display_name: person.display_name,
      relationship: person.relationship,
      communication_score: person.communication_score,
      relationship_strength: person.relationship_strength
    }
  end

  defp valid_email?(value) when is_binary(value) do
    String.contains?(value, "@") and not String.contains?(value, " ")
  end

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  defp normalize_name(_value), do: ""

  defp clamp(value, min_value, max_value) when is_integer(value) do
    value |> max(min_value) |> min(max_value)
  end

  defp clamp(_value, min_value, _max_value), do: min_value
end
