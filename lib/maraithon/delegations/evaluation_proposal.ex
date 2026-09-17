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
    Code.ensure_loaded!(Maraithon.Behaviors.AIChiefOfStaff)

    Repo.all(
      from a in Maraithon.Agents.Agent,
        where: a.user_id == ^job.user_id,
        where:
          a.behavior == "ai_chief_of_staff" or
            (a.behavior == "manifest_agent" and
               fragment("?->>'source_behavior'", a.config) == "ai_chief_of_staff"),
        order_by: [desc: a.updated_at],
        limit: 3
    )
    |> Enum.map(fn agent ->
      snapshot =
        Repo.one(
          from s in Maraithon.Runtime.Snapshot,
            where: s.agent_id == ^agent.id and is_nil(s.payload_purged_at),
            order_by: [desc: s.sequence_num, desc: s.id],
            limit: 1
        )

      {state, decode_error} =
        if snapshot do
          snapshot = Maraithon.Runtime.Snapshot.hydrate_payloads!(snapshot)

          case Maraithon.Runtime.SnapshotFormat.decode_stored(
                 diagnostic_snapshot(snapshot.state_data)
               ) do
            {:ok, state, _} when is_map(state) -> {state, nil}
            {:error, reason} -> {%{}, Maraithon.Redaction.error_class(reason)}
          end
        else
          {%{}, "no_snapshot"}
        end

      state = state[:source_state] || state

      %{
        agent_id: agent.id,
        status: agent.status,
        install_status: agent.install_status,
        snapshot: if(snapshot, do: Map.take(snapshot, [:sequence_num, :state_name]), else: nil),
        snapshot_decode_error: decode_error,
        failed_steps:
          Repo.all(
            from s in Maraithon.Agents.AgentRunStep,
              where: s.agent_id == ^agent.id and s.status == "failed",
              order_by: [desc: s.started_at],
              limit: 3
          )
          |> Enum.map(&failed_step_summary/1),
        memo_updated_at: get_in(state, [:cycle_memory, "updated_at"]),
        pending_skill: state[:pending_effect_skill_id],
        cycle_memo_generated: state[:cycle_memo_generated],
        delegation_review_attempted_at: state[:delegation_review_attempted_at],
        delegation_review_recorded:
          if(is_nil(decode_error), do: is_binary(state[:delegation_review_digest]))
      }
    end)
  end

  def diagnostics(_job), do: nil

  # A release eval has no running skills to load every historical state symbol.
  # Project only the known planning fields, then use the same closed decoder.
  # This is a read-only summary, never a replacement or restored checkpoint.
  defp diagnostic_snapshot(
         %{
           "format" => "maraithon.agent_snapshot",
           "format_version" => 1,
           "value" => %{"$type" => "map", "entries" => entries} = value
         } = envelope
       )
       when map_size(envelope) == 3 and map_size(value) == 2 and is_list(entries) do
    state =
      Enum.find_value(entries, value, fn
        [key, %{"$type" => "map", "entries" => nested} = source]
        when map_size(source) == 2 and is_list(nested) ->
          if snapshot_key(key) == "source_state", do: source

        _ ->
          nil
      end)

    fields = ~w(cycle_memory pending_effect_skill_id cycle_memo_generated
                delegation_review_attempted_at delegation_review_digest)

    selected =
      Enum.filter(state["entries"], fn
        [key, _value] -> snapshot_key(key) in fields
        _ -> false
      end)

    Map.put(envelope, "value", %{"$type" => "map", "entries" => selected})
  end

  defp diagnostic_snapshot(value), do: value

  defp snapshot_key(%{"$type" => "symbol", "value" => name} = key)
       when map_size(key) == 2 and is_binary(name),
       do: name

  defp snapshot_key(name) when is_binary(name), do: name
  defp snapshot_key(_), do: nil

  defp failed_step_summary(step) do
    summary = %{
      effect_type: step.effect_type,
      error: Maraithon.Redaction.log_metadata_value(:failure_code, step.error),
      at: step.started_at
    }

    if step.effect_type == "llm_call" and is_nil(step.payload_purged_at) do
      step = Maraithon.Agents.AgentRunStep.hydrate_payloads!(step)
      params = step.request_payload

      request =
        cond do
          is_map(params["request_rejection"]) ->
            %{available: false, rejection: params["request_rejection"]}

          params == %{} ->
            %{available: false}

          true ->
            %{
              available: true,
              valid: match?({:ok, _}, Maraithon.LLM.RequestBudget.validate(params)),
              bytes: byte_size(Jason.encode!(params)),
              messages: length(params["messages"] || []),
              tools: length(params["tools"] || [])
            }
        end

      Map.put(summary, :request, request)
    else
      summary
    end
  end

  def source_failures(%{payload: %{"scenario" => %{"entry" => "proposal"}}} = job) do
    since = DateTime.add(DateTime.utc_now(), -1, :hour)
    job_types = Maraithon.Runtime.BackgroundJobs.source_account_job_types()

    # Retain distinct causes so repeated deployment interruptions do not hide
    # a processing failure that happened earlier in the same bounded window.
    failures =
      from j in Maraithon.Runtime.BackgroundJob,
        where: j.user_id == ^job.user_id and j.status == "failed" and j.updated_at >= ^since,
        where: j.job_type in ^job_types,
        windows: [
          cause: [
            partition_by: [j.job_type, j.last_error],
            order_by: [desc: j.updated_at, desc: j.id]
          ]
        ],
        select: %{
          job_id: j.id,
          job_type: j.job_type,
          error: j.last_error,
          at: j.updated_at,
          attempts: j.attempts,
          cause_rank: over(row_number(), :cause)
        }

    Repo.all(
      from j in subquery(failures),
        where: j.cause_rank == 1,
        order_by: [desc: j.at, desc: j.job_id],
        limit: 16,
        select: %{
          job_id: type(j.job_id, Ecto.UUID),
          job_type: j.job_type,
          error: j.error,
          at: type(j.at, :utc_datetime_usec),
          attempts: j.attempts
        }
    )
    |> Enum.map(fn failure ->
      if failure.error == "source_discovery_incomplete_decisions" and
           failure.job_type == "runtime_partition:source_account_discovery_reason" do
        source_job =
          Repo.get!(Maraithon.Runtime.BackgroundJob, failure.job_id)
          |> Maraithon.Runtime.BackgroundJob.hydrate_payloads()

        account =
          Repo.get_by!(ConnectedAccount,
            id: source_job.payload["account_id"],
            user_id: job.user_id
          )

        Map.merge(failure, %{
          account_id: account.id,
          handoff:
            Maraithon.Runtime.SourceAccountDiscovery.handoff_diagnostics(
              account,
              source_job.payload
            )
        })
      else
        failure
      end
    end)
  end

  def source_failures(_job), do: []

  def source_cycles(%{payload: %{"scenario" => %{"entry" => "proposal"}}} = job) do
    Maraithon.ConnectedAccounts.list_personal_for_user(job.user_id)
    |> Enum.filter(&(&1.status == "connected"))
    |> Enum.take(10)
    |> Enum.map(fn account ->
      acquisition =
        Repo.one(
          from j in Maraithon.Runtime.BackgroundJob,
            where: j.user_id == ^job.user_id,
            where: j.dedupe_key == ^"runtime-partition:source-account-discovery:#{account.id}",
            order_by: [desc: j.inserted_at, desc: j.id],
            limit: 1
        )

      completed =
        Repo.one(
          from j in Maraithon.Runtime.BackgroundJob,
            where: j.user_id == ^job.user_id and j.status == "completed",
            where:
              like(
                j.dedupe_key,
                ^"runtime-partition:source-account-discovery-finalize:#{account.id}:%"
              ),
            order_by: [desc: j.completed_at, desc: j.id],
            limit: 1
        )

      %{
        account_id: account.id,
        provider: account.provider,
        acquisition: cycle_summary(acquisition),
        last_completed: cycle_summary(completed)
      }
    end)
  end

  def source_cycles(_job), do: []

  defp cycle_summary(nil), do: nil

  defp cycle_summary(row) do
    job = Maraithon.Runtime.BackgroundJob.hydrate_payloads(row)
    children = (job.result || %{})["reason_job_ids"] || []
    children = Enum.take(children, 200)

    counts =
      Repo.all(
        from j in Maraithon.Runtime.BackgroundJob,
          where: j.user_id == ^job.user_id and j.id in ^children,
          group_by: j.status,
          select: {j.status, count(j.id)}
      )
      |> Map.new()

    %{
      job_id: job.id,
      status: job.status,
      updated_at: job.updated_at,
      completed_at: job.completed_at,
      result:
        Map.take(
          job.result || %{},
          ~w(outcome source_items fanout_count decision_count advanced_watermarks finalizer_job_id)
        ),
      children: counts
    }
  end

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
