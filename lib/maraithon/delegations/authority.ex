defmodule Maraithon.Delegations.Authority do
  @moduledoc "Job and record authority for delegated runs and prepared actions."
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.AssistantChat.Execution
  alias Maraithon.Delegations.{Binding, Delegation, Gates, Grant, Scope, Turn}
  alias Maraithon.Runtime.{BackgroundJob, DatabaseClock, JobAuthority}
  alias Maraithon.TelegramAssistant.{PreparedAction, Run}

  # Called before the PreparedAction lock, including for receipts after a stop.
  # Current control state governs entry, not whether an earlier outcome survives.
  def lock_action_scope!(%PreparedAction{authorization_kind: "delegation_grant"} = action) do
    job = Execution.capture_authority()
    require_job!(job, action.user_id)

    unless job.job_type in ~w(delegation_send assistant_action_reconcile) and
             job.payload["action_id"] == action.id,
           do: Repo.rollback(:delegation_job_mismatch)

    context = lock_context!(action.payload[Binding.key()], action.user_id)

    unless context.turn.prepared_action_id == action.id,
      do: Repo.rollback(:delegation_action_mismatch)

    context
  end

  def lock_action_scope!(_), do: :ok

  # A public Runner call cannot bypass the durable entry. The short transaction
  # ends before provider I/O; its job owner keeps the existing execution heartbeat.
  def before_provider(%PreparedAction{authorization_kind: "delegation_grant"} = action) do
    case Execution.capture_authority() do
      %BackgroundJob{job_type: "delegation_send"} = job ->
        case JobAuthority.transaction(job, fn ->
               action = PreparedAction.hydrate_payload(action)
               context = lock_action_scope!(action)

               current =
                 locked(PreparedAction, action.id, action.user_id)
                 |> PreparedAction.hydrate_payload()

               binding = action.payload[Binding.key()]

               with true <- matches_job?(job, binding) and current?(context, binding),
                    true <- Gates.sends_enabled?(action.user_id, context.delegation.provider),
                    true <-
                      current.status == "confirmed" and context.turn.status == "dispatched" and
                        context.delegation.state == "sending",
                    token when is_binary(token) <- action.payload["_maraithon_execution_token"],
                    ^token <- current.payload["_maraithon_execution_token"],
                    true <-
                      Map.delete(current.payload, "_maraithon_execution_lease_until") ==
                        Map.delete(action.payload, "_maraithon_execution_lease_until"),
                    {:ok, until, _} <-
                      DateTime.from_iso8601(
                        current.payload["_maraithon_execution_lease_until"] || ""
                      ),
                    :gt <- DateTime.compare(until, DatabaseClock.now!()) do
                 :ok
               else
                 _ -> Repo.rollback(:delegation_entry_not_current)
               end
             end) do
          {:ok, :ok} -> :ok
          error -> error
        end

      _ ->
        {:error, :delegation_job_required}
    end
  end

  def before_provider(_), do: :ok

  def write_run(%Run{} = run, fun) do
    case Execution.capture_authority() do
      %BackgroundJob{job_type: "delegation_decide", user_id: user_id} = job
      when user_id == run.user_id ->
        case JobAuthority.transaction(job, fn ->
               current = Repo.get_by!(Run, id: run.id, user_id: user_id) |> Run.hydrate_payloads()
               binding = current.prompt_snapshot[Binding.key()]

               unless matches_job?(job, binding), do: Repo.rollback(:delegation_job_mismatch)
               context = lock_context!(binding, user_id)
               fun.(context.run)
             end) do
          {:ok, result} -> result
          error -> error
        end

      _ ->
        {:error, :delegation_job_required}
    end
  end

  def matches_job?(%BackgroundJob{payload: payload, user_id: user_id}, binding)
      when is_map(payload) and is_map(binding) do
    user_id == binding["user_id"] and
      Enum.all?(~w(delegation_id turn_id run_id grant_version), &(payload[&1] == binding[&1]))
  end

  def matches_job?(_, _), do: false

  @doc "Lock in delegation, turn, run order under an existing runtime or user fence."
  def lock_context!(binding, user_id) when is_map(binding) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "delegation authority needs a transaction")

    d = locked(Delegation, binding["delegation_id"], user_id) |> Delegation.hydrate()
    turn = locked(Turn, binding["turn_id"], user_id) |> Turn.hydrate()
    run = locked(Run, binding["run_id"], user_id) |> Run.hydrate_payloads()

    grant =
      Repo.get_by!(Grant, delegation_id: d.id, user_id: user_id, version: turn.grant_version)
      |> Grant.hydrate()

    unless turn.delegation_id == d.id and turn.run_id == run.id and
             turn.grant_version == binding["grant_version"] and
             turn.source_revision == binding["source_revision"] and
             binding["scope_hash"] == grant.data["scope_hash"] and
             Scope.hash(grant.data["scope"]) == grant.data["scope_hash"] and
             run.prompt_snapshot[Binding.key()] == binding,
           do: Repo.rollback(:delegation_record_mismatch)

    %{delegation: d, turn: turn, run: run, grant: grant}
  end

  def lock_context!(_, _), do: Repo.rollback(:delegation_binding_required)

  @doc "Current authority for a new decision; late receipts use the historical grant above."
  def current?(%{delegation: d, turn: turn, grant: grant}, binding) do
    d.schema_version == 1 and grant.policy_version == 1 and
      d.current_grant_id == grant.id and grant.control_state == "active" and
      turn.status in ~w(deciding validated dispatched) and
      d.state in ~w(ready syncing deciding sending) and
      d.source_revision == binding["source_revision"] and
      d.workflow_revision == binding["workflow_revision"]
  end

  defp require_job!(%BackgroundJob{user_id: user_id} = job, user_id) do
    JobAuthority.fence!(job)
    :ok
  end

  defp require_job!(_, _), do: Repo.rollback(:delegation_job_required)

  defp locked(schema, id, user_id),
    do:
      Repo.one!(
        from r in schema, where: r.id == ^id and r.user_id == ^user_id, lock: "FOR UPDATE"
      )
end
