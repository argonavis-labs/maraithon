defmodule Maraithon.Delegations.EvaluationCanary do
  @moduledoc "A real quiet interval and later fact recall in the controlled Gmail eval."
  import Ecto.Query
  alias Maraithon.{Delegations, Repo}
  alias Maraithon.Delegations.{Evaluation, Ledger, Policy, Preferences, Scope, Turn}
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.Todos.{Todo, Workflow}

  @quiet_seconds 6 * 60 * 60
  @stable ~w(grant_id scope_hash owner_hash ledger_hash source_revision model_calls reserved_micro_usd cost_micro_usd agent_messages)

  def scenario?(job), do: get_in(job.payload, ["scenario", "id"]) == "durable_memory"

  def before_reply(job, state, d, index) do
    if scenario?(job) and index == 3,
      do: wait_for_release(state, d),
      else: {:ready, state}
  end

  defp wait_for_release(%{"canary_wait" => %{"after" => after_wait}} = state, _d)
       when is_map(after_wait),
       do: {:ready, state}

  defp wait_for_release(%{"canary_wait" => wait} = state, d) do
    now = DateTime.utc_now()
    {:ok, due, _} = DateTime.from_iso8601(wait["reply_not_before"])

    if DateTime.compare(now, due) == :lt do
      {:wait_until, state, due}
    else
      current = snapshot(d)

      cond do
        Map.take(wait["before"], @stable) != Map.take(current, @stable) ->
          {:error, :canary_quiet_state_changed}

        not is_binary(current["runtime_revision"]) or
            current["runtime_revision"] == wait["before"]["runtime_revision"] ->
          {:wait_until, state, DateTime.add(now, 30, :minute)}

        true ->
          # Commit the observed quiet interval before the fixture can send its
          # final reply. A worker loss cannot erase the proof or resend a reply.
          {:wait, put_in(state, ["canary_wait", "after"], current)}
      end
    end
  end

  defp wait_for_release(state, d) do
    before = snapshot(d)

    due =
      DateTime.utc_now()
      |> DateTime.add(@quiet_seconds, :second)
      |> Preferences.next_work_time(Preferences.get(d.user_id))

    next =
      state
      |> Map.put("phase", "waiting_across_releases")
      |> Map.put("canary_wait", %{
        "before" => before,
        "reply_not_before" => DateTime.to_iso8601(due)
      })

    {:wait_until, next, due}
  end

  def observation(job) do
    if scenario?(job) and is_binary((job.result || %{})["delegation_id"]) do
      if d = Delegations.get(job.user_id, job.result["delegation_id"]), do: snapshot(d)
    end
  end

  defp snapshot(d) do
    grant = Delegations.current_grant(d)
    todo = Repo.get_by!(Todo, id: d.todo_id, user_id: d.user_id)

    counts =
      Repo.one(
        from t in Turn,
          where: t.delegation_id == ^d.id and t.user_id == ^d.user_id,
          select: %{
            "model_calls" => type(coalesce(sum(t.model_calls), 0), :integer),
            "reserved_micro_usd" => type(coalesce(sum(t.reserved_micro_usd), 0), :integer)
          }
      )

    now = DateTime.utc_now()

    %{
      "observed_at" => DateTime.to_iso8601(now),
      "elapsed_seconds" => max(DateTime.diff(now, d.inserted_at), 0),
      "runtime_revision" => System.get_env("K_REVISION"),
      "state" => d.state,
      "grant_id" => grant.id,
      "scope_hash" => grant.data["scope_hash"],
      "owner_hash" => Scope.hash(Workflow.current(todo)["owner"]),
      "ledger_hash" => Scope.hash(d.data["ledger"] || %{}),
      "source_revision" => d.source_revision,
      "cost_micro_usd" => d.lifetime_micro_usd,
      "agent_messages" => d.lifetime_sends
    }
    |> Map.merge(counts)
  end

  def verify(job, state, d, todo, turns) do
    turns = Enum.map(turns, &Turn.hydrate/1)
    turn = Enum.max_by(turns, & &1.seq)
    run = Repo.get_by!(Run, id: turn.run_id, user_id: d.user_id) |> Run.hydrate_payloads()
    facts = get_in(d.data, ["ledger", "facts"]) || %{}
    expected = job.payload["scenario"]["expect"]["answers"]
    colour_id = state["reply_message_ids"]["0"]
    recent = Enum.take(run.prompt_snapshot["sources"]["messages"], -6)
    recalled = run.prompt_snapshot["recalled_sources"] || []
    wait = state["canary_wait"] || %{}
    before = wait["before"] || %{}
    after_wait = wait["after"] || %{}
    model = Evaluation.scenarios()["model"]
    outcome = String.downcase(get_in(d.data, ["ledger", "latest_outcome"]) || "")

    checks = %{
      "done_with_all_answers" =>
        todo.status == "done" and state["completion_cites_reply"] and
          Enum.all?(Enum.with_index(expected), fn {answer, index} ->
            id = state["reply_message_ids"][Integer.to_string(index)]
            String.contains?(outcome, answer) and learned?(facts, answer, id)
          end),
      "quiet_state_preserved" =>
        before != %{} and Map.take(before, @stable) == Map.take(after_wait, @stable),
      "waited_six_hours" =>
        (after_wait["elapsed_seconds"] || 0) - (before["elapsed_seconds"] || 0) >= @quiet_seconds,
      "crossed_release" =>
        is_binary(before["runtime_revision"]) and is_binary(after_wait["runtime_revision"]) and
          before["runtime_revision"] != after_wait["runtime_revision"],
      "older_fact_used" =>
        is_binary(colour_id) and colour_id not in Enum.map(recent, & &1["message_id"]) and
          learned?(
            get_in(run.prompt_snapshot, ["fact_ledger", "facts"]) || %{},
            "indigo",
            colour_id
          ) and
          colour_id in (turn.data["decision"]["evidence"] || []) and
          Enum.any?(
            recalled,
            &(&1["reference"]["message_id"] == colour_id and
                Ledger.digest(&1["message"]) == &1["reference"]["digest"])
          ),
      "completion_independently_reviewed" =>
        Policy.approved?(turn.data["decision"], turn.data["policy_review"]),
      "configured_model_used" =>
        Enum.all?(turns, fn t ->
          entries = t.data["model_entries"] || %{}

          t.model == model and map_size(entries) == t.model_calls and
            Enum.all?(entries, fn {_, entry} ->
              entry["state"] == "settled" and entry["actual_model"] == model
            end)
        end),
      "within_limits" =>
        d.lifetime_sends in 4..6 and d.lifetime_micro_usd <= 100_000 and
          Enum.all?(turns, &(&1.model_calls <= 3))
    }

    Map.merge(state, %{
      "phase" =>
        if(Enum.all?(checks, fn {_, passed} -> passed end), do: "passed", else: "failed"),
      "canary_checks" => checks,
      "people_context_count" => length(run.prompt_snapshot["people"] || []),
      "final_observation" => snapshot(d)
    })
  end

  defp learned?(facts, answer, id) do
    is_binary(id) and
      Enum.any?(facts, fn {_, fact} ->
        String.contains?(String.downcase(fact["text"]), answer) and
          Enum.any?(fact["evidence"], &(&1["message_id"] == id))
      end)
  end
end
