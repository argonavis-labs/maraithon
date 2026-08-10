defmodule Maraithon.Runtime.AgentLeases do
  @moduledoc """
  Exact PostgreSQL-clock ownership and readiness fences for runtime Agents.

  Registry, PID, node name, and `agents.status` are never ownership proof. The
  immutable UUID token plus a live database lease is lifecycle authority;
  workload authority additionally requires readiness, current desired-state,
  Binding consent, an open exact-runtime gate, and no lifecycle marker.
  """

  import Ecto.Query

  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents.Agent
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.Config, as: RuntimeConfig

  @default_ttl_ms 60_000
  @min_ttl_ms 1_000
  @max_ttl_ms 300_000
  @runnable_statuses ~w(running degraded)

  def claim(agent_id, opts \\ [])

  def claim(agent_id, opts) when is_list(opts) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_node} <- owner_node(opts),
         {:ok, ttl_ms} <- ttl_ms(opts, [:ttl_ms, :owner_node]) do
      owner_token = Ecto.UUID.generate()

      Repo.transaction(fn ->
        agent = lock_agent!(agent_id)
        binding = lock_active_binding!(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        {now, lease_until} = DatabaseClock.window!(ttl_ms)

        ensure_no_lifecycle_operation!(operation)
        ensure_runnable!(agent)
        ensure_binding_matches!(agent, binding)
        ensure_initial_guard_allows_claim!(guard, now)
        ensure_no_existing_lease!(lease, now)
        ensure_no_processing_directive!(agent_id, :runtime_work_requires_reconciliation)

        insert_lease!(agent_id, owner_token, owner_node, now, lease_until)
      end)
    end
  end

  def claim(_agent_id, _opts), do: {:error, :invalid_runtime_lease}

  def claim_recovery(agent_id, guard_generation, opts \\ [])

  def claim_recovery(agent_id, guard_generation, opts) when is_list(opts) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, guard_generation} <- cast_uuid(guard_generation),
         {:ok, owner_node} <- owner_node(opts),
         {:ok, ttl_ms} <- ttl_ms(opts, [:ttl_ms, :owner_node]) do
      owner_token = Ecto.UUID.generate()

      Repo.transaction(fn ->
        agent = lock_agent!(agent_id)
        binding = lock_active_binding!(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        {now, lease_until} = DatabaseClock.window!(ttl_ms)

        ensure_no_lifecycle_operation!(operation)
        ensure_runnable!(agent)
        ensure_binding_matches!(agent, binding)
        ensure_due_recovery_guard!(guard, guard_generation, now)
        ensure_no_existing_lease!(lease, now)
        ensure_no_processing_directive!(agent_id, :runtime_work_requires_reconciliation)

        insert_lease!(agent_id, owner_token, owner_node, now, lease_until)
      end)
    end
  end

  def claim_recovery(_agent_id, _guard_generation, _opts),
    do: {:error, :invalid_runtime_lease}

  def renew(agent_id, owner_token, opts \\ [])

  def renew(agent_id, owner_token, opts) when is_list(opts) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token),
         {:ok, ttl_ms} <- ttl_ms(opts, [:ttl_ms]) do
      Repo.transaction(fn ->
        agent = lock_agent!(agent_id)
        binding = lock_binding(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        {now, lease_until} = DatabaseClock.window!(ttl_ms)

        ensure_exact_live_lease!(lease, owner_token, now)

        runnable? =
          is_nil(operation) and runnable?(agent) and binding_matches?(agent, binding) and
            guard_allows_ready?(guard, now)

        updates =
          if runnable? do
            %{renewed_at: now, lease_until: lease_until, updated_at: now}
          else
            %{
              renewed_at: now,
              lease_until: lease_until,
              ready_at: nil,
              draining_at: lease.draining_at || now,
              updated_at: now
            }
          end

        update_lease!(lease, updates)
      end)
    end
  end

  def renew(_agent_id, _owner_token, _opts), do: {:error, :invalid_runtime_lease}

  @doc """
  Renews an unready recovery incarnation without publishing readiness or
  converting the lease to draining while its exact guard generation remains
  due. Recovery readiness is still published only by `finish_recovery/3`.
  """
  def renew_recovery(agent_id, owner_token, guard_generation, opts \\ [])

  def renew_recovery(agent_id, owner_token, guard_generation, opts) when is_list(opts) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token),
         {:ok, guard_generation} <- cast_uuid(guard_generation),
         {:ok, ttl_ms} <- ttl_ms(opts, [:ttl_ms]) do
      Repo.transaction(fn ->
        agent = lock_agent!(agent_id)
        binding = lock_active_binding!(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        {now, lease_until} = DatabaseClock.window!(ttl_ms)

        ensure_no_lifecycle_operation!(operation)
        ensure_runnable!(agent)
        ensure_binding_matches!(agent, binding)
        ensure_due_recovery_guard!(guard, guard_generation, now)
        ensure_exact_live_lease!(lease, owner_token, now)

        update_lease!(lease, %{
          renewed_at: now,
          lease_until: lease_until,
          updated_at: now
        })
      end)
    end
  end

  def renew_recovery(_agent_id, _owner_token, _guard_generation, _opts),
    do: {:error, :invalid_runtime_lease}

  def mark_ready(agent_id, owner_token) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      Repo.transaction(fn ->
        agent = lock_agent!(agent_id)
        binding = lock_active_binding!(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        now = DatabaseClock.now!()

        ensure_no_lifecycle_operation!(operation)
        ensure_runnable!(agent)
        ensure_binding_matches!(agent, binding)
        ensure_initial_guard_allows_claim!(guard, now)
        ensure_exact_live_lease!(lease, owner_token, now)

        # Readiness is deliberately the last authority write in this transaction.
        update_lease!(lease, %{ready_at: now, draining_at: nil, updated_at: now})
      end)
    end
  end

  def finish_recovery(agent_id, owner_token, guard_generation) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token),
         {:ok, guard_generation} <- cast_uuid(guard_generation) do
      Repo.transaction(fn ->
        agent = lock_agent!(agent_id)
        binding = lock_active_binding!(agent)
        guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        now = DatabaseClock.now!()

        ensure_no_lifecycle_operation!(operation)
        ensure_runnable!(agent)
        ensure_binding_matches!(agent, binding)
        ensure_due_recovery_guard!(guard, guard_generation, now)
        ensure_exact_live_lease!(lease, owner_token, now)

        guard
        |> Ecto.Changeset.change(%{
          needs_recovery: false,
          blocked_until: nil,
          updated_at: now
        })
        |> Repo.update!()

        # The lease becomes ready only after every recovery fact is committed.
        update_lease!(lease, %{ready_at: now, draining_at: nil, updated_at: now})
      end)
    end
  end

  @doc """
  Atomically revoke workload readiness and persist stopped desired state.

  The returned lease token is routing metadata for the exact incarnation that
  was fenced. Callers must finish this transaction before signalling a local or
  remote process; no process/RPC wait belongs inside the database lock scope.
  """
  def fence_for_stop(agent_id, opts \\ [])

  def fence_for_stop(agent_id, opts) when is_list(opts) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, ttl_ms} <- ttl_ms(opts, [:ttl_ms]) do
      Repo.transaction(fn ->
        agent = lock_agent!(agent_id)
        _binding = lock_binding(agent)
        _guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        operation = lock_operation(agent_id)
        {now, drain_until} = DatabaseClock.window!(ttl_ms)
        ensure_no_lifecycle_operation!(operation)

        {lease_state, fenced_lease} =
          cond do
            is_nil(lease) ->
              {:none, nil}

            DateTime.compare(lease.lease_until, now) == :gt ->
              fenced =
                update_lease!(lease, %{
                  ready_at: nil,
                  draining_at: lease.draining_at || now,
                  lease_until: later_datetime(lease.lease_until, drain_until),
                  updated_at: now
                })

              {:live, fenced}

            true ->
              # Expiry is generation loss, never permission to resurrect that
              # incarnation for cleanup. Abort before changing desired state so
              # the caller can durably record the exact loss generation first.
              Repo.rollback(
                {:expired_lease_requires_reconciliation,
                 %{owner_token: lease.owner_token, owner_node: lease.owner_node}}
              )
          end

        stopped_agent =
          if agent.status == "stopped" and not is_nil(agent.stopped_at) do
            agent
          else
            agent
            |> Ecto.Changeset.change(%{
              status: "stopped",
              stopped_at: now,
              updated_at: now
            })
            |> Repo.update!()
          end

        %{agent: stopped_agent, lease: fenced_lease, lease_state: lease_state}
      end)
    end
  end

  def fence_for_stop(_agent_id, _opts), do: {:error, :invalid_runtime_lease}

  def begin_draining(agent_id, owner_token) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      Repo.transaction(fn ->
        agent = lock_agent!(agent_id)
        _binding = lock_binding(agent)
        _guard = lock_guard(agent_id)
        lease = lock_lease(agent_id)
        _operation = lock_operation(agent_id)
        now = DatabaseClock.now!()

        ensure_exact_live_lease!(lease, owner_token, now)

        update_lease!(lease, %{
          ready_at: nil,
          draining_at: lease.draining_at || now,
          updated_at: now
        })
      end)
    end
  end

  def release(agent_id, owner_token) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      Repo.transaction(fn ->
        agent = lock_agent!(agent_id)
        _binding = lock_binding(agent)
        _guard = lock_guard(agent_id)

        lease = lock_lease(agent_id)
        _operation = lock_operation(agent_id)
        now = DatabaseClock.now!()
        ensure_exact_live_lease!(lease, owner_token, now)
        ensure_no_processing_directive!(agent_id, :runtime_work_in_progress)
        Repo.delete!(lease)
        :released
      end)
    end
  end

  def owner?(agent_id, owner_token) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      Repo.exists?(
        from(lease in AgentRuntimeLease,
          where: lease.agent_id == ^agent_id,
          where: lease.owner_token == ^owner_token,
          where: lease.lease_until > fragment("timezone('UTC', clock_timestamp())")
        )
      )
    else
      _invalid -> false
    end
  end

  def ready?(agent_id, owner_token) do
    with :ok <- exact_runtime_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      Repo.exists?(ready_query(agent_id, owner_token))
    else
      _invalid_or_disabled -> false
    end
  end

  def fence_owner!(agent_id, owner_token) do
    require_transaction!()
    ensure_exact_runtime_enabled!()

    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      agent = lock_agent!(agent_id)
      _binding = lock_binding(agent)
      _guard = lock_guard(agent_id)
      lease = lock_lease(agent_id)
      _operation = lock_operation(agent_id)
      now = DatabaseClock.now!()

      ensure_exact_live_lease!(lease, owner_token, now)
      :ok
    else
      _invalid -> Repo.rollback(:runtime_lease_lost)
    end
  end

  def fence_ready!(agent_id, owner_token) do
    require_transaction!()
    ensure_exact_runtime_enabled!()

    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, owner_token} <- cast_uuid(owner_token) do
      agent = lock_agent!(agent_id)
      binding = lock_active_binding!(agent)
      guard = lock_guard(agent_id)
      lease = lock_lease(agent_id)
      operation = lock_operation(agent_id)
      now = DatabaseClock.now!()

      ensure_no_lifecycle_operation!(operation)
      ensure_runnable!(agent)
      ensure_binding_matches!(agent, binding)
      ensure_initial_guard_allows_claim!(guard, now)
      ensure_exact_ready_lease!(lease, owner_token, now)
      :ok
    else
      _invalid -> Repo.rollback(:runtime_not_ready)
    end
  end

  def get(agent_id) do
    case cast_uuid(agent_id) do
      {:ok, agent_id} -> Repo.get(AgentRuntimeLease, agent_id)
      {:error, :invalid_runtime_lease} -> nil
    end
  end

  defp ready_query(agent_id, owner_token) do
    from(lease in AgentRuntimeLease,
      join: agent in Agent,
      on: agent.id == lease.agent_id,
      join: binding in Binding,
      on: binding.agent_id == agent.id and binding.user_id == agent.user_id,
      left_join: guard in AgentRestartGuard,
      on: guard.agent_id == agent.id,
      left_join: operation in AgentLifecycleOperation,
      on: operation.agent_id == agent.id,
      where: lease.agent_id == ^agent_id,
      where: lease.owner_token == ^owner_token,
      where: lease.lease_until > fragment("timezone('UTC', clock_timestamp())"),
      where: not is_nil(lease.ready_at),
      where: is_nil(lease.draining_at),
      where: agent.install_status == "enabled",
      where: agent.status in ^@runnable_statuses,
      where: not is_nil(agent.user_id),
      where: binding.status == "active",
      where: is_nil(operation.agent_id),
      where:
        is_nil(guard.agent_id) or
          (guard.tripped == false and guard.needs_recovery == false and
             (is_nil(guard.blocked_until) or
                guard.blocked_until <= fragment("timezone('UTC', clock_timestamp())")))
    )
  end

  defp insert_lease!(agent_id, owner_token, owner_node, now, lease_until) do
    %AgentRuntimeLease{inserted_at: now, updated_at: now}
    |> AgentRuntimeLease.changeset(%{
      agent_id: agent_id,
      owner_token: owner_token,
      owner_node: owner_node,
      claimed_at: now,
      renewed_at: now,
      lease_until: lease_until,
      ready_at: nil,
      draining_at: nil
    })
    |> Repo.insert!()
  end

  defp update_lease!(lease, updates) do
    lease
    |> Ecto.Changeset.change(updates)
    |> Repo.update!()
  end

  defp lock_agent!(agent_id) do
    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE")) do
      %Agent{} = agent -> agent
      nil -> Repo.rollback(:agent_not_found)
    end
  end

  defp lock_active_binding!(%Agent{} = agent) do
    case lock_binding(agent) do
      %Binding{status: "active"} = binding -> binding
      _missing_or_inactive -> Repo.rollback(:agent_binding_not_active)
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

  defp ensure_no_lifecycle_operation!(nil), do: :ok
  defp ensure_no_lifecycle_operation!(_operation), do: Repo.rollback(:agent_drain_pending)

  defp ensure_exact_runtime_enabled! do
    case exact_runtime_enabled() do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp exact_runtime_enabled do
    if RuntimeConfig.exact_agent_runtime_enabled?(),
      do: :ok,
      else: {:error, :exact_runtime_disabled}
  end

  defp ensure_runnable!(agent) do
    unless runnable?(agent), do: Repo.rollback(:agent_not_runnable)
  end

  defp runnable?(%Agent{user_id: user_id, install_status: "enabled", status: status})
       when is_binary(user_id) and status in @runnable_statuses,
       do: true

  defp runnable?(_agent), do: false

  defp ensure_binding_matches!(agent, binding) do
    unless binding_matches?(agent, binding), do: Repo.rollback(:agent_binding_not_active)
  end

  defp binding_matches?(
         %Agent{id: agent_id, user_id: user_id},
         %Binding{agent_id: agent_id, user_id: user_id, status: "active"}
       )
       when is_binary(user_id),
       do: true

  defp binding_matches?(_agent, _binding), do: false

  defp ensure_initial_guard_allows_claim!(nil, _now), do: :ok

  defp ensure_initial_guard_allows_claim!(%AgentRestartGuard{} = guard, now) do
    cond do
      guard.tripped -> Repo.rollback(:agent_restart_tripped)
      guard.needs_recovery -> Repo.rollback(:agent_recovery_required)
      blocked?(guard, now) -> Repo.rollback(:agent_restart_backoff)
      true -> :ok
    end
  end

  defp ensure_due_recovery_guard!(
         %AgentRestartGuard{
           generation: generation,
           needs_recovery: true,
           tripped: false
         } = guard,
         generation,
         now
       ) do
    if blocked?(guard, now), do: Repo.rollback(:agent_restart_backoff), else: :ok
  end

  defp ensure_due_recovery_guard!(%AgentRestartGuard{tripped: true}, _generation, _now),
    do: Repo.rollback(:agent_restart_tripped)

  defp ensure_due_recovery_guard!(_guard, _generation, _now),
    do: Repo.rollback(:stale_recovery_generation)

  defp ensure_no_existing_lease!(nil, _now), do: :ok

  defp ensure_no_existing_lease!(%AgentRuntimeLease{} = lease, now) do
    if DateTime.compare(lease.lease_until, now) == :gt,
      do: Repo.rollback(:runtime_lease_owned),
      else: Repo.rollback(:expired_lease_requires_reconciliation)
  end

  defp ensure_exact_live_lease!(
         %AgentRuntimeLease{owner_token: owner_token} = lease,
         owner_token,
         now
       ) do
    if DateTime.compare(lease.lease_until, now) == :gt,
      do: :ok,
      else: Repo.rollback(:runtime_lease_expired)
  end

  defp ensure_exact_live_lease!(_lease, _owner_token, _now),
    do: Repo.rollback(:runtime_lease_lost)

  defp ensure_exact_ready_lease!(lease, owner_token, now) do
    ensure_exact_live_lease!(lease, owner_token, now)

    if is_nil(lease.ready_at) or not is_nil(lease.draining_at),
      do: Repo.rollback(:runtime_not_ready),
      else: :ok
  end

  defp guard_allows_ready?(nil, _now), do: true

  defp guard_allows_ready?(%AgentRestartGuard{} = guard, now) do
    not guard.tripped and not guard.needs_recovery and not blocked?(guard, now)
  end

  defp blocked?(%AgentRestartGuard{blocked_until: nil}, _now), do: false

  defp blocked?(%AgentRestartGuard{blocked_until: blocked_until}, now),
    do: DateTime.compare(blocked_until, now) == :gt

  defp later_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp ensure_no_processing_directive!(agent_id, reason) do
    case Repo.one(
           from(directive in AgentDirective,
             where: directive.agent_id == ^agent_id,
             where: directive.status == "processing",
             lock: "FOR UPDATE"
           )
         ) do
      nil -> :ok
      _processing -> Repo.rollback(reason)
    end
  end

  defp owner_node(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:owner_node, :ttl_ms])) do
      current_owner = Atom.to_string(node())
      owner_node = Keyword.get(opts, :owner_node, current_owner)

      if owner_node == current_owner and byte_size(owner_node) in 1..255 and
           String.valid?(owner_node) and
           not Regex.match?(~r/[\s\x00-\x1F\x7F]/u, owner_node),
         do: {:ok, owner_node},
         else: {:error, :invalid_runtime_lease}
    else
      {:error, :invalid_runtime_lease}
    end
  end

  defp ttl_ms(opts, allowed_keys) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed_keys)) do
      ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

      if is_integer(ttl_ms) and ttl_ms in @min_ttl_ms..@max_ttl_ms,
        do: {:ok, ttl_ms},
        else: {:error, :invalid_runtime_lease}
    else
      {:error, :invalid_runtime_lease}
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_runtime_lease}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_runtime_lease}

  defp require_transaction! do
    unless Repo.in_transaction?() do
      raise ArgumentError, "runtime lease fences require the caller's database transaction"
    end
  end
end
