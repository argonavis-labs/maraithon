defmodule Maraithon.Delegations.Outcomes do
  @moduledoc "Apply proven conversation progress to the todo while preserving its owner."
  alias Maraithon.{Repo, Todos}
  alias Maraithon.Delegations.{Actions, Authority, Jobs, Policy, Preferences, Turn}
  alias Maraithon.Todos.{Todo, Workflow}

  def follow_up(d, grant, now) do
    prefs = Preferences.get(d.user_id)

    limit =
      get_in(grant.data, ["scope", "limits", "reminders_per_cycle"]) ||
        prefs["reminders_per_cycle"]

    next = if d.reminder_count_cycle < limit, do: Preferences.follow_up_at(now, prefs)
    %{d | follow_up_at: next, next_wake_at: next}
  end

  def apply(d, grant, event, kind) do
    todo = Repo.get_by!(Todo, id: d.todo_id, user_id: d.user_id)
    workflow = Workflow.current(todo)

    if workflow["revision"] == d.workflow_revision and todo.status in ~w(open snoozed) do
      context = if event.data["turn_id"], do: Jobs.context!(d, event)

      with {:ok, attrs} <- transition(d, grant, context, kind),
           {:ok, updated} <-
             Todos.transition_workflow(
               d.user_id,
               d.todo_id,
               Map.merge(attrs, %{
                 "owner" => grant.data["scope"]["task_owner"] || workflow["owner"],
                 "outcome" => grant.data["scope"]["outcome"],
                 "expected_revision" => workflow["revision"],
                 "request_id" => "delegation:#{d.id}:#{event.id}"
               })
             ) do
        if context && context.turn.status == "validated",
          do: context.turn |> Turn.changeset(%{status: "settled"}) |> Repo.update!()

        data =
          if context && is_map(context.turn.data["decision"]) do
            decision = context.turn.data["decision"]
            sources = context.run.prompt_snapshot["sources"]

            Map.merge(d.data, %{
              "last_action" => attrs["next_action"],
              "evidence" =>
                Enum.map(decision["evidence"] || [], fn id ->
                  %{"source" => "gmail", "account_id" => sources["account_id"], "id" => id}
                end),
              "ledger" => Map.put(d.data["ledger"] || %{}, "latest_outcome", decision["reason"])
            })
          else
            d.data
          end

        %{d | workflow_revision: Workflow.current(updated)["revision"], data: data}
      else
        {:error, _} -> needs_review(d)
      end
    else
      needs_review(d)
    end
  end

  defp transition(d, _grant, context, :complete) do
    decision = context.turn.data["decision"]

    with true <- Authority.workflow_current?(d),
         {:ok, %{"kind" => "complete"}} <- Policy.validate(context, decision),
         true <- Policy.approved?(decision, context.turn.data["policy_review"]) do
      {:ok,
       %{
         "state" => "done",
         "outcome_confirmed" => true,
         "next_action" => "Done.",
         "reason" => decision["reason"]
       }}
    else
      _ -> {:error, :outcome_not_proven}
    end
  end

  defp transition(_d, _grant, context, :booked) do
    slot =
      Enum.find(
        context.delegation.data["offered_slots"] || [],
        &(Policy.slot_id(&1) == context.turn.data["decision"]["accepted_slot_id"])
      )

    if slot,
      do:
        {:ok,
         %{
           "state" => "waiting",
           "waiting_until" => slot["start_at"],
           "next_action" => "Attend the confirmed meeting.",
           "reason" => "The calendar provider confirmed the meeting and invitations."
         }},
      else: {:error, :meeting_not_proven}
  end

  defp transition(%{state: "waiting_reply"} = d, _grant, _context, :progress),
    do:
      {:ok,
       %{
         "state" => "waiting",
         "waiting_until" => if(d.follow_up_at, do: DateTime.to_iso8601(d.follow_up_at)),
         "next_action" => "Waiting for the conversation to continue.",
         "reason" => "Maraithon is tracking the reply."
       }}

  defp transition(%{state: "needs_user"} = d, grant, _context, :progress) do
    state =
      if get_in(grant.data, ["scope", "task_owner", "kind"]) == "person",
        do: "they_own",
        else: "you_own"

    {:ok,
     %{
       "state" => state,
       "next_action" => d.data["question"] || "Review this conversation.",
       "reason" => "The delegated conversation needs clarification; the task owner is unchanged."
     }}
  end

  defp transition(_, _, _, _), do: {:error, :unsupported_workflow_transition}

  defp needs_review(d) do
    Actions.supersede_unentered!(d)

    %{
      d
      | state: "needs_user",
        next_wake_at: nil,
        data:
          Map.put(
            d.data,
            "question",
            "The todo changed while I was working. Please review the conversation and delegate it again if needed."
          )
    }
  end
end
