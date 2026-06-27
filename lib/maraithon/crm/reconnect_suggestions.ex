defmodule Maraithon.Crm.ReconnectSuggestions do
  @moduledoc """
  Turns the CRM from an A-Z address book into an intelligent "who should I
  reconnect with" surface.

  The mobile People tab's job-to-be-done is not "list every contact" — it is
  "show me the people I should reach out to right now, and why." This module
  ranks the user's people on three signals the rest of Maraithon already
  computes, and attaches a concrete reason to each:

    * **Open work** — the person is linked to open todos/commitments. This is
      the "based on your work" hook: someone is waiting on you, or you owe
      them a reply, and that thread is the reason to reconnect.
    * **Overdue cadence** — `communication_signals.overdue` (from
      `Maraithon.Crm.CommunicationScore`): you usually talk every N days and
      it has been well past that.
    * **Going quiet** — a strong relationship (by communication score /
      relationship strength) that has gone silent, even without a learned
      cadence yet.

  People with none of these reasons are dropped — this is a curated
  reconnect list, not a ranked dump of the whole address book.
  """

  import Ecto.Query

  alias Maraithon.Crm.Person
  alias Maraithon.Crm.PersonLink
  alias Maraithon.Goals.{Goal, GoalLink}
  alias Maraithon.Repo
  alias Maraithon.Todos

  @default_limit 12
  @candidate_pool 500
  @open_statuses ["open", "snoozed"]
  @going_quiet_strength 45
  @going_quiet_days 21

  @doc """
  Returns ranked reconnect suggestions for the user.

  Each entry is a map: `%{person: %Person{}, category:, reason:, headline:,
  suggested_action:, days_since_last:, cadence_days:, communication_score:,
  overdue:, open_work: [%{id:, title:}], priority:}`.

  Options: `:limit` (default #{@default_limit}, max 50), `:now` (for tests).
  """
  def suggestions(user_id, opts \\ [])

  def suggestions(user_id, opts) when is_binary(user_id) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, 50)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    goal_slots =
      opts
      |> Keyword.get(:goal_slots, default_goal_slots(limit))
      |> clamp(0, limit)

    user_id
    |> ranked_suggestions(now)
    |> take_balanced(limit, goal_slots)
  end

  def suggestions(_user_id, _opts), do: []

  @doc """
  Returns goal-discovered people as their own lane.

  Unlike `suggestions/2`, this always explains the goal connection even when
  the same person also has open work. That keeps the People surface from
  becoming just "who has the most current tasks."
  """
  def goal_opportunities(user_id, opts \\ [])

  def goal_opportunities(user_id, opts) when is_binary(user_id) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, 50)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    goal_links_by_person = active_goal_links_by_person(user_id)
    people = people_by_ids(user_id, Map.keys(goal_links_by_person))

    contexts =
      Maraithon.Crm.relationship_contexts(user_id, people, resource_type: "todo", link_limit: 5)

    context_by_person = Map.new(contexts, &{&1.person.id, &1})

    people
    |> Enum.map(fn person ->
      context = Map.get(context_by_person, person.id, %{todos: []})
      goal_links = Map.get(goal_links_by_person, person.id, [])
      build_goal_opportunity(person, context, goal_links, now)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.priority, :desc)
    |> Enum.uniq_by(&suggestion_identity/1)
    |> Enum.take(limit)
  end

  def goal_opportunities(_user_id, _opts), do: []

  defp ranked_suggestions(user_id, now) do
    goal_links_by_person = active_goal_links_by_person(user_id)
    people = candidate_people(user_id, Map.keys(goal_links_by_person))

    contexts =
      Maraithon.Crm.relationship_contexts(user_id, people, resource_type: "todo", link_limit: 5)

    context_by_person = Map.new(contexts, &{&1.person.id, &1})

    people
    |> Enum.map(fn person ->
      context = Map.get(context_by_person, person.id, %{todos: []})
      goal_links = Map.get(goal_links_by_person, person.id, [])
      build_suggestion(person, context, goal_links, now)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.priority, :desc)
    |> Enum.uniq_by(&suggestion_identity/1)
  end

  # Pull a bounded, already-meaningful pool: active people who have any real
  # communication signal or relationship strength, PLUS anyone linked to open
  # work (the "based on your work" hook — that thread is a reconnect reason
  # even for a contact with no learned cadence yet). The 0-everything noise
  # contacts (newsletters, one-off senders) never belong in a reconnect list.
  defp candidate_people(user_id, goal_person_ids) do
    work_person_ids = people_with_open_work(user_id)
    important_person_ids = Enum.uniq(work_person_ids ++ goal_person_ids)

    important_people = people_by_ids(user_id, important_person_ids)

    ranked_people =
      Person
      |> where([p], p.user_id == ^user_id and p.status == "active")
      |> where([p], p.communication_score > 0 or p.relationship_strength > 0)
      |> order_by([p],
        desc: p.communication_score,
        desc: p.relationship_strength,
        desc_nulls_last: p.last_interaction_at
      )
      |> limit(@candidate_pool)
      |> Repo.all()

    (important_people ++ ranked_people)
    |> Enum.uniq_by(& &1.id)
  end

  defp people_by_ids(_user_id, []), do: []

  defp people_by_ids(user_id, person_ids) do
    Person
    |> where([p], p.user_id == ^user_id and p.status == "active")
    |> where([p], p.id in ^person_ids)
    |> Repo.all()
  end

  defp active_goal_links_by_person(user_id) do
    GoalLink
    |> join(:inner, [link], goal in Goal,
      on: goal.id == link.goal_id and goal.user_id == ^user_id and goal.status == "active"
    )
    |> where(
      [link, _goal],
      link.user_id == ^user_id and link.resource_type == "person"
    )
    |> order_by([link, goal], desc: goal.priority, desc: link.confidence, desc: link.updated_at)
    |> select([link, goal], %{
      person_id: link.resource_id,
      goal_id: goal.id,
      goal_title: goal.title,
      relationship: link.relationship,
      confidence: link.confidence,
      priority: goal.priority
    })
    |> Repo.all()
    |> Enum.group_by(& &1.person_id)
  end

  # person_links store resource_id as text while todo ids are UUIDs, so we
  # resolve them through Todos (the same path the rest of Crm uses) rather
  # than a typed SQL join that would choke on any non-UUID resource_id.
  defp people_with_open_work(user_id) do
    todo_links =
      PersonLink
      |> where([link], link.user_id == ^user_id and link.resource_type == "todo")
      |> select([link], {link.person_id, link.resource_id})
      |> Repo.all()

    open_todo_ids =
      todo_links
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> then(&Todos.list_by_ids(user_id, &1))
      |> Enum.filter(&(&1.status in @open_statuses))
      |> MapSet.new(& &1.id)

    todo_links
    |> Enum.filter(fn {_person_id, resource_id} -> MapSet.member?(open_todo_ids, resource_id) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
  end

  defp build_suggestion(%Person{} = person, context, goal_links, now) do
    signals = communication_signals(person)
    open_work = open_work_items(context)
    days_since = days_since_last(person, signals, now)
    cadence = integer_or_nil(signals["cadence_days"])
    score = person.communication_score || 0
    overdue? = signals["overdue"] == true

    case classify(person, open_work, goal_links, overdue?, days_since, score) do
      nil ->
        nil

      category ->
        %{
          person: person,
          category: category,
          headline: headline(category),
          reason: reason(category, person, open_work, goal_links, days_since, cadence),
          suggested_action: suggested_action(category, person, open_work, goal_links),
          days_since_last: days_since,
          cadence_days: cadence,
          communication_score: score,
          overdue: overdue?,
          open_work: Enum.map(open_work, &%{id: &1.id, title: &1.title}),
          goals: Enum.map(goal_links, &%{id: &1.goal_id, title: &1.goal_title}),
          priority: priority(category, person, open_work, overdue?, days_since, cadence, score)
        }
    end
  end

  defp build_goal_opportunity(%Person{} = person, context, [_ | _] = goal_links, now) do
    signals = communication_signals(person)
    open_work = open_work_items(context)
    days_since = days_since_last(person, signals, now)
    cadence = integer_or_nil(signals["cadence_days"])
    score = person.communication_score || 0

    %{
      person: person,
      category: :goal_aligned,
      headline: headline(:goal_aligned),
      reason: reason(:goal_aligned, person, open_work, goal_links, days_since, cadence),
      suggested_action: suggested_action(:goal_aligned, person, open_work, goal_links),
      days_since_last: days_since,
      cadence_days: cadence,
      communication_score: score,
      overdue: signals["overdue"] == true,
      open_work: Enum.map(open_work, &%{id: &1.id, title: &1.title}),
      goals: Enum.map(goal_links, &%{id: &1.goal_id, title: &1.goal_title}),
      priority: goal_opportunity_priority(person, goal_links, open_work, days_since)
    }
  end

  defp build_goal_opportunity(_person, _context, _goal_links, _now), do: nil

  # Reason precedence: real open work is the strongest reconnect trigger, then
  # an overdue learned cadence, then a strong relationship gone quiet.
  defp classify(person, open_work, goal_links, overdue?, days_since, score) do
    strength = person.relationship_strength || 0

    cond do
      open_work != [] -> :open_work
      goal_links != [] -> :goal_aligned
      overdue? -> :overdue
      going_quiet?(strength, score, days_since) -> :going_quiet
      true -> nil
    end
  end

  defp going_quiet?(strength, score, days_since) do
    is_integer(days_since) and days_since >= @going_quiet_days and
      (strength >= @going_quiet_strength or score >= @going_quiet_strength)
  end

  defp headline(:open_work), do: "Open work"
  defp headline(:goal_aligned), do: "Goal aligned"
  defp headline(:overdue), do: "Overdue"
  defp headline(:going_quiet), do: "Going quiet"

  defp reason(:open_work, person, open_work, _goal_links, _days, _cadence) do
    name = first_name(person)
    count = length(open_work)

    lead =
      case count do
        1 -> "#{count} open item with #{name}"
        n -> "#{n} open items with #{name}"
      end

    case List.first(open_work) do
      %{title: title} when is_binary(title) and title != "" ->
        "#{lead}: #{title}."

      _ ->
        "#{lead} is waiting to move forward."
    end
  end

  defp reason(:goal_aligned, person, _open_work, goal_links, _days, _cadence) do
    name = first_name(person)

    case List.first(goal_links) do
      %{goal_title: title} when is_binary(title) and title != "" ->
        "#{name} is linked to your goal \"#{title}\"."

      _ ->
        "#{name} is linked to an active goal."
    end
  end

  defp reason(:overdue, person, _open_work, _goal_links, days_since, cadence) do
    name = first_name(person)

    cond do
      is_integer(days_since) and is_integer(cadence) ->
        "#{days_since} days since you spoke with #{name} — you usually connect every #{cadence_label(cadence)}."

      is_integer(days_since) ->
        "#{days_since} days since you last spoke with #{name}."

      true ->
        "It has been a while since you connected with #{name}."
    end
  end

  defp reason(:going_quiet, person, _open_work, _goal_links, days_since, _cadence) do
    name = first_name(person)

    case days_since do
      d when is_integer(d) ->
        "A strong relationship — #{d} days quiet with #{name}."

      _ ->
        "A strong relationship that has gone quiet with #{name}."
    end
  end

  defp suggested_action(:open_work, person, open_work, _goal_links) do
    case List.first(open_work) do
      %{title: title} when is_binary(title) and title != "" ->
        "Reach out to #{first_name(person)} to move \"#{title}\" forward."

      _ ->
        contact_action(person)
    end
  end

  defp suggested_action(:goal_aligned, person, _open_work, goal_links) do
    case List.first(goal_links) do
      %{goal_title: title} when is_binary(title) and title != "" ->
        "Review whether #{first_name(person)} can help move \"#{title}\" forward."

      _ ->
        contact_action(person)
    end
  end

  defp suggested_action(_category, person, _open_work, _goal_links), do: contact_action(person)

  defp contact_action(%Person{} = person) do
    name = first_name(person)

    case preferred_method(person) do
      nil -> "Send #{name} a quick note to reconnect."
      method -> "Reach out to #{name} over #{method}."
    end
  end

  # Priority blends the curated reasons with the underlying strength/score so
  # the most consequential reconnections rise first. Open work dominates;
  # overdue magnitude and relationship strength refine the order.
  defp priority(category, person, open_work, overdue?, days_since, cadence, score) do
    strength = person.relationship_strength || 0

    base = score * 0.3 + strength * 0.4

    category_weight =
      case category do
        :open_work -> 80 + min(length(open_work), 3) * 12
        :goal_aligned -> 72
        :overdue -> 35
        :going_quiet -> 20
      end

    overdue_magnitude =
      if overdue? and is_integer(days_since) and is_integer(cadence) and cadence > 0 do
        min((days_since - cadence) / cadence, 3.0) * 8
      else
        0
      end

    quiet_magnitude =
      if is_integer(days_since), do: min(days_since / 30, 3.0) * 3, else: 0

    base + category_weight + overdue_magnitude + quiet_magnitude
  end

  defp goal_opportunity_priority(person, goal_links, open_work, days_since) do
    strength = person.relationship_strength || 0
    score = person.communication_score || 0

    goal_score =
      goal_links
      |> Enum.map(fn link -> (link.priority || 0) + (link.confidence || 0.0) * 100 end)
      |> Enum.max(fn -> 0 end)

    quiet_bump = if is_integer(days_since), do: min(days_since / 30, 3.0) * 4, else: 0
    work_bump = if open_work == [], do: 0, else: 10

    goal_score + strength * 0.2 + score * 0.1 + quiet_bump + work_bump
  end

  defp take_balanced(suggestions, limit, 0), do: Enum.take(suggestions, limit)

  defp take_balanced(suggestions, limit, goal_slots) do
    goal_suggestions =
      suggestions
      |> Enum.filter(&(&1.category == :goal_aligned))
      |> Enum.take(goal_slots)

    if goal_suggestions == [] do
      Enum.take(suggestions, limit)
    else
      selected_goal_ids = MapSet.new(goal_suggestions, & &1.person.id)

      general_suggestions =
        suggestions
        |> Enum.reject(&MapSet.member?(selected_goal_ids, &1.person.id))
        |> Enum.take(limit - length(goal_suggestions))

      {lead, tail} = Enum.split(general_suggestions, min(3, length(general_suggestions)))

      (lead ++ goal_suggestions ++ tail)
      |> Enum.take(limit)
    end
  end

  defp suggestion_identity(%{person: %Person{id: id, display_name: display_name}}) do
    case normalized_identity_name(display_name) do
      nil -> {:id, id}
      name -> {:name, name}
    end
  end

  defp suggestion_identity(_suggestion), do: {:unknown, System.unique_integer([:positive])}

  defp normalized_identity_name(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp normalized_identity_name(_value), do: nil

  defp open_work_items(%{todos: todos}) when is_list(todos) do
    todos
    |> Enum.filter(&(&1.status in @open_statuses))
    |> Enum.map(fn todo ->
      %{id: todo.id, title: normalize_title(todo.title) || normalize_title(todo.summary)}
    end)
    |> Enum.reject(&is_nil(&1.title))
    |> Enum.uniq_by(&String.downcase(&1.title))
  end

  defp open_work_items(_context), do: []

  defp communication_signals(%Person{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "communication_signals") do
      %{} = signals -> signals
      _ -> %{}
    end
  end

  defp communication_signals(_person), do: %{}

  defp days_since_last(person, signals, now) do
    case integer_or_nil(signals["days_since_last"]) do
      value when is_integer(value) ->
        value

      nil ->
        case person.last_interaction_at do
          %DateTime{} = last -> max(DateTime.diff(now, last, :day), 0)
          _ -> nil
        end
    end
  end

  defp preferred_method(%Person{preferred_communication_method: method}) do
    case method do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp first_name(%Person{first_name: first}) when is_binary(first) do
    case String.trim(first) do
      "" -> "them"
      value -> value
    end
  end

  defp first_name(%Person{display_name: display}) when is_binary(display) do
    display
    |> String.trim()
    |> String.split(" ", trim: true)
    |> List.first()
    |> case do
      nil -> "them"
      value -> value
    end
  end

  defp first_name(_person), do: "them"

  defp cadence_label(days) when is_integer(days) and days <= 1, do: "day"
  defp cadence_label(days) when is_integer(days) and days <= 9, do: "#{days} days"
  defp cadence_label(days) when is_integer(days) and days <= 13, do: "week or two"
  defp cadence_label(days) when is_integer(days) and days <= 35, do: "month"
  defp cadence_label(_days), do: "few months"

  defp normalize_title(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_title(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp default_goal_slots(limit) when is_integer(limit) and limit <= 3, do: 1
  defp default_goal_slots(limit) when is_integer(limit), do: min(3, max(1, div(limit, 4)))
  defp default_goal_slots(_limit), do: 1

  defp clamp(value, min_value, max_value) when is_integer(value),
    do: value |> max(min_value) |> min(max_value)

  defp clamp(_value, min_value, _max_value), do: min_value
end
