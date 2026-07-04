defmodule Maraithon.Todos.CounterpartyBackfill do
  @moduledoc """
  SPEC 04 R6/R6a: rerunnable, idempotent backfill for label-only owed todos
  (`counterparty_label` present, `counterparty_person_id` nil).

  Two passes, in order, every run:

  1. **Deterministic** — `Maraithon.Todos.CounterpartyResolver.resolve_person/3`
     runs unconditionally on every candidate row, including rows a previous
     run already marked `ambiguous_unresolved`/`not_found`. This is a single
     cheap CRM read per row (no model call), and it alone flips a row to
     resolved whenever a merge collapsed a duplicate out of the candidate
     set or a new sole-compatible person appeared.
  2. **Model-gated** — only the deterministically-`:ambiguous` remainder, and
     for previously-marked rows only when the candidate set concretely
     changed since the row's `attempted_at` (an active `Crm.Person` inserted
     or updated after that timestamp whose name is compatible with the
     label). One model call per batch, never one per row; the model must
     pick exactly one candidate id or say none — the FK is stamped only on
     a single confident pick.

  Every touched row (resolved or not) gets a
  `metadata["counterparty_resolution"]` marker
  (`%{"attempted_at" => iso8601, "result" => "resolved" | "ambiguous_unresolved" | "not_found"}`)
  so reruns never re-burn model calls on a permanently-ambiguous label.
  """

  import Ecto.Query

  alias Maraithon.Crm.Person
  alias Maraithon.LLM
  alias Maraithon.Repo
  alias Maraithon.Todos.CounterpartyResolver
  alias Maraithon.Todos.Todo

  require Logger

  @default_limit 500
  @model_batch_size 10
  @model_confidence_floor 0.7
  @default_max_tokens 2_000

  def run(user_id, opts \\ [])

  def run(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    model_pass? = Keyword.get(opts, :model_pass?, true)

    todos = candidate_todos(user_id, limit)

    grouped =
      Enum.reduce(todos, %{resolved: [], ambiguous: [], not_found: [], unchanged: []}, fn todo,
                                                                                          acc ->
        case CounterpartyResolver.resolve_person(user_id, todo.counterparty_label) do
          {:ok, %Person{} = person} ->
            %{acc | resolved: [{todo, person} | acc.resolved]}

          :ambiguous ->
            if escalate_to_model?(user_id, todo) do
              %{acc | ambiguous: [todo | acc.ambiguous]}
            else
              %{acc | unchanged: [todo | acc.unchanged]}
            end

          :not_found ->
            %{acc | not_found: [todo | acc.not_found]}
        end
      end)

    resolved_count =
      grouped.resolved
      |> Enum.reverse()
      |> Enum.map(fn {todo, person} -> stamp_resolved(todo, person, "deterministic", now) end)
      |> Enum.count(&match?({:ok, _todo}, &1))

    not_found_count =
      grouped.not_found
      |> Enum.reverse()
      |> Enum.map(&mark_unresolved(&1, "not_found", now))
      |> Enum.count(&match?({:ok, _todo}, &1))

    {model_resolved_count, model_unresolved_count} =
      if model_pass? do
        resolve_ambiguous_with_model(user_id, Enum.reverse(grouped.ambiguous), now, opts)
      else
        {0, mark_all_unresolved(Enum.reverse(grouped.ambiguous), now)}
      end

    {:ok,
     %{
       source: "counterparty_backfill",
       scanned: length(todos),
       resolved_deterministic: resolved_count,
       resolved_model: model_resolved_count,
       ambiguous_unresolved: model_unresolved_count,
       not_found: not_found_count,
       skipped_unchanged_ambiguous: length(grouped.unchanged)
     }}
  end

  def run(_user_id, _opts), do: {:error, :invalid_counterparty_backfill}

  defp candidate_todos(user_id, limit) do
    Todo
    |> where(
      [todo],
      todo.user_id == ^user_id and is_nil(todo.counterparty_person_id) and
        not is_nil(todo.counterparty_label) and todo.counterparty_label != ""
    )
    |> order_by([todo], asc: todo.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # R6a tier 2: escalate a still-ambiguous row to the model pass only when it
  # was never attempted before, or when the active candidate set for its
  # label concretely changed since `attempted_at` — an active person inserted
  # or updated after that timestamp whose name is compatible with the label.
  # A merge repoint (R7) bumps the survivor's updated_at, which is exactly
  # the signal this query looks for.
  defp escalate_to_model?(user_id, %Todo{} = todo) do
    case resolution_marker(todo) do
      %{"attempted_at" => attempted_at} when is_binary(attempted_at) ->
        case DateTime.from_iso8601(attempted_at) do
          {:ok, since, _offset} ->
            candidate_set_changed?(user_id, todo.counterparty_label, since)

          _invalid ->
            true
        end

      _never_attempted ->
        true
    end
  end

  defp candidate_set_changed?(user_id, label, %DateTime{} = since) do
    Person
    |> where([person], person.user_id == ^user_id and person.status == "active")
    |> where([person], person.inserted_at > ^since or person.updated_at > ^since)
    |> limit(200)
    |> Repo.all()
    |> Enum.any?(&CounterpartyResolver.label_compatible?(label, &1))
  end

  defp resolution_marker(%Todo{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "counterparty_resolution") do
      %{} = marker -> marker
      _other -> nil
    end
  end

  defp resolution_marker(_todo), do: nil

  # ---------------------------------------------------------------------------
  # Model-gated second pass
  # ---------------------------------------------------------------------------

  defp resolve_ambiguous_with_model(_user_id, [], _now, _opts), do: {0, 0}

  defp resolve_ambiguous_with_model(user_id, ambiguous_todos, now, opts) do
    ambiguous_todos
    |> Enum.map(fn todo ->
      {todo, CounterpartyResolver.candidates(user_id, todo.counterparty_label)}
    end)
    |> Enum.chunk_every(@model_batch_size)
    |> Enum.reduce({0, 0}, fn batch, {resolved, unresolved} ->
      {batch_resolved, batch_unresolved} = resolve_batch_with_model(batch, now, opts)
      {resolved + batch_resolved, unresolved + batch_unresolved}
    end)
  end

  defp resolve_batch_with_model(batch, now, opts) do
    picks =
      case model_picks(batch, opts) do
        {:ok, picks} -> picks
        {:error, _reason} -> %{}
      end

    Enum.reduce(batch, {0, 0}, fn {todo, candidates}, {resolved, unresolved} ->
      candidate_ids = MapSet.new(candidates, & &1.id)

      case Map.get(picks, todo.id) do
        %{person_id: person_id, confidence: confidence}
        when is_binary(person_id) and confidence >= @model_confidence_floor ->
          if MapSet.member?(candidate_ids, person_id) do
            person = Enum.find(candidates, &(&1.id == person_id))
            _ = stamp_resolved(todo, person, "model", now)
            {resolved + 1, unresolved}
          else
            _ = mark_unresolved(todo, "ambiguous_unresolved", now)
            {resolved, unresolved + 1}
          end

        _none_or_unsure ->
          _ = mark_unresolved(todo, "ambiguous_unresolved", now)
          {resolved, unresolved + 1}
      end
    end)
  end

  defp model_picks(batch, opts) do
    params = %{
      "messages" => [%{"role" => "user", "content" => build_prompt(batch)}],
      "max_tokens" => Keyword.get(opts, :max_tokens, @default_max_tokens),
      "temperature" => 0.0,
      "reasoning_effort" => "none"
    }

    with {:ok, response} <- complete(params, opts),
         {:ok, content} <- response_content(response),
         {:ok, decoded} <- decode_response(content) do
      picks =
        decoded
        |> Map.get("resolutions", [])
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.reduce(%{}, fn resolution, acc ->
          todo_id = read_string(resolution, "todo_id")
          person_id = read_string(resolution, "person_id")
          confidence = read_float(resolution, "confidence")

          if is_binary(todo_id) do
            Map.put(acc, todo_id, %{person_id: person_id, confidence: confidence})
          else
            acc
          end
        end)

      {:ok, picks}
    else
      {:error, reason} ->
        Logger.warning("counterparty_backfill model pass failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_prompt(batch) do
    items =
      Enum.map(batch, fn {todo, candidates} ->
        %{
          "todo_id" => todo.id,
          "counterparty_label" => todo.counterparty_label,
          "todo_title" => todo.title,
          "todo_summary" => todo.summary,
          "direction" => todo.direction,
          "candidates" => Enum.map(candidates, &serialize_candidate/1)
        }
      end)

    """
    COUNTERPARTY_RESOLUTION_JSON_V1

    You resolve which CRM person a todo's free-text counterparty label refers
    to. For each item below, either pick exactly ONE candidate person id you
    are confident the label refers to, or return null when unsure.

    Rules:
    - Two distinct real people with similar names (same team, same family)
      are common. Only pick a candidate when the todo context and the
      candidate's relationship/contact details clearly identify one person.
    - Never guess. A wrong person id is worse than none — return null with
      low confidence when the evidence is thin.
    - person_id must be copied exactly from the candidate list, or null.

    Return ONLY valid JSON shaped like:
    {"resolutions": [{"todo_id": "...", "person_id": "..." , "confidence": 0.0}]}
    (person_id may be null; confidence is 0.0-1.0.)

    ITEMS_JSON:
    #{Jason.encode!(items)}
    """
  end

  defp serialize_candidate(%Person{} = person) do
    %{
      "person_id" => person.id,
      "display_name" => person.display_name,
      "relationship" => person.relationship,
      "notes" => person.notes,
      "contact_details" =>
        (person.contact_details || %{})
        |> Map.take(~w(emails phones slack_ids telegram_ids))
    }
  end

  defp complete(params, opts) do
    cond do
      is_function(Keyword.get(opts, :llm_complete), 1) ->
        Keyword.fetch!(opts, :llm_complete).(params)

      is_function(configured_llm_complete(), 1) ->
        configured_llm_complete().(params)

      true ->
        LLM.complete(params)
    end
  end

  defp configured_llm_complete do
    :maraithon
    |> Application.get_env(:counterparty_backfill, [])
    |> Keyword.get(:llm_complete)
  end

  defp response_content(%{content: content}) when is_binary(content), do: {:ok, content}
  defp response_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp response_content(content) when is_binary(content), do: {:ok, content}
  defp response_content(_response), do: {:error, :counterparty_backfill_missing_content}

  defp decode_response(content) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> {:error, :counterparty_backfill_invalid_json}
    end
  end

  # ---------------------------------------------------------------------------
  # Row stamping
  # ---------------------------------------------------------------------------

  defp stamp_resolved(%Todo{} = todo, %Person{} = person, resolved_by, now) do
    todo
    |> Ecto.Changeset.change(%{
      counterparty_person_id: person.id,
      metadata: put_marker(todo.metadata, "resolved", resolved_by, now)
    })
    |> Repo.update()
  end

  defp mark_all_unresolved(todos, now) do
    todos
    |> Enum.map(&mark_unresolved(&1, "ambiguous_unresolved", now))
    |> Enum.count(&match?({:ok, _todo}, &1))
  end

  defp mark_unresolved(%Todo{} = todo, result, now) do
    todo
    |> Ecto.Changeset.change(%{metadata: put_marker(todo.metadata, result, nil, now)})
    |> Repo.update()
  end

  defp put_marker(metadata, result, resolved_by, now) do
    marker =
      %{
        "attempted_at" => DateTime.to_iso8601(now),
        "result" => result
      }
      |> maybe_put("resolved_by", resolved_by)

    Map.put(metadata || %{}, "counterparty_resolution", marker)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp read_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp read_float(map, key) do
    case Map.get(map, key) do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      _other -> 0.0
    end
  end
end
