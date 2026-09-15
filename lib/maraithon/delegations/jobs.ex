defmodule Maraithon.Delegations.Jobs do
  @moduledoc "Durable turn admission and worker results in the existing runtime lanes."
  import Ecto.Query
  alias Maraithon.{Accounts, LLM, Repo}
  alias Maraithon.Delegations.{Authority, Binding, Outbox, Turn}

  alias Maraithon.Runtime.{
    BackgroundJob,
    BackgroundJobs,
    DatabaseClock,
    JobAuthority,
    PeriodicJobs
  }

  alias Maraithon.TelegramAssistant.Run

  # The coordinator already holds its task, user, and delegation fences. The
  # turn and job commit together; a BEAM message is never evidence of admission.
  def start_sync!(d, grant, event, now) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "turn admission needs authority")

    if Repo.exists?(
         from t in Turn,
           where: t.delegation_id == ^d.id and t.status in ~w(deciding validated dispatched)
       ) do
      d
    else
      seq = Repo.one(from t in Turn, where: t.delegation_id == ^d.id, select: max(t.seq)) || 0
      run_id = Ecto.UUID.generate()
      model = Accounts.assistant_model(d.user_id) || LLM.openrouter_model()

      turn =
        %Turn{user_id: d.user_id}
        |> Turn.changeset(%{
          delegation_id: d.id,
          seq: seq + 1,
          grant_version: grant.version,
          source_revision: d.source_revision,
          wake_reason: event.kind,
          model: model,
          data: %{
            "event_id" => event.id,
            "reminder" => event.kind == "timer_due" and not is_nil(d.follow_up_at)
          }
        })
        |> Repo.insert!()

      binding = Binding.context(d, turn, grant, run_id)

      %Run{id: run_id}
      |> Run.changeset(%{
        user_id: d.user_id,
        chat_id: "delegation:#{d.id}",
        surface: "delegation",
        trigger_type: "delegation_event",
        status: "queued",
        started_at: now,
        model_provider: "openrouter",
        model_name: model,
        prompt_snapshot: %{Binding.key() => binding},
        result_summary: %{}
      })
      |> Repo.insert!()

      turn |> Turn.changeset(%{run_id: run_id}) |> Repo.update!()
      enqueue!("delegation_sync", d, binding, now)
      %{d | state: "syncing", next_wake_at: nil, data: Map.delete(d.data, "hold_reason")}
    end
  end

  def enqueue!(kind, d, binding, available_at, extra \\ %{})
      when kind in ~w(delegation_sync delegation_decide delegation_send) do
    account =
      Repo.get_by!(Maraithon.Accounts.ConnectedAccount,
        id: d.connected_account_id,
        user_id: d.user_id
      )

    model? = kind == "delegation_decide"

    attrs = %{
      user_id: d.user_id,
      queue: if(model?, do: "runtime_model_user", else: "runtime_provider_account"),
      partition_key:
        if(model?,
          do: "delegation:#{d.id}",
          else: PeriodicJobs.provider_partition(d.user_id, account.provider)
        ),
      rate_limit_key:
        if(model?,
          do: "model",
          else: Maraithon.Runtime.TokenRefresher.provider_family(account.provider)
        ),
      dedupe_key: "#{kind}:#{binding["turn_id"]}",
      scheduled_at: available_at,
      max_attempts: 3,
      payload: Map.merge(binding, extra)
    }

    case BackgroundJobs.enqueue(kind, attrs) do
      {:ok, job} -> job
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def start_decide!(d, event, now) do
    context = context!(d, event)
    binding = context.run.prompt_snapshot[Binding.key()]

    if Authority.current?(context, binding) and is_map(context.run.prompt_snapshot["sources"]) do
      enqueue!("delegation_decide", d, binding, now)
      %{d | state: "deciding", next_wake_at: nil}
    else
      Repo.rollback(:delegation_source_not_current)
    end
  end

  def context!(d, event) do
    turn =
      Repo.get_by!(Turn, id: event.data["turn_id"], delegation_id: d.id, user_id: d.user_id)
      |> Turn.hydrate()

    run = Repo.get_by!(Run, id: turn.run_id, user_id: d.user_id) |> Run.hydrate_payloads()
    binding = run.prompt_snapshot[Binding.key()]
    Authority.lock_context!(binding, d.user_id)
  end

  def transaction(%BackgroundJob{} = job, fun) do
    JobAuthority.transaction(job, fn ->
      context = Authority.lock_context!(Map.delete(job.payload, "action_id"), job.user_id)

      unless Authority.matches_job?(job, context.run.prompt_snapshot[Binding.key()]),
        do: Repo.rollback(:delegation_job_mismatch)

      if Authority.current?(context, job.payload), do: fun.(context), else: :superseded
    end)
  end

  def result!(context, kind, data) do
    binding = context.run.prompt_snapshot[Binding.key()]

    Outbox.append!(
      context.delegation,
      kind,
      "#{kind}:#{context.turn.id}",
      Map.merge(data, Map.take(binding, ~w(turn_id grant_version run_id source_revision)))
    )
  end

  def hold!(context, reason) do
    context.run
    |> Run.changeset(%{status: "degraded", finished_at: DatabaseClock.now!(), error: reason})
    |> Repo.update!()

    result!(context, "failure", %{
      "reason" => reason,
      "question" => "I couldn't fully read this conversation. Please review it before I continue."
    })
  end

  def finish({:ok, :superseded}, job), do: finish({:ok, %{state: "superseded"}}, job)

  def finish({:ok, result}, job) do
    Outbox.publish_pending(job.user_id)
    {:ok, result}
  end

  def finish(error, _job), do: error
end
