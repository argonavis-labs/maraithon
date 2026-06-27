defmodule Maraithon.Crm.GoalPeopleDiscovery do
  @moduledoc """
  Broad, goal-aware People scan.

  This is the durable background counterpart to the People tab's reconnect
  surface: scan active contacts against active goals, then write goal links for
  people who plausibly help move a goal forward. The UI can then rank from
  source-backed goal links instead of "who Kent talks to most."
  """

  import Ecto.Query

  alias Maraithon.Crm.Person
  alias Maraithon.Goals
  alias Maraithon.Goals.Goal
  alias Maraithon.Repo

  @default_people_limit 500
  @default_goal_limit 20
  @default_links_per_goal 12
  @min_confidence 0.32
  @stopwords MapSet.new(~w(
    a about after all also am an and any are as at be by can close do for from get goal going
    has have how i if in into is it its me my of on or our out over own plan so that the this
    through to up us we what when with work you your
  ))

  @doc """
  Scan active people against active goals and persist high-confidence
  `goal_links` to person resources.
  """
  def run(user_id, opts \\ [])

  def run(user_id, opts) when is_binary(user_id) and is_list(opts) do
    people_limit = opts |> Keyword.get(:people_limit, @default_people_limit) |> clamp(1, 2_000)
    goal_limit = opts |> Keyword.get(:goal_limit, @default_goal_limit) |> clamp(1, 100)
    links_per_goal = opts |> Keyword.get(:links_per_goal, @default_links_per_goal) |> clamp(1, 50)

    goals = active_goals(user_id, goal_limit)
    people = active_people(user_id, people_limit)

    result =
      goals
      |> Enum.flat_map(&candidate_links(user_id, &1, people, links_per_goal))
      |> persist_links(user_id)

    {:ok,
     %{
       source: "goal_people_discovery",
       goals_checked: length(goals),
       people_scanned: length(people),
       links_created_or_updated: result.linked,
       skipped: result.skipped
     }}
  end

  def run(_user_id, _opts), do: {:error, :invalid_goal_people_discovery}

  defp active_goals(user_id, limit) do
    Goals.list_goals(user_id, status: "active", limit: limit)
  end

  defp active_people(user_id, limit) do
    Person
    |> where([person], person.user_id == ^user_id and person.status == "active")
    |> order_by([person], asc: fragment("lower(?)", person.display_name), asc: person.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp candidate_links(user_id, %Goal{} = goal, people, links_per_goal) do
    ambiguous_name_terms = ambiguous_name_terms(people)

    people
    |> Enum.map(&score_person(goal, &1, ambiguous_name_terms))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.confidence, :desc)
    |> Enum.take(links_per_goal)
    |> Enum.map(fn candidate ->
      %{
        "goal_id" => goal.id,
        "resource_type" => "person",
        "resource_id" => candidate.person.id,
        "relationship" => "supports",
        "source" => "agent",
        "confidence" => candidate.confidence,
        "metadata" => %{
          "source" => "goal_people_discovery",
          "reason" => candidate.reason,
          "matched_terms" => candidate.matched_terms,
          "goal_title" => goal.title,
          "person_name" => candidate.person.display_name,
          "user_id" => user_id
        }
      }
    end)
  end

  defp score_person(%Goal{} = goal, %Person{} = person, ambiguous_name_terms) do
    goal_text = goal_text(goal)
    goal_terms = text_terms(goal_text)
    person_terms = text_terms(person_text(person))
    overlap = MapSet.intersection(goal_terms, person_terms) |> MapSet.to_list() |> Enum.sort()
    direct_name? = direct_name_match?(goal_text, goal_terms, person, ambiguous_name_terms)
    domain_score = domain_score(goal, person)
    overlap_score = min(length(overlap) * 0.14, 0.56)
    name_score = if direct_name?, do: 0.5, else: 0.0
    strength_score = min((person.relationship_strength || 0) / 100, 1.0) * 0.08
    confidence = min(overlap_score + name_score + domain_score + strength_score, 0.96)

    if confidence >= @min_confidence do
      %{
        person: person,
        confidence: Float.round(confidence, 2),
        matched_terms: overlap,
        reason: reason(goal, person, overlap, direct_name?, domain_score)
      }
    end
  end

  defp goal_text(%Goal{} = goal) do
    [
      goal.category,
      goal.title,
      goal.desired_outcome,
      goal.why,
      goal.success_metric,
      inspect(goal.metadata || %{})
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp person_text(%Person{} = person) do
    [
      person.display_name,
      person.first_name,
      person.last_name,
      person.relationship,
      person.notes,
      inspect(person.metadata || %{}),
      inspect(person.contact_details || %{})
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp text_terms(value) when is_binary(value) do
    value
    |> normalized_text()
    |> String.split(" ", trim: true)
    |> Enum.reject(&(String.length(&1) < 3 or MapSet.member?(@stopwords, &1)))
    |> MapSet.new()
  end

  defp ambiguous_name_terms(people) do
    people
    |> Enum.flat_map(&person_name_terms/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_term, count} -> count > 1 end)
    |> Enum.map(fn {term, _count} -> term end)
    |> MapSet.new()
  end

  defp person_name_terms(%Person{} = person) do
    [person.first_name, person.last_name, person.display_name]
    |> Enum.flat_map(fn
      value when is_binary(value) -> MapSet.to_list(text_terms(value))
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp direct_name_match?(goal_text, goal_terms, %Person{} = person, ambiguous_name_terms) do
    direct_display_name_match?(goal_text, person.display_name) or
      person
      |> person_name_terms()
      |> Enum.reject(&MapSet.member?(ambiguous_name_terms, &1))
      |> Enum.any?(&MapSet.member?(goal_terms, &1))
  end

  defp direct_display_name_match?(goal_text, display_name) when is_binary(display_name) do
    display_name = normalized_text(display_name)

    if String.contains?(display_name, " ") do
      goal_text
      |> normalized_text()
      |> String.contains?(display_name)
    else
      false
    end
  end

  defp direct_display_name_match?(_goal_text, _display_name), do: false

  defp normalized_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  defp domain_score(%Goal{} = goal, %Person{} = person) do
    goal_text = goal_text(goal) |> String.downcase()
    person_text = person_text(person) |> String.downcase()

    cond do
      String.contains?(goal_text, ["fundraise", "seed", "investor", "capital"]) and
          String.contains?(person_text, ["investor", "vc", "venture", "angel"]) ->
        0.38

      String.contains?(goal_text, ["customer", "sales", "revenue", "contract", "renewal"]) and
          String.contains?(person_text, ["customer", "client", "buyer", "sponsor"]) ->
        0.34

      String.contains?(goal_text, ["hire", "recruit", "candidate", "team"]) and
          String.contains?(person_text, ["candidate", "recruiter", "talent", "teammate"]) ->
        0.3

      String.contains?(goal_text, ["family", "school", "camp", "child", "emma", "jack"]) and
          String.contains?(person_text, ["family", "school", "teacher", "coach", "child"]) ->
        0.34

      true ->
        0.0
    end
  end

  defp reason(%Goal{} = goal, %Person{} = person, overlap, direct_name?, domain_score) do
    cond do
      direct_name? ->
        "#{person.display_name} is named in or near the goal \"#{goal.title}\"."

      overlap != [] ->
        "#{person.display_name} shares goal-relevant terms: #{Enum.join(overlap, ", ")}."

      domain_score > 0 ->
        "#{person.display_name} has relationship context that matches the goal domain."

      true ->
        "#{person.display_name} may be relevant to \"#{goal.title}\"."
    end
  end

  defp persist_links(candidates, user_id) do
    Enum.reduce(candidates, %{linked: 0, skipped: 0}, fn attrs, acc ->
      case Goals.link_resource(user_id, attrs["goal_id"], attrs, source: "agent") do
        {:ok, _link} -> %{acc | linked: acc.linked + 1}
        {:error, _reason} -> %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  defp clamp(value, min_value, max_value) when is_integer(value) do
    value |> max(min_value) |> min(max_value)
  end

  defp clamp(_value, min_value, _max_value), do: min_value
end
