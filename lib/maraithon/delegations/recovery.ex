defmodule Maraithon.Delegations.Recovery do
  @moduledoc "Bounded repair of proven-dead, read-only decision workers. Sends never replay."
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Delegations.{Authority, Binding, Delegation, Gates, Jobs, Turn}
  alias Maraithon.Runtime.{BackgroundJob, DatabaseClock, JobAuthority}
  alias Maraithon.Runtime.Coordination.TaskAssignment
  alias Maraithon.TelegramAssistant.{Continuation, Run}

  def run_once(%BackgroundJob{job_type: "runtime_recurring:delegation_due_sweep"} = job, user_id)
      when is_nil(job.user_id) or job.user_id == user_id do
    JobAuthority.transaction(job, fn ->
      Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(user_id)

      # Terminal jobs retain their task evidence. The existing active-job key
      # prevents parallel replacements; no old claim or assignment is reset.
      Repo.all(
        from t in Turn,
          as: :turn,
          join: d in Delegation,
          on: d.id == t.delegation_id and d.user_id == t.user_id,
          join: r in Run,
          on: r.id == t.run_id and r.user_id == t.user_id,
          join: j in BackgroundJob,
          on:
            j.user_id == t.user_id and j.job_type == "delegation_decide" and
              j.dedupe_key == fragment("'delegation_decide:' || ?::text", t.id),
          join: a in TaskAssignment,
          on: a.id == j.coordination_task_assignment_id,
          where:
            t.user_id == ^user_id and t.status == "deciding" and d.state == "deciding" and
              r.status in ~w(queued running) and j.status == "failed" and
              a.state == "outcome_ambiguous",
          where:
            not exists(
              from active in BackgroundJob,
                where:
                  active.dedupe_key ==
                    fragment("'delegation_decide:' || ?::text", parent_as(:turn).id) and
                    active.status in ~w(pending running),
                select: 1
            ),
          distinct: r.id,
          order_by: r.id,
          limit: 25,
          select: r
      )
      |> Enum.count(&recover?/1)
    end)
  end

  defp recover?(run) do
    binding = Run.hydrate_payloads(run).prompt_snapshot[Binding.key()]
    context = Authority.lock_context!(binding, run.user_id)
    key = "delegation_decide:#{context.turn.id}"

    latest =
      Repo.one(
        from j in BackgroundJob,
          where:
            j.user_id == ^run.user_id and j.job_type == "delegation_decide" and
              j.dedupe_key == ^key,
          order_by: [desc: j.inserted_at, desc: j.id],
          limit: 1
      )
      |> BackgroundJob.hydrate_payloads()

    if Authority.current?(context, binding) and Authority.workflow_current?(context.delegation) and
         Gates.scope_enabled?(context.delegation, context.grant) and proven_dead?(latest, binding) do
      count = context.turn.data["decision_recoveries"] || 0

      if count < 2 do
        now = DatabaseClock.now!()
        restore!(context, now)

        turn = Repo.get!(Turn, context.turn.id) |> Turn.hydrate()

        turn
        |> Turn.changeset(%{
          data:
            Map.merge(turn.data, %{
              "decision_recoveries" => count + 1,
              "decision_recovery_job_id" => latest.id
            })
        })
        |> Repo.update!()

        Jobs.enqueue!("delegation_decide", context.delegation, binding, now)
      else
        context.run
        |> Run.changeset(%{
          status: "degraded",
          error: "decision_recovery_exhausted",
          finished_at: DatabaseClock.now!()
        })
        |> Repo.update!()

        Jobs.result!(context, "failure", %{
          "question" =>
            "I couldn't finish this step after several retries. Please review this conversation."
        })
      end

      true
    else
      false
    end
  end

  defp proven_dead?(%{status: "failed", job_type: "delegation_decide"} = job, binding) do
    with true <- Map.take(job.payload, Map.keys(binding)) == binding,
         %TaskAssignment{} = a <- Repo.get(TaskAssignment, job.coordination_task_assignment_id) do
      a.work_kind == "background_job" and a.work_id == job.id and
        a.claim_token == job.claim_token and a.state == "outcome_ambiguous" and
        not is_nil(a.termination_proven_at) and a.outcome == "provider_outcome_ambiguous"
    else
      _ -> false
    end
  end

  defp proven_dead?(_, _), do: false

  defp restore!(context, now) do
    run = context.run

    if Continuation.present?(run) do
      attrs = %{
        user_id: run.user_id,
        source_message_id: context.turn.data["event_id"],
        delegation_binding: run.prompt_snapshot[Binding.key()]
      }

      case Continuation.load(run, attrs) do
        {:ok, checkpoint, _, _} ->
          checkpoint = retry_checkpoint!(context, checkpoint)

          # A bounded replacement gets time to execute after an outage, while
          # model-call counts, settled spend and unknown reservations survive.
          deadline =
            DateTime.to_unix(now, :millisecond) +
              min(checkpoint["policy"]["max_wall_clock_ms"], 120_000)

          run
          |> Run.changeset(%{
            result_summary:
              Map.put(
                run.result_summary,
                "execution_checkpoint",
                Map.put(checkpoint, "deadline_ms", deadline)
              )
          })
          |> Repo.update!()

        {:error, _} ->
          # Let the replacement worker publish its existing invalid-checkpoint
          # hold under its own claim. Never rewrite unreadable state.
          :ok
      end
    end
  end

  defp retry_checkpoint!(context, %{"phase" => "model_entered"} = checkpoint) do
    stage = checkpoint["delegation_stage"]
    entries = context.turn.data["model_entries"] || %{}

    if stage in ~w(compose repair policy) and get_in(entries, [stage, "state"]) == "entered" do
      archived = "#{stage}:interrupted:#{context.turn.model_calls}"
      entries = entries |> Map.put(archived, entries[stage]) |> Map.delete(stage)

      context.turn
      |> Turn.changeset(%{data: Map.put(context.turn.data, "model_entries", entries)})
      |> Repo.update!()

      checkpoint |> Map.put("phase", "ready") |> Map.put("retry_stage", stage)
    else
      checkpoint
    end
  end

  defp retry_checkpoint!(_, checkpoint), do: checkpoint
end
