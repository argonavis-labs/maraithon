defmodule Maraithon.Runtime.AgentRestartGuards do
  @moduledoc """
  Durable, exact-owner restart backoff and crash-loop fencing.

  The guard is written before the matching lease is removed in one transaction.
  Its lock prefix includes LifecycleOperation after Lease and before Directive.
  A replacement token or a duplicate delayed `:DOWN` can therefore never be
  counted against the current incarnation.
  """

  import Ecto.Query

  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents.Agent
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.Coordination.Scope

  @default_window_ms 600_000
  @default_max_crashes 3
  @default_backoffs_ms [5_000, 15_000, 30_000]
  @max_window_ms 86_400_000
  @max_backoff_ms 3_600_000
  @max_crashes 100

  def record_crash(agent_id, owner_token, reason, opts \\ [])

  def record_crash(agent_id, owner_token, reason, opts) when is_list(opts) do
    record_loss(agent_id, owner_token, reason, opts, false)
  end

  def record_crash(_agent_id, _owner_token, _reason, _opts),
    do: {:error, :invalid_restart_guard}

  @doc """
  Records an expired generation only after rechecking expiry while holding the
  exact Agent -> Binding -> Guard -> Lease locks. A stale sweeper hint can
  therefore never delete a lease that renewed before its transaction began.
  """
  def record_expired(agent_id, owner_token, opts \\ [])

  def record_expired(agent_id, owner_token, opts) when is_list(opts) do
    record_loss(agent_id, owner_token, :lease_expired, opts, true)
  end

  def record_expired(_agent_id, _owner_token, _opts),
    do: {:error, :invalid_restart_guard}

  defp record_loss(agent_id, owner_token, reason, opts, require_expired?) do
    protocol_mode = ProtocolCutover.mode()

    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token),
         {:ok, policy} <- policy(opts) do
      Repo.transaction(fn ->
        if protocol_mode == :exact, do: ProtocolCutover.require_exact_reconciliation!()

        agent = lock_agent!(agent_id)
        coordination = Scope.authorize_reconciliation!(agent)
        _binding = lock_binding(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        _operation = lock_operation(agent_id)
        now = DatabaseClock.now!()

        case matching_owner(lease, guard, owner_token) do
          {:duplicate, %AgentRestartGuard{} = duplicate} ->
            {:duplicate, duplicate}

          :stale ->
            {:ignored, :stale_owner}

          {:exact, %AgentRuntimeLease{} = exact_lease} ->
            if require_expired? and DateTime.compare(exact_lease.lease_until, now) == :gt do
              {:ignored, :lease_renewed}
            else
              {window_started_at, crash_count} = next_window(guard, now, policy.window_ms)
              tripped = crash_count >= policy.max_crashes

              blocked_until =
                if tripped, do: nil, else: deadline(now, backoff(policy, crash_count))

              attrs = %{
                agent_id: agent_id,
                generation: Ecto.UUID.generate(),
                last_owner_token: owner_token,
                blocked_until: blocked_until,
                window_started_at: window_started_at,
                crash_count: crash_count,
                tripped: tripped,
                needs_recovery: true,
                last_reason: safe_reason(reason)
              }

              stored_guard = put_guard!(guard, attrs, now)

              if tripped and agent.status not in ["stopped", "terminated"] do
                agent
                |> Ecto.Changeset.change(%{
                  status: "stopped",
                  stopped_at: now,
                  updated_at: now
                })
                |> Repo.update!()
              end

              if tripped and protocol_mode == :exact do
                cancel_pending_for_tripped_agent!(agent_id, now, coordination)
              end

              # Guard evidence and pending-work settlement are durable before the
              # exact matching lease vanishes.
              Repo.delete!(exact_lease)
              {:recorded, stored_guard}
            end
        end
      end)
      |> unwrap_transaction()
    end
  end

  @doc "Settles pending exact work left behind by tripped crash-loop guards."
  def reconcile_tripped_pending(limit \\ 100)

  def reconcile_tripped_pending(limit) when is_integer(limit) and limit in 1..500 do
    case ProtocolCutover.mode() do
      :legacy ->
        {:ok, 0}

      :exact ->
        from(guard in AgentRestartGuard,
          join: agent in Agent,
          as: :agent,
          on: agent.id == guard.agent_id,
          join: effect in Effect,
          on:
            effect.agent_id == guard.agent_id and effect.status == "pending" and
              not is_nil(effect.runtime_owner_generation) and is_nil(effect.claimed_by) and
              is_nil(effect.claimed_at) and is_nil(effect.claim_token) and
              is_nil(effect.claim_owner_node) and is_nil(effect.claim_heartbeat_at) and
              is_nil(effect.claim_expires_at) and is_nil(effect.claim_supervisor_id) and
              is_nil(effect.claim_task_id),
          where: guard.tripped and guard.needs_recovery,
          where: not is_nil(guard.last_owner_token),
          group_by: [guard.agent_id, guard.generation],
          order_by: [asc: min(effect.inserted_at), asc: guard.agent_id],
          limit: ^limit,
          select: {guard.agent_id, guard.generation}
        )
        |> Scope.all_ready_agent()
        |> Enum.reduce_while({:ok, 0}, fn {agent_id, generation}, {:ok, total} ->
          case reconcile_tripped_generation(agent_id, generation) do
            {:ok, count} -> {:cont, {:ok, total + count}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:blocked, reason} ->
        {:error, {:effect_protocol_mismatch, reason}}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  def reconcile_tripped_pending(_limit), do: {:error, :invalid_restart_guard_limit}

  def reset_for_operator(agent_id) do
    with {:ok, agent_id} <- cast_uuid(agent_id) do
      Repo.transaction(fn ->
        agent = lock_agent!(agent_id)
        _binding = lock_binding(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        now = DatabaseClock.now!()

        if operation, do: Repo.rollback(:agent_drain_pending)
        if lease, do: Repo.rollback(:runtime_lease_owned)
        ensure_no_processing_directive!(agent_id)

        put_guard!(
          guard,
          %{
            agent_id: agent_id,
            generation: Ecto.UUID.generate(),
            last_owner_token: nil,
            blocked_until: nil,
            window_started_at: nil,
            crash_count: 0,
            tripped: false,
            needs_recovery: false,
            last_reason: nil
          },
          now
        )
      end)
    end
  end

  def get(agent_id) do
    case cast_uuid(agent_id) do
      {:ok, agent_id} -> Repo.get(AgentRestartGuard, agent_id)
      {:error, :invalid_restart_guard} -> nil
    end
  end

  defp matching_owner(nil, %AgentRestartGuard{} = guard, owner_token) do
    if guard.last_owner_token == owner_token and (guard.needs_recovery or guard.tripped),
      do: {:duplicate, guard},
      else: :stale
  end

  defp matching_owner(
         %AgentRuntimeLease{owner_token: owner_token} = lease,
         _guard,
         owner_token
       ),
       do: {:exact, lease}

  defp matching_owner(_lease, _guard, _owner_token), do: :stale

  defp next_window(nil, now, _window_ms), do: {now, 1}

  defp next_window(%AgentRestartGuard{} = guard, now, window_ms) do
    if is_nil(guard.window_started_at) or
         DateTime.diff(now, guard.window_started_at, :millisecond) > window_ms do
      {now, 1}
    else
      {guard.window_started_at, guard.crash_count + 1}
    end
  end

  defp backoff(%{backoffs_ms: backoffs}, crash_count) do
    backoffs
    |> Enum.at(max(crash_count - 1, 0), List.last(backoffs))
    |> min(@max_backoff_ms)
  end

  defp deadline(now, milliseconds), do: DateTime.add(now, milliseconds, :millisecond)

  defp put_guard!(nil, attrs, now) do
    %AgentRestartGuard{inserted_at: now, updated_at: now}
    |> AgentRestartGuard.changeset(attrs)
    |> Repo.insert!()
  end

  defp put_guard!(%AgentRestartGuard{} = guard, attrs, now) do
    guard
    |> AgentRestartGuard.changeset(attrs)
    |> Ecto.Changeset.change(updated_at: now)
    |> Repo.update!()
  end

  defp reconcile_tripped_generation(agent_id, generation) do
    Repo.transaction(fn ->
      ProtocolCutover.require_exact_reconciliation!()
      agent = lock_agent!(agent_id)
      coordination = Scope.authorize_reconciliation!(agent)
      _binding = lock_binding(agent)
      guard = lock_guard(agent_id)
      lease = lock_lease(agent_id)
      _operation = lock_operation(agent_id)

      cond do
        not match?(%AgentRestartGuard{}, guard) ->
          0

        guard.generation != generation or not guard.tripped or not guard.needs_recovery ->
          0

        not is_nil(lease) ->
          0

        is_nil(guard.last_owner_token) ->
          0

        true ->
          {count, _rows} =
            cancel_pending_for_tripped_agent!(
              agent_id,
              DatabaseClock.now!(),
              coordination
            )

          count
      end
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_pending_for_tripped_agent!(agent_id, now, coordination) do
    query =
      from(effect in Effect,
        where: effect.agent_id == ^agent_id,
        where: not is_nil(effect.runtime_owner_generation),
        where: effect.status == "pending",
        where: is_nil(effect.claimed_by),
        where: is_nil(effect.claimed_at),
        where: is_nil(effect.claim_token),
        where: is_nil(effect.claim_owner_node),
        where: is_nil(effect.claim_heartbeat_at),
        where: is_nil(effect.claim_expires_at),
        where: is_nil(effect.claim_supervisor_id),
        where: is_nil(effect.claim_task_id)
      )
      |> Scope.scope_reconciliation_mutation(coordination)

    Repo.update_all(
      query,
      set: [
        status: "cancelled",
        cancellation_state: "settled",
        cancellation_reason: "agent_crash_loop_tripped",
        cancellation_requested_at: now,
        cancellation_target_claim_token: nil,
        cancellation_last_attempt_at: nil,
        cancellation_last_error: nil,
        cancellation_settled_at: now,
        claimed_by: nil,
        claimed_at: nil,
        retry_after: nil,
        result: nil,
        result_envelope: nil,
        error: "agent_crash_loop_tripped",
        updated_at: now
      ]
    )
  end

  defp ensure_no_processing_directive!(agent_id) do
    case Repo.one(
           from(directive in AgentDirective,
             where: directive.agent_id == ^agent_id,
             where: directive.status == "processing",
             lock: "FOR UPDATE"
           )
         ) do
      nil -> :ok
      _processing -> Repo.rollback(:runtime_work_requires_reconciliation)
    end
  end

  defp lock_agent!(agent_id) do
    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE")) do
      %Agent{} = agent -> agent
      nil -> Repo.rollback(:agent_not_found)
    end
  end

  defp lock_binding(%Agent{id: agent_id, user_id: user_id}) when is_binary(user_id) do
    Repo.one(
      from(binding in Binding,
        where: binding.agent_id == ^agent_id,
        where: binding.user_id == ^user_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_binding(_agent), do: nil

  defp lock_guard(agent_id) do
    Repo.one(
      from(guard in AgentRestartGuard,
        where: guard.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_lease(agent_id) do
    Repo.one(
      from(lease in AgentRuntimeLease,
        where: lease.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_operation(agent_id) do
    Repo.one(
      from(operation in AgentLifecycleOperation,
        where: operation.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp policy(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:window_ms, :max_crashes, :backoffs_ms])) do
      window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
      max_crashes = Keyword.get(opts, :max_crashes, @default_max_crashes)
      backoffs_ms = Keyword.get(opts, :backoffs_ms, @default_backoffs_ms)

      if is_integer(window_ms) and window_ms in 1_000..@max_window_ms and
           is_integer(max_crashes) and max_crashes in 1..@max_crashes and
           is_list(backoffs_ms) and backoffs_ms != [] and
           Enum.all?(backoffs_ms, &(is_integer(&1) and &1 in 0..@max_backoff_ms)) do
        {:ok, %{window_ms: window_ms, max_crashes: max_crashes, backoffs_ms: backoffs_ms}}
      else
        {:error, :invalid_restart_guard}
      end
    else
      {:error, :invalid_restart_guard}
    end
  end

  defp safe_reason(reason) do
    reason
    |> Maraithon.Redaction.error_class()
    |> case do
      value when is_binary(value) and byte_size(value) in 1..255 ->
        if String.valid?(value) and not Regex.match?(~r/[\x00-\x1F\x7F]/u, value),
          do: value,
          else: "runtime_crash"

      _other ->
        "runtime_crash"
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_restart_guard}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_restart_guard}

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
