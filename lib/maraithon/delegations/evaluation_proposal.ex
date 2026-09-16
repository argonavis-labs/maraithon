defmodule Maraithon.Delegations.EvaluationProposal do
  @moduledoc "Controlled provider fixture that waits for a real Chief of Staff proposal and UI acceptance."
  import Ecto.Query
  alias Maraithon.{Crm, Delegations, Repo}
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.ChiefOfStaff.Skills.DelegationProposals
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Crm.Observation
  alias Maraithon.Runtime.JobAuthority
  alias Maraithon.Todos.{Todo, Workflow}

  def diagnostics(%{payload: %{"scenario" => %{"entry" => "proposal"}}} = job) do
    Repo.all(
      from a in Maraithon.Agents.Agent,
        where: a.user_id == ^job.user_id and a.behavior == "ai_chief_of_staff",
        order_by: [desc: a.updated_at],
        limit: 3
    )
    |> Enum.map(fn agent ->
      snapshot = Maraithon.Runtime.Snapshot.latest(agent.id) || %{}
      state = snapshot[:behavior_state] || %{}

      %{
        agent_id: agent.id,
        status: agent.status,
        install_status: agent.install_status,
        snapshot: Map.take(snapshot, [:sequence_num, :state_name]),
        memo_updated_at: get_in(state, [:cycle_memory, "updated_at"]),
        pending_skill: state[:pending_effect_skill_id],
        cycle_memo_generated: state[:cycle_memo_generated]
      }
    end)
  end

  def diagnostics(_job), do: nil

  def prepare(job, todo, message) do
    JobAuthority.transaction(job, fn ->
      account = Repo.get_by!(ConnectedAccount, id: todo.source_account_id, user_id: job.user_id)
      :ok = Gmail.ingest_messages(job.user_id, [message], account: account)

      source =
        Repo.get_by!(Observation,
          user_id: job.user_id,
          source: "gmail",
          source_item_id: "#{account.provider}:#{message.message_id}"
        )

      person = Crm.find_person_by_contact(job.user_id, job.payload["sender_identity"]["email"])

      unless person && person.id in source.resolved_person_ids,
        do: Repo.rollback(:eval_counterparty_not_resolved)

      {:ok, workflow} =
        Workflow.transition(
          todo,
          %{
            "state" => "you_own",
            "expected_revision" => Workflow.current(todo)["revision"],
            "outcome" => job.payload["scenario"]["outcome"],
            "next_action" => todo.next_action,
            "reason" => "Controlled eval received its source email."
          },
          Workflow.user_owner(todo)
        )

      todo
      |> Todo.changeset(%{
        counterparty_person_id: person.id,
        counterparty_label: person.display_name,
        source_occurred_at: message.internal_date,
        workflow: workflow
      })
      |> Repo.update!()
    end)
  end

  def wait(job, state) do
    JobAuthority.transaction(job, fn ->
      todo = Repo.get_by!(Todo, id: state["todo_id"], user_id: job.user_id)
      delegation = Delegations.for_todo(job.user_id, todo.id)

      cond do
        delegation ->
          unless is_map(state["proposal"]) and delegation.actor == state["proposal"]["actor"] and
                   delegation.kind == state["proposal"]["kind"],
                 do: Repo.rollback(:eval_proposal_acceptance_not_proven)

          Map.merge(state, %{
            "phase" => "waiting_for_agent",
            "delegation_id" => delegation.id,
            "proposal_accepted_at" => DateTime.to_iso8601(delegation.inserted_at)
          })

        proposal = DelegationProposals.current(todo) ->
          state
          |> Map.put("phase", "waiting_for_proposal_acceptance")
          |> Map.put("proposal", Map.take(proposal, ~w(actor kind label rank)))
          |> Map.put_new("proposal_seen_at", DateTime.to_iso8601(DateTime.utc_now()))

        true ->
          state
          |> Map.put("phase", "waiting_for_proposal")
          |> Map.put(
            "proposal_candidate_ready",
            Enum.any?(DelegationProposals.candidates(job.user_id), &(&1["todo_id"] == todo.id))
          )
      end
    end)
    |> case do
      {:ok, next} -> {:wait, next}
      error -> error
    end
  end
end
