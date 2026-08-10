defmodule Maraithon.Effects.Cancellation do
  @moduledoc """
  Partition-safe two-phase cancellation for exact durable Effect claims.

  Phase one is database-only and may compose into an AgentIsolation transaction.
  It persists cancellation intent while retaining the immutable Effect claim
  token and physical task identity. Phase two runs only after commit: it routes
  to the persisted owner, obtains coupled Task.Supervisor proof, and settles the
  exact claim as `failed/effect_outcome_ambiguous`. Unreachable, partitioned,
  legacy, or otherwise unproved work remains durably `cancelling` until exact
  supervisor proof or a task-bound operator attestation exists.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.Effects.CancellationPlan
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Effects.TerminalEnvelope
  alias Maraithon.Effects.TerminationAttestations
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.EffectTaskSupervisor
  alias Maraithon.Runtime.Coordination.{TaskAssignment, TaskClaims}

  @default_plan_limit 32
  @max_plan_limit 100
  @max_runtime_nodes 32
  @rpc_timeout_ms 5_000
  @ambiguous_outcome :effect_outcome_ambiguous

  @doc "True while the persisted epoch permits exact cancellation/reconciliation."
  def enabled?, do: ProtocolCutover.exact_reconciliation_enabled?()

  @doc false
  def exact_writes_enabled?, do: ProtocolCutover.exact_writes_enabled?()

  @doc false
  def protocol_mode, do: ProtocolCutover.mode()

  @doc "Verify the reviewed fleet epoch, exact schema, and every active Effect shape."
  def activation_preconditions, do: ProtocolCutover.activation_preconditions()

  @doc false
  def fence_effect_admission!(agent_id, runtime_owner_generation) do
    require_transaction!()

    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, runtime_owner_generation} <- cast_uuid(runtime_owner_generation) do
      ProtocolCutover.require_exact_write!()
      AgentLeases.fence_ready!(agent_id, runtime_owner_generation)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc false
  def request_coordination_drain_in_transaction!(
        node_incarnation_id,
        partition_id,
        partition_epoch,
        reason
      )
      when is_binary(node_incarnation_id) and is_integer(partition_id) and
             is_integer(partition_epoch) and is_binary(reason) do
    require_transaction!()
    ProtocolCutover.require_exact_reconciliation!()
    now = DatabaseClock.now!()

    effects =
      Repo.all(
        from effect in Effect,
          where: effect.coordination_node_incarnation_id == ^node_incarnation_id,
          where: effect.coordination_partition_id == ^partition_id,
          where: effect.coordination_partition_epoch == ^partition_epoch,
          where: effect.status in ["claimed", "executing", "cancelling"],
          order_by: [asc: effect.id],
          lock: "FOR UPDATE"
      )

    Enum.each(effects, fn effect ->
      request_coordination_termination!(effect)

      if effect.status != "cancelling" do
        effect
        |> Ecto.Changeset.change(%{
          status: "cancelling",
          cancellation_state: "requested",
          cancellation_reason: reason,
          cancellation_requested_at: now,
          cancellation_target_claim_token: effect.claim_token,
          cancellation_last_attempt_at: nil,
          cancellation_last_error: nil,
          cancellation_settled_at: nil,
          retry_after: nil,
          error: reason,
          updated_at: now
        })
        |> Repo.update!()
      end
    end)

    length(effects)
  end

  @doc false
  def record_local_coordination_termination(
        %TaskAssignment{work_kind: "effect"} = assignment,
        evidence_id
      )
      when is_binary(evidence_id) and byte_size(evidence_id) in 1..256 do
    Repo.transaction(fn ->
      ProtocolCutover.require_exact_reconciliation!()

      effect =
        case Repo.one(
               from effect in Effect,
                 where: effect.id == ^assignment.work_id,
                 where: effect.status == "cancelling",
                 where: effect.cancellation_state == "requested",
                 lock: "FOR UPDATE"
             ) do
          %Effect{} = value -> value
          nil -> Repo.rollback(:effect_claim_lost)
        end

      case coordination_assignment(effect) do
        {:ok, expected} ->
          unless exact_coordination_assignment?(assignment, expected),
            do: Repo.rollback(:coordination_task_authority_lost)

          actual = exact_coordination_assignment!(expected)

          actual =
            if actual.state in ["reserved", "running"],
              do: TaskClaims.request_effect_termination_in_transaction!(actual),
              else: actual

          case actual.state do
            "termination_requested" ->
              case TaskClaims.record_local_termination(
                     actual,
                     "supervisor_down",
                     evidence_id
                   ) do
                {:ok, %TaskAssignment{state: "termination_proven"} = proven} -> proven
                _lost -> Repo.rollback(:coordination_task_termination_proof_lost)
              end

            "termination_proven" ->
              actual

            _terminal_or_mismatched ->
              Repo.rollback(:coordination_task_authority_lost)
          end

        _uncoordinated_or_mismatched ->
          Repo.rollback(:coordination_task_authority_lost)
      end
    end)
  end

  def record_local_coordination_termination(_assignment, _evidence_id),
    do: {:error, :invalid_effect_claim}

  @doc "Persist cancellation intent and execute the first exact post-commit page."
  def request(agent_id, reason, opts \\ []) do
    with {:ok, plan} <- prepare(agent_id, reason, opts) do
      execute(plan)
    end
  end

  @doc "Persist cancellation intent without process, RPC, or network calls."
  def prepare(agent_id, reason, opts \\ []) do
    with :ok <- require_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, reason} <- cancellation_reason(reason),
         {:ok, parsed_opts} <- prepare_agent_opts(opts) do
      Repo.transaction(fn ->
        prepare_in_transaction!(agent_id, reason, parsed_opts)
      end)
    end
  end

  @doc false
  def prepare_lifecycle(agent_id, operation_token, reason, opts \\ [])

  def prepare_lifecycle(agent_id, operation_token, reason, opts) when is_list(opts) do
    with :ok <- require_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, operation_token} <- cast_uuid(operation_token),
         {:ok, reason} <- cancellation_reason(reason),
         true <- Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 == :limit)),
         {:ok, limit} <- plan_limit(Keyword.get(opts, :limit, @default_plan_limit)) do
      Repo.transaction(fn ->
        ProtocolCutover.require_exact_reconciliation!()
        _effects = lock_effects_for_cancellation!(agent_id)
        agent = lock_agent!(agent_id)
        _binding = lock_optional_same_user_binding!(agent)
        lease = lock_runtime_rows!(agent_id)
        ensure_lifecycle_authority!(agent, operation_token, lease)
        now = DatabaseClock.now!()

        pending_cancelled = cancel_pending!(agent_id, reason, now)
        requested = request_active_cancellation!(agent_id, reason, now)
        {claims, more?} = requested_claim_page(agent_id, limit)

        %CancellationPlan{
          agent_id: agent.id,
          user_id: agent.user_id,
          reason: reason,
          claims: claims,
          pending_cancelled: pending_cancelled,
          requested: pending_cancelled + requested,
          more?: more?,
          lifecycle_operation_token: operation_token
        }
      end)
    else
      _invalid -> {:error, :invalid_effect_cancellation}
    end
  end

  def prepare_lifecycle(_agent_id, _operation_token, _reason, _opts),
    do: {:error, :invalid_effect_cancellation}

  @doc """
  Compose phase one into a caller-owned transaction.

  AgentIsolation must retain the returned plan and call `execute/1` only after
  the outer transaction commits. This function deliberately does not redesign
  or mutate Binding authority itself.
  """
  def prepare_in_transaction!(agent_id, reason, opts \\ []) do
    require_transaction!()

    with :ok <- require_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, reason} <- cancellation_reason(reason),
         {:ok, parsed_opts} <- normalize_agent_prepared_opts(opts) do
      ProtocolCutover.require_exact_reconciliation!()
      _effects = lock_effects_for_cancellation!(agent_id)
      agent = lock_agent!(agent_id)
      binding = lock_same_user_binding!(agent)
      ensure_expected_user!(binding, parsed_opts.user_id)
      lease = lock_runtime_rows!(agent_id)
      ensure_expected_runtime_owner!(lease, parsed_opts.expected_runtime_owner_generation)
      now = DatabaseClock.now!()

      pending_cancelled = cancel_pending!(agent_id, reason, now)
      requested = request_active_cancellation!(agent_id, reason, now)
      {claims, more?} = requested_claim_page(agent_id, parsed_opts.limit)

      %CancellationPlan{
        agent_id: agent.id,
        user_id: binding.user_id,
        reason: reason,
        claims: claims,
        pending_cancelled: pending_cancelled,
        requested: pending_cancelled + requested,
        more?: more?
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc false
  def prepare_exact_claims(agent_id, effects, reason, opts \\ [])

  def prepare_exact_claims(agent_id, effects, reason, opts) when is_list(effects) do
    with :ok <- require_enabled(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, reason} <- cancellation_reason(reason),
         {:ok, references} <- exact_references(effects),
         true <- length(references) <= @max_plan_limit,
         {:ok, parsed_opts} <- prepare_opts(opts) do
      Repo.transaction(fn ->
        ProtocolCutover.require_exact_reconciliation!()
        _effects = lock_referenced_effects!(agent_id, references)
        agent = lock_agent!(agent_id)
        binding = lock_same_user_binding!(agent)
        ensure_expected_user!(binding, parsed_opts.user_id)
        lock_runtime_rows!(agent_id)
        now = DatabaseClock.now!()

        claims =
          references
          |> Enum.map(&request_exact_claim!(agent_id, &1, reason, now))
          |> Enum.reject(&is_nil/1)

        %CancellationPlan{
          agent_id: agent.id,
          user_id: binding.user_id,
          reason: reason,
          claims: claims,
          pending_cancelled: 0,
          requested: length(claims),
          more?: false
        }
      end)
    else
      false -> {:error, :invalid_effect_cancellation}
      {:error, _reason} = error -> error
    end
  end

  def prepare_exact_claims(_agent_id, _effects, _reason, _opts),
    do: {:error, :invalid_effect_cancellation}

  @doc "Execute only exact claims from an already-committed plan."
  def execute(%CancellationPlan{} = plan) do
    if Repo.in_transaction?() do
      {:error, :effect_cancellation_requires_post_commit}
    else
      {settled, duplicates, unresolved} =
        case authorize_plan_execution(plan) do
          :ok -> execute_claims(plan)
          {:error, reason} -> {0, 0, [{nil, reason}]}
        end

      unresolved =
        case unresolved_protocol_count(plan.agent_id) do
          0 -> unresolved
          count -> [{nil, {:effect_protocol_mismatch, count}} | unresolved]
        end

      summary = %{
        agent_id: plan.agent_id,
        requested: plan.requested,
        pending_cancelled: plan.pending_cancelled,
        claims_settled: settled,
        duplicate_settlements: duplicates,
        unresolved: Enum.reverse(unresolved),
        more?: plan.more?
      }

      if unresolved == [] and not plan.more?, do: {:ok, summary}, else: {:pending, summary}
    end
  end

  def execute(_plan), do: {:error, :invalid_effect_cancellation_plan}

  @doc "Retry a bounded durable page for one Agent after the staging commit."
  def reconcile_agent(agent_id, limit \\ @default_plan_limit) do
    with :ok <- require_enabled(),
         false <- Repo.in_transaction?(),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, limit} <- plan_limit(limit),
         {:ok, plan} <- load_agent_plan(agent_id, limit) do
      execute(plan)
    else
      true -> {:error, :effect_cancellation_requires_post_commit}
      {:error, _reason} = error -> error
    end
  end

  @doc "Retry a bounded global page of committed exact cancellations."
  def reconcile(limit \\ @default_plan_limit) do
    with :ok <- require_enabled(),
         false <- Repo.in_transaction?(),
         {:ok, limit} <- plan_limit(limit) do
      # Surprise rows and exact cancellations use independent bounded pages so
      # a permanent malformed/legacy row cannot starve physical exact claims.
      surprises = protocol_mismatch_candidates(limit)

      exact_results =
        cancellation_candidates(limit)
        |> Enum.map(fn {agent_id, effect_id, claim_token} ->
          case load_committed_plan(agent_id, effect_id, claim_token) do
            {:ok, plan} -> {effect_id, execute(plan)}
            {:error, reason} -> {effect_id, {:error, reason}}
          end
        end)

      Enum.map(surprises, fn effect_id ->
        {effect_id, {:error, {:effect_protocol_mismatch, :surprise_active_shape}}}
      end) ++ exact_results
    else
      _disabled_or_invalid -> []
    end
  end

  @doc "Fence a bounded page of expired exact claims without taking them over."
  def fence_expired_claims(limit \\ @max_plan_limit)

  def fence_expired_claims(limit) when is_integer(limit) and limit in 1..@max_plan_limit do
    if enabled?() do
      expired_claim_candidates(limit)
      |> Enum.flat_map(fn {agent_id, effect_id, claim_token} ->
        case prepare_expired_claim(agent_id, effect_id, claim_token) do
          {:ok, %CancellationPlan{} = plan} -> [plan]
          _lost_or_failed -> []
        end
      end)
    else
      []
    end
  end

  def fence_expired_claims(_limit), do: []

  @doc false
  def terminate_exact_on_owner(claim) when is_map(claim) do
    with {:ok, claim} <- validate_claim(claim),
         true <- claim.owner_node == Atom.to_string(node()),
         {:ok, persisted} <- load_persisted_claim(claim) do
      case EffectTaskSupervisor.terminate_exact(persisted) do
        {:ok, proof} -> {:ok, proof}
        {:unknown, reason} -> {:unknown, reason}
        _unexpected -> {:unknown, :effect_task_termination_unproven}
      end
    else
      false -> {:unknown, :effect_claim_wrong_physical_owner}
      {:duplicate, _persisted} -> {:unknown, :effect_cancellation_already_settled}
      {:error, reason} -> {:unknown, reason}
    end
  end

  def terminate_exact_on_owner(_claim), do: {:unknown, :invalid_effect_claim}

  defp execute_claims(%CancellationPlan{} = plan) do
    Enum.reduce(plan.claims, {0, 0, []}, fn claim, {settled, duplicates, unresolved} ->
      case route_and_terminate(claim) do
        {:ok, proof} ->
          case settle(plan, claim, proof) do
            {:ok, :settled} -> {settled + 1, duplicates, unresolved}
            {:ok, :duplicate} -> {settled, duplicates + 1, unresolved}
            {:error, reason} -> {settled, duplicates, [{claim.effect_id, reason} | unresolved]}
          end

        :duplicate ->
          {settled, duplicates + 1, unresolved}

        {:unknown, reason} ->
          persist_unknown(plan, claim, reason)
          {settled, duplicates, [{claim.effect_id, reason} | unresolved]}
      end
    end)
  end

  defp cancel_pending!(agent_id, reason, now) do
    query =
      from(effect in Effect,
        where: effect.agent_id == ^agent_id,
        where: effect.status == "pending",
        where: not is_nil(effect.runtime_owner_generation),
        where: is_nil(effect.claimed_by),
        where: is_nil(effect.claimed_at),
        where: is_nil(effect.claim_token),
        where: is_nil(effect.claim_owner_node),
        where: is_nil(effect.claim_heartbeat_at),
        where: is_nil(effect.claim_expires_at),
        where: is_nil(effect.claim_supervisor_id),
        where: is_nil(effect.claim_task_id)
      )

    {count, _rows} =
      Repo.update_all(query,
        set: [
          status: "cancelled",
          cancellation_state: "settled",
          cancellation_reason: reason,
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
          error: reason,
          updated_at: now
        ]
      )

    count
  end

  defp request_active_cancellation!(agent_id, reason, now) do
    effects =
      Repo.all(
        from effect in Effect,
          where: effect.agent_id == ^agent_id,
          where: effect.status in ["claimed", "executing"],
          where: not is_nil(effect.runtime_owner_generation),
          where: not is_nil(effect.claim_token),
          where: not is_nil(effect.claim_owner_node),
          where: not is_nil(effect.claim_heartbeat_at),
          where: not is_nil(effect.claim_expires_at),
          where: not is_nil(effect.claim_supervisor_id),
          where: not is_nil(effect.claim_task_id),
          where: is_nil(effect.cancellation_state),
          order_by: [asc: effect.id],
          lock: "FOR UPDATE"
      )

    # Lock the complete canonical Effect set before touching any assignment.
    # This gives every multi-row cancellation the same Effect -> assignment
    # order as entry, renewal, terminal settlement, and proof convergence.
    Enum.each(effects, fn effect ->
      request_coordination_termination!(effect)

      effect
      |> Ecto.Changeset.change(%{
        status: "cancelling",
        cancellation_state: "requested",
        cancellation_reason: reason,
        cancellation_requested_at: now,
        cancellation_target_claim_token: effect.claim_token,
        cancellation_last_attempt_at: nil,
        cancellation_last_error: nil,
        cancellation_settled_at: nil,
        retry_after: nil,
        error: reason,
        updated_at: now
      })
      |> Repo.update!()
    end)

    length(effects)
  end

  defp requested_claim_page(agent_id, limit) do
    rows =
      Repo.all(
        from(effect in Effect,
          where: effect.agent_id == ^agent_id,
          where: effect.status == "cancelling",
          where: effect.cancellation_state == "requested",
          where: not is_nil(effect.runtime_owner_generation),
          where: not is_nil(effect.claim_token),
          where: not is_nil(effect.claim_owner_node),
          where: not is_nil(effect.claim_supervisor_id),
          where: not is_nil(effect.claim_task_id),
          order_by: [
            asc_nulls_first: effect.cancellation_last_attempt_at,
            asc: effect.cancellation_requested_at,
            asc: effect.id
          ],
          limit: ^(limit + 1)
        )
      )

    {Enum.take(rows, limit) |> Enum.map(&claim_from_effect!/1), length(rows) > limit}
  end

  defp request_exact_claim!(agent_id, reference, reason, now) do
    effect = lock_effect!(agent_id, reference.effect_id)

    cond do
      exact_claim?(effect, reference) and effect.status in ["claimed", "executing"] ->
        request_coordination_termination!(effect)

        effect
        |> Ecto.Changeset.change(%{
          status: "cancelling",
          cancellation_state: "requested",
          cancellation_reason: reason,
          cancellation_requested_at: now,
          cancellation_target_claim_token: effect.claim_token,
          cancellation_last_attempt_at: nil,
          cancellation_last_error: nil,
          cancellation_settled_at: nil,
          retry_after: nil,
          error: reason,
          updated_at: now
        })
        |> Repo.update!()
        |> claim_from_effect!()

      exact_claim?(effect, reference) and effect.status == "cancelling" and
          effect.cancellation_state == "requested" ->
        request_coordination_termination!(effect)
        claim_from_effect!(effect)

      true ->
        nil
    end
  end

  defp prepare_expired_claim(agent_id, effect_id, claim_token) do
    Repo.transaction(fn ->
      ProtocolCutover.require_exact_reconciliation!()
      effect = lock_effect!(agent_id, effect_id)
      agent = lock_agent!(agent_id)
      _binding = lock_optional_same_user_binding!(agent)
      lock_runtime_rows!(agent_id)
      now = DatabaseClock.now!()

      cond do
        effect.status in ["claimed", "executing"] and effect.claim_token == claim_token and
          not is_nil(effect.claim_expires_at) and
            DateTime.compare(effect.claim_expires_at, now) != :gt ->
          claim =
            request_exact_claim!(
              agent_id,
              %{effect_id: effect_id, claim_token: claim_token},
              "claim_liveness_expired",
              now
            )

          %CancellationPlan{
            agent_id: agent.id,
            user_id: agent.user_id,
            reason: "claim_liveness_expired",
            claims: if(claim, do: [claim], else: []),
            pending_cancelled: 0,
            requested: if(claim, do: 1, else: 0),
            more?: false
          }

        effect.status == "cancelling" and effect.cancellation_state == "requested" and
            effect.cancellation_target_claim_token == claim_token ->
          %CancellationPlan{
            agent_id: agent.id,
            user_id: agent.user_id,
            reason: effect.cancellation_reason,
            claims: [claim_from_effect!(effect)],
            pending_cancelled: 0,
            requested: 0,
            more?: false
          }

        true ->
          Repo.rollback(:effect_claim_not_expired)
      end
    end)
  end

  defp load_agent_plan(agent_id, limit) do
    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id)) do
      %Agent{user_id: user_id} when is_binary(user_id) ->
        {claims, more?} = requested_claim_page(agent_id, limit)

        {:ok,
         %CancellationPlan{
           agent_id: agent_id,
           user_id: user_id,
           reason: "reconcile",
           claims: claims,
           pending_cancelled: 0,
           requested: 0,
           more?: more?
         }}

      _missing ->
        {:error, :agent_not_found}
    end
  end

  defp load_committed_plan(agent_id, effect_id, claim_token) do
    case Repo.one(
           from(effect in Effect,
             join: agent in Agent,
             on: agent.id == effect.agent_id,
             where: effect.agent_id == ^agent_id,
             where: effect.id == ^effect_id,
             where: effect.status == "cancelling",
             where: effect.cancellation_state == "requested",
             where: not is_nil(effect.runtime_owner_generation),
             where: not is_nil(effect.claim_owner_node),
             where: not is_nil(effect.claim_supervisor_id),
             where: not is_nil(effect.claim_task_id),
             where: effect.claim_token == ^claim_token,
             where: effect.cancellation_target_claim_token == ^claim_token,
             select: {effect, agent.user_id}
           )
         ) do
      {%Effect{} = effect, user_id} when is_binary(user_id) ->
        {:ok,
         %CancellationPlan{
           agent_id: agent_id,
           user_id: user_id,
           reason: effect.cancellation_reason,
           claims: [claim_from_effect!(effect)],
           pending_cancelled: 0,
           requested: 0,
           more?: false
         }}

      nil ->
        {:error, :effect_cancellation_claim_lost}
    end
  end

  defp route_and_terminate(claim) do
    case load_persisted_claim(claim) do
      {:ok, persisted} ->
        if TerminationAttestations.proof?(persisted) do
          {:ok, :operator_attestation}
        else
          with {:ok, owner_node} <- runtime_node(persisted.owner_node) do
            if owner_node == node() do
              terminate_exact_on_owner(persisted)
            else
              case :rpc.call(
                     owner_node,
                     __MODULE__,
                     :terminate_exact_on_owner,
                     [persisted],
                     @rpc_timeout_ms
                   ) do
                {:ok, proof} -> {:ok, proof}
                {:unknown, reason} -> {:unknown, reason}
                _failure -> {:unknown, :effect_claim_owner_unreachable}
              end
            end
          else
            {:error, reason} -> {:unknown, reason}
          end
        end

      {:duplicate, _persisted} ->
        :duplicate

      {:error, reason} ->
        {:unknown, reason}
    end
  catch
    _kind, _reason -> {:unknown, :effect_claim_owner_unreachable}
  end

  defp load_persisted_claim(claim) do
    query =
      from(effect in Effect,
        where: effect.id == ^claim.effect_id,
        where: effect.agent_id == ^claim.agent_id,
        where: effect.runtime_owner_generation == ^claim.runtime_owner_generation,
        where: effect.claim_token == ^claim.claim_token,
        where: effect.cancellation_target_claim_token == ^claim.claim_token,
        where: effect.claim_owner_node == ^claim.owner_node,
        where: effect.claim_supervisor_id == ^claim.supervisor_id,
        where: effect.claim_task_id == ^claim.task_id,
        where:
          (effect.status == "cancelling" and effect.cancellation_state == "requested") or
            (effect.status in ["failed", "cancelled"] and
               effect.cancellation_state == "settled")
      )

    case Repo.one(query) do
      %Effect{status: "cancelling", cancellation_state: "requested"} = effect ->
        {:ok, claim_from_effect!(effect)}

      %Effect{status: status, cancellation_state: "settled"} = effect
      when status in ["failed", "cancelled"] ->
        {:duplicate, claim_from_effect!(effect)}

      nil ->
        {:error, :effect_cancellation_claim_lost}
    end
  end

  defp settle(%CancellationPlan{} = plan, claim, proof)
       when proof in [
              :terminated,
              :supervisor_down,
              :never_activated,
              :operator_attestation
            ] do
    Repo.transaction(fn ->
      ProtocolCutover.require_exact_reconciliation!()
      effect = lock_effect!(claim.agent_id, claim.effect_id)
      agent = lock_agent!(claim.agent_id)
      lock_plan_authority!(plan, agent)

      cond do
        effect.status in ["failed", "cancelled"] and
          effect.cancellation_state == "settled" and
          effect.cancellation_target_claim_token == claim.claim_token and
            effect.claim_token == claim.claim_token ->
          :duplicate

        exact_cancelling_claim?(effect, claim) ->
          now = DatabaseClock.now!()

          case settle_coordination_termination!(effect, proof) do
            %TaskAssignment{
              state: "settled",
              provider_boundary: "not_entered",
              outcome: "cancelled_before_provider"
            } ->
              settle_pre_provider_cancellation!(effect, now)

            %TaskAssignment{
              state: "outcome_ambiguous",
              provider_boundary: boundary,
              outcome: "provider_outcome_ambiguous"
            }
            when boundary in ["entered", "outcome_unknown"] ->
              settle_ambiguous_cancellation!(effect, now)

            :uncoordinated ->
              settle_ambiguous_cancellation!(effect, now)

            _mismatched ->
              Repo.rollback(:coordination_task_settlement_lost)
          end

          :settled

        true ->
          Repo.rollback(:effect_cancellation_claim_lost)
      end
    end)
  end

  defp settle(_plan, _claim, _proof), do: {:error, :effect_task_termination_unproven}

  defp settle_pre_provider_cancellation!(%Effect{} = effect, now) do
    if retryable_pre_provider_abort?(effect.cancellation_reason) do
      effect
      |> Ecto.Changeset.change(%{
        status: "pending",
        claimed_by: nil,
        claimed_at: nil,
        claim_token: nil,
        claim_owner_node: nil,
        claim_heartbeat_at: nil,
        claim_expires_at: nil,
        claim_supervisor_id: nil,
        claim_task_id: nil,
        coordination_task_assignment_id: nil,
        cancellation_state: nil,
        cancellation_reason: nil,
        cancellation_requested_at: nil,
        cancellation_target_claim_token: nil,
        cancellation_last_attempt_at: nil,
        cancellation_last_error: nil,
        cancellation_settled_at: nil,
        retry_after: now,
        result: nil,
        result_envelope: nil,
        error: nil,
        updated_at: now
      })
      |> Repo.update!()
    else
      effect
      |> Ecto.Changeset.change(%{
        status: "cancelled",
        cancellation_state: "settled",
        cancellation_target_claim_token: nil,
        cancellation_last_attempt_at: now,
        cancellation_last_error: nil,
        cancellation_settled_at: now,
        result: nil,
        result_envelope: nil,
        completion_claimed_by: effect.claim_owner_node,
        completion_claimed_at: effect.claimed_at,
        claimed_by: nil,
        claimed_at: nil,
        claim_token: nil,
        claim_owner_node: nil,
        claim_heartbeat_at: nil,
        claim_expires_at: nil,
        claim_supervisor_id: nil,
        claim_task_id: nil,
        coordination_task_assignment_id: nil,
        retry_after: nil,
        updated_at: now
      })
      |> Repo.update!()
    end
  end

  defp settle_ambiguous_cancellation!(%Effect{} = effect, now) do
    effect
    |> Ecto.Changeset.change(%{
      status: "failed",
      cancellation_state: "settled",
      cancellation_last_attempt_at: now,
      cancellation_last_error: nil,
      cancellation_settled_at: now,
      result: nil,
      error: "effect_outcome_ambiguous",
      result_envelope: TerminalEnvelope.error(@ambiguous_outcome),
      result_dispatched_at: nil,
      result_dispatch_after: nil,
      result_dispatch_attempts: 0,
      result_acknowledged_at: nil,
      completion_claimed_by: effect.claim_owner_node,
      completion_claimed_at: effect.claimed_at,
      claimed_by: nil,
      claimed_at: nil,
      retry_after: nil,
      updated_at: now
    })
    |> Repo.update!()
  end

  defp retryable_pre_provider_abort?(reason),
    do:
      reason in [
        "claim_liveness_expired",
        "effect_runner_shutdown",
        "effect_task_exited_without_outcome",
        "effect_task_start_ambiguous"
      ]

  defp request_coordination_termination!(%Effect{} = effect) do
    case coordination_assignment(effect) do
      :uncoordinated ->
        :ok

      {:ok, expected} ->
        case TaskClaims.request_effect_termination_in_transaction!(expected) do
          %TaskAssignment{state: "termination_requested"} = requested ->
            unless exact_coordination_assignment?(requested, expected),
              do: Repo.rollback(:coordination_task_authority_lost)

            :ok

          _terminal_or_mismatched ->
            Repo.rollback(:coordination_task_authority_lost)
        end

      :mismatched ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  defp settle_coordination_termination!(%Effect{} = effect, proof) do
    case coordination_assignment(effect) do
      :uncoordinated ->
        :uncoordinated

      {:ok, expected} ->
        assignment = exact_coordination_assignment!(expected)

        proven_or_terminal =
          case assignment.state do
            state when state in ["reserved", "running", "termination_requested"] ->
              record_coordination_termination_proof!(assignment, proof)

            "termination_proven" ->
              assignment

            state when state in ["settled", "outcome_ambiguous"] ->
              assignment

            _invalid_state ->
              Repo.rollback(:coordination_task_authority_lost)
          end

        final =
          case proven_or_terminal.state do
            "termination_proven" ->
              TaskClaims.reconcile_effect_proven_in_transaction(
                proven_or_terminal,
                effect.agent_id,
                effect.runtime_owner_generation
              )

            _already_terminal ->
              proven_or_terminal
          end

        case final do
          %TaskAssignment{
            id: id,
            state: "settled",
            provider_boundary: "not_entered",
            outcome: "cancelled_before_provider"
          }
          when id == expected.id ->
            final

          %TaskAssignment{
            id: id,
            state: "outcome_ambiguous",
            provider_boundary: boundary,
            outcome: "provider_outcome_ambiguous"
          }
          when id == expected.id and boundary in ["entered", "outcome_unknown"] ->
            final

          _mismatched_terminal_proof ->
            Repo.rollback(:coordination_task_settlement_lost)
        end

      :mismatched ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  defp record_coordination_termination_proof!(assignment, :operator_attestation) do
    evidence_id = "effect-termination-attestation:#{assignment.claim_token}"

    case TaskClaims.record_external_termination(
           assignment,
           evidence_id,
           "Maraithon.Effects.TerminationAttestations"
         ) do
      {:ok, %TaskAssignment{} = proven} -> proven
      _lost -> Repo.rollback(:coordination_task_termination_proof_lost)
    end
  end

  defp record_coordination_termination_proof!(assignment, proof)
       when proof in [:terminated, :authority_absence, :supervisor_restarted] do
    evidence_id = "effect-task-authority:#{proof}:#{assignment.local_task_id}"

    case TaskClaims.record_local_termination(assignment, "supervisor_down", evidence_id) do
      {:ok, %TaskAssignment{} = proven} -> proven
      _lost -> Repo.rollback(:coordination_task_termination_proof_lost)
    end
  end

  defp exact_coordination_assignment?(actual, expected) do
    fields = [
      :id,
      :activation_epoch,
      :work_kind,
      :work_id,
      :claim_token,
      :partition_id,
      :partition_epoch,
      :node_incarnation_id,
      :supervisor_id,
      :local_task_id
    ]

    Map.take(actual, fields) == Map.take(expected, fields)
  end

  defp exact_coordination_assignment!(expected) do
    actual = TaskClaims.lock_effect_assignment_in_transaction!(expected)

    if exact_coordination_assignment?(actual, expected),
      do: actual,
      else: Repo.rollback(:coordination_task_authority_lost)
  end

  defp coordination_assignment(%Effect{
         id: work_id,
         claim_token: claim_token,
         claim_supervisor_id: supervisor_id,
         claim_task_id: local_task_id,
         coordination_activation_epoch: activation_epoch,
         coordination_partition_id: partition_id,
         coordination_partition_epoch: partition_epoch,
         coordination_node_incarnation_id: node_incarnation_id,
         coordination_task_assignment_id: assignment_id
       })
       when is_binary(work_id) and is_binary(claim_token) and is_binary(supervisor_id) and
              is_binary(local_task_id) and is_binary(activation_epoch) and
              is_integer(partition_id) and is_integer(partition_epoch) and
              is_binary(node_incarnation_id) and is_binary(assignment_id) do
    {:ok,
     %TaskAssignment{
       id: assignment_id,
       activation_epoch: activation_epoch,
       work_kind: "effect",
       work_id: work_id,
       claim_token: claim_token,
       partition_id: partition_id,
       partition_epoch: partition_epoch,
       node_incarnation_id: node_incarnation_id,
       supervisor_id: supervisor_id,
       local_task_id: local_task_id
     }}
  end

  defp coordination_assignment(%Effect{
         coordination_activation_epoch: nil,
         coordination_partition_id: nil,
         coordination_partition_epoch: nil,
         coordination_node_incarnation_id: nil,
         coordination_task_assignment_id: nil
       }),
       do: :uncoordinated

  defp coordination_assignment(%Effect{}), do: :mismatched

  defp persist_unknown(%CancellationPlan{} = plan, claim, reason) do
    Repo.transaction(fn ->
      ProtocolCutover.require_exact_reconciliation!()
      _effect = lock_effect!(claim.agent_id, claim.effect_id)
      agent = lock_agent!(claim.agent_id)
      lock_plan_authority!(plan, agent)
      now = DatabaseClock.now!()
      error = cancellation_error(reason)

      query =
        from(effect in Effect,
          where: effect.id == ^claim.effect_id,
          where: effect.agent_id == ^claim.agent_id,
          where: effect.status == "cancelling",
          where: effect.runtime_owner_generation == ^claim.runtime_owner_generation,
          where: effect.cancellation_state == "requested",
          where: effect.claim_token == ^claim.claim_token,
          where: effect.cancellation_target_claim_token == ^claim.claim_token,
          where: effect.claim_owner_node == ^claim.owner_node,
          where: effect.claim_supervisor_id == ^claim.supervisor_id,
          where: effect.claim_task_id == ^claim.task_id
        )

      Repo.update_all(query,
        set: [
          cancellation_last_attempt_at: now,
          cancellation_last_error: error,
          updated_at: now
        ]
      )
    end)

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp exact_cancelling_claim?(effect, claim) do
    effect.status == "cancelling" and
      effect.cancellation_state == "requested" and
      effect.claim_token == claim.claim_token and
      effect.cancellation_target_claim_token == claim.claim_token and
      effect.claim_owner_node == claim.owner_node and
      effect.claim_supervisor_id == claim.supervisor_id and
      effect.claim_task_id == claim.task_id and
      effect.runtime_owner_generation == claim.runtime_owner_generation
  end

  defp exact_claim?(effect, reference) do
    effect.claim_token == reference.claim_token and not is_nil(effect.claim_token)
  end

  defp expired_claim_candidates(limit) do
    Repo.all(
      from(effect in Effect,
        where: effect.status in ["claimed", "executing"],
        where: not is_nil(effect.runtime_owner_generation),
        where: not is_nil(effect.claim_token),
        where: not is_nil(effect.claim_owner_node),
        where: not is_nil(effect.claim_supervisor_id),
        where: not is_nil(effect.claim_task_id),
        where: effect.claim_expires_at <= fragment("timezone('UTC', clock_timestamp())"),
        order_by: [asc: effect.claim_expires_at, asc: effect.id],
        limit: ^limit,
        select: {effect.agent_id, effect.id, effect.claim_token}
      )
    )
  end

  defp protocol_mismatch_candidates(0), do: []

  defp protocol_mismatch_candidates(limit) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT id::text
        FROM public.effects
        WHERE status IN ('pending', 'claimed', 'executing', 'cancelling')
          AND NOT (
            runtime_owner_generation IS NOT NULL AND
            effect_protocol_version = 2 AND
            payload_encryption_version = 1 AND
            payload_purged_at IS NULL AND params_ciphertext IS NOT NULL AND
            params = '{"redacted": true}'::jsonb AND result IS NULL AND
            (
              (status = 'pending' AND claimed_by IS NULL AND claimed_at IS NULL AND
               claim_token IS NULL AND claim_owner_node IS NULL AND
               claim_heartbeat_at IS NULL AND claim_expires_at IS NULL AND
               claim_supervisor_id IS NULL AND claim_task_id IS NULL AND
               cancellation_state IS NULL AND cancellation_reason IS NULL AND
               cancellation_requested_at IS NULL AND cancellation_target_claim_token IS NULL AND
               cancellation_last_attempt_at IS NULL AND cancellation_last_error IS NULL AND
               cancellation_settled_at IS NULL) OR
              (status IN ('claimed', 'executing') AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL AND
               claim_token IS NOT NULL AND claim_owner_node IS NOT NULL AND
               claim_owner_node = claimed_by AND claim_heartbeat_at IS NOT NULL AND
               claim_expires_at IS NOT NULL AND claim_heartbeat_at < claim_expires_at AND
               claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL AND
               cancellation_state IS NULL AND cancellation_reason IS NULL AND
               cancellation_requested_at IS NULL AND cancellation_target_claim_token IS NULL AND
               cancellation_last_attempt_at IS NULL AND cancellation_last_error IS NULL AND
               cancellation_settled_at IS NULL) OR
              (status = 'cancelling' AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL AND
               claim_token IS NOT NULL AND claim_owner_node IS NOT NULL AND
               claim_owner_node = claimed_by AND claim_heartbeat_at IS NOT NULL AND
               claim_expires_at IS NOT NULL AND claim_heartbeat_at < claim_expires_at AND
               claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL AND
               cancellation_state = 'requested' AND cancellation_reason IS NOT NULL AND
               cancellation_requested_at IS NOT NULL AND
               cancellation_target_claim_token = claim_token AND
               cancellation_settled_at IS NULL)
            )
          )
        ORDER BY inserted_at, id
        LIMIT $1
        """,
        [limit]
      )

    Enum.map(rows, fn [effect_id] -> effect_id end)
  end

  defp cancellation_candidates(limit) do
    Repo.all(
      from(effect in Effect,
        where: effect.status == "cancelling",
        where: effect.cancellation_state == "requested",
        where: not is_nil(effect.runtime_owner_generation),
        where: not is_nil(effect.claim_token),
        where: not is_nil(effect.claim_owner_node),
        where: not is_nil(effect.claim_supervisor_id),
        where: not is_nil(effect.claim_task_id),
        where: not is_nil(effect.cancellation_target_claim_token),
        order_by: [
          asc_nulls_first: effect.cancellation_last_attempt_at,
          asc: effect.cancellation_requested_at,
          asc: effect.id
        ],
        limit: ^limit,
        select: {effect.agent_id, effect.id, effect.cancellation_target_claim_token}
      )
    )
  end

  # Counts legacy, bare/unknown cancelling, partial exact identity, and any
  # other operational surprise. It is deliberately a COUNT rather than an
  # unbounded load so reconciliation remains paged.
  defp unresolved_protocol_count(agent_id) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        """
        SELECT COUNT(*)
        FROM public.effects
        WHERE agent_id = $1::uuid
          AND status IN ('pending', 'claimed', 'executing', 'cancelling')
          AND NOT (
            runtime_owner_generation IS NOT NULL AND
            effect_protocol_version = 2 AND
            payload_encryption_version = 1 AND
            payload_purged_at IS NULL AND params_ciphertext IS NOT NULL AND
            params = '{"redacted": true}'::jsonb AND result IS NULL AND
            (
              (status = 'pending' AND claimed_by IS NULL AND claimed_at IS NULL AND
               claim_token IS NULL AND claim_owner_node IS NULL AND
               claim_heartbeat_at IS NULL AND claim_expires_at IS NULL AND
               claim_supervisor_id IS NULL AND claim_task_id IS NULL AND
               cancellation_state IS NULL AND cancellation_reason IS NULL AND
               cancellation_requested_at IS NULL AND cancellation_target_claim_token IS NULL AND
               cancellation_last_attempt_at IS NULL AND cancellation_last_error IS NULL AND
               cancellation_settled_at IS NULL) OR
              (status IN ('claimed', 'executing') AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL AND
               claim_token IS NOT NULL AND claim_owner_node IS NOT NULL AND
               claim_owner_node = claimed_by AND claim_heartbeat_at IS NOT NULL AND
               claim_expires_at IS NOT NULL AND claim_heartbeat_at < claim_expires_at AND
               claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL AND
               cancellation_state IS NULL AND cancellation_reason IS NULL AND
               cancellation_requested_at IS NULL AND cancellation_target_claim_token IS NULL AND
               cancellation_last_attempt_at IS NULL AND cancellation_last_error IS NULL AND
               cancellation_settled_at IS NULL) OR
              (status = 'cancelling' AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL AND
               claim_token IS NOT NULL AND claim_owner_node IS NOT NULL AND
               claim_owner_node = claimed_by AND claim_heartbeat_at IS NOT NULL AND
               claim_expires_at IS NOT NULL AND claim_heartbeat_at < claim_expires_at AND
               claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL AND
               cancellation_state = 'requested' AND cancellation_reason IS NOT NULL AND
               cancellation_requested_at IS NOT NULL AND
               cancellation_target_claim_token = claim_token AND
               cancellation_settled_at IS NULL)
            )
          )
        """,
        [Ecto.UUID.dump!(agent_id)]
      )

    count
  end

  defp lock_agent!(agent_id) do
    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE")) do
      %Agent{} = agent -> agent
      nil -> Repo.rollback(:agent_not_found)
    end
  end

  defp lock_same_user_binding!(%Agent{id: agent_id, user_id: user_id}) when is_binary(user_id) do
    case Repo.one(
           from(binding in Binding,
             where: binding.agent_id == ^agent_id,
             where: binding.user_id == ^user_id,
             lock: "FOR UPDATE"
           )
         ) do
      %Binding{} = binding -> binding
      nil -> Repo.rollback(:agent_binding_not_found)
    end
  end

  defp lock_same_user_binding!(%Agent{}), do: Repo.rollback(:agent_owner_missing)

  defp lock_optional_same_user_binding!(%Agent{id: agent_id, user_id: user_id})
       when is_binary(user_id) do
    Repo.one(
      from(binding in Binding,
        where: binding.agent_id == ^agent_id,
        where: binding.user_id == ^user_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_optional_same_user_binding!(%Agent{}), do: nil

  # Canonical order after Agent -> Binding: Guard -> Lease -> processing
  # Directive -> active Run -> Effect. Process/RPC calls happen only after the
  # transaction using this order has committed.
  defp lock_runtime_rows!(agent_id) do
    _guard =
      Repo.one(
        from(guard in AgentRestartGuard,
          where: guard.agent_id == ^agent_id,
          lock: "FOR UPDATE"
        )
      )

    lease =
      Repo.one(
        from(lease in AgentRuntimeLease,
          where: lease.agent_id == ^agent_id,
          lock: "FOR UPDATE"
        )
      )

    _operation =
      Repo.one(
        from(operation in AgentLifecycleOperation,
          where: operation.agent_id == ^agent_id,
          lock: "FOR UPDATE"
        )
      )

    _directives =
      Repo.all(
        from(directive in AgentDirective,
          where: directive.agent_id == ^agent_id,
          where: directive.status == "processing",
          order_by: [asc: directive.id],
          lock: "FOR UPDATE"
        )
      )

    _runs =
      Repo.all(
        from(run in AgentRun,
          where: run.agent_id == ^agent_id,
          where: run.status == "running",
          order_by: [asc: run.id],
          lock: "FOR UPDATE"
        )
      )

    _steps =
      Repo.all(
        from(step in AgentRunStep,
          where: step.agent_id == ^agent_id,
          where: step.status == "requested",
          order_by: [asc: step.id],
          lock: "FOR UPDATE"
        )
      )

    lease
  end

  defp lock_lifecycle_operation!(agent_id, operation_token) do
    case Repo.one(
           from(operation in AgentLifecycleOperation,
             where: operation.agent_id == ^agent_id,
             where: operation.operation_token == ^operation_token,
             where: operation.state == "draining",
             lock: "FOR UPDATE"
           )
         ) do
      %AgentLifecycleOperation{} = operation -> operation
      nil -> Repo.rollback(:lifecycle_operation_not_found)
    end
  end

  defp ensure_lifecycle_authority!(%Agent{} = agent, operation_token, lease) do
    operation = lock_lifecycle_operation!(agent.id, operation_token)

    guard =
      Repo.one(
        from(guard in AgentRestartGuard,
          where: guard.agent_id == ^agent.id,
          lock: "FOR UPDATE"
        )
      )

    cond do
      agent.status != "stopped" ->
        Repo.rollback(:lifecycle_operation_fence_lost)

      not is_nil(lease) ->
        Repo.rollback(:runtime_lease_requires_reconciliation)

      not is_map(operation.payload) or
          operation.request_digest !=
            AgentLifecycleOperations.digest(Map.get(operation.payload, "request", %{})) ->
        Repo.rollback(:lifecycle_operation_payload_mismatch)

      operation.payload_digest != AgentLifecycleOperations.digest(operation.payload) ->
        Repo.rollback(:lifecycle_operation_payload_mismatch)

      operation.requires_external_drain and is_nil(operation.external_drain_confirmed_at) ->
        Repo.rollback(:external_fleet_drain_required)

      lifecycle_guard_valid?(guard, operation) ->
        operation

      true ->
        Repo.rollback(:restart_guard_requires_reconciliation)
    end
  end

  defp lifecycle_guard_valid?(nil, _operation), do: true

  defp lifecycle_guard_valid?(%AgentRestartGuard{} = guard, operation) do
    not (guard.needs_recovery or guard.tripped) or
      (is_binary(operation.expected_owner_token) and
         guard.last_owner_token == operation.expected_owner_token)
  end

  defp lock_plan_authority!(%CancellationPlan{} = plan, %Agent{} = agent) do
    if plan.agent_id != agent.id, do: Repo.rollback(:effect_cancellation_agent_mismatch)

    case plan.lifecycle_operation_token do
      nil ->
        # Caller ownership was fenced when cancellation intent committed. Once
        # a row is durably `cancelling`, crash reconciliation must not depend on
        # a still-present Binding merely to prove and settle physical death.
        _binding = lock_optional_same_user_binding!(agent)
        lock_runtime_rows!(agent.id)

      operation_token ->
        _binding = lock_optional_same_user_binding!(agent)
        lease = lock_runtime_rows!(agent.id)
        ensure_lifecycle_authority!(agent, operation_token, lease)
    end
  end

  defp authorize_plan_execution(%CancellationPlan{lifecycle_operation_token: nil}), do: :ok

  defp authorize_plan_execution(%CancellationPlan{} = plan) do
    case Repo.transaction(fn ->
           ProtocolCutover.require_exact_reconciliation!()
           agent = lock_agent!(plan.agent_id)
           lock_plan_authority!(plan, agent)
           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp lock_effects_for_cancellation!(agent_id) do
    Repo.all(
      from effect in Effect,
        where: effect.agent_id == ^agent_id,
        where: effect.status in ["pending", "claimed", "executing", "cancelling"],
        where: not is_nil(effect.runtime_owner_generation),
        order_by: [asc: effect.id],
        lock: "FOR UPDATE"
    )
  end

  defp lock_referenced_effects!(agent_id, references) do
    ids = references |> Enum.map(& &1.effect_id) |> Enum.uniq() |> Enum.sort()

    Repo.all(
      from effect in Effect,
        where: effect.agent_id == ^agent_id,
        where: effect.id in ^ids,
        order_by: [asc: effect.id],
        lock: "FOR UPDATE"
    )
  end

  defp lock_effect!(agent_id, effect_id) do
    case Repo.one(
           from(effect in Effect,
             where: effect.id == ^effect_id,
             where: effect.agent_id == ^agent_id,
             lock: "FOR UPDATE"
           )
         ) do
      %Effect{} = effect -> effect
      nil -> Repo.rollback(:effect_cancellation_claim_lost)
    end
  end

  defp claim_from_effect!(%Effect{} = effect) do
    claim = %{
      effect_id: effect.id,
      agent_id: effect.agent_id,
      claim_token: effect.claim_token,
      runtime_owner_generation: effect.runtime_owner_generation,
      owner_node: effect.claim_owner_node,
      supervisor_id: effect.claim_supervisor_id,
      task_id: effect.claim_task_id
    }

    case validate_claim(claim) do
      {:ok, valid} -> valid
      {:error, _reason} -> Repo.rollback(:legacy_effect_claim_requires_drain)
    end
  end

  defp validate_claim(claim) when is_map(claim) do
    with {:ok, effect_id} <- claim |> Map.get(:effect_id) |> cast_uuid(),
         {:ok, agent_id} <- claim |> Map.get(:agent_id) |> cast_uuid(),
         {:ok, claim_token} <- claim |> Map.get(:claim_token) |> cast_uuid(),
         {:ok, runtime_owner_generation} <-
           claim |> Map.get(:runtime_owner_generation) |> cast_uuid(),
         {:ok, supervisor_id} <- claim |> Map.get(:supervisor_id) |> cast_uuid(),
         {:ok, task_id} <- claim |> Map.get(:task_id) |> cast_uuid(),
         {:ok, owner_node} <- owner_node(Map.get(claim, :owner_node)) do
      {:ok,
       %{
         effect_id: effect_id,
         agent_id: agent_id,
         claim_token: claim_token,
         runtime_owner_generation: runtime_owner_generation,
         owner_node: owner_node,
         supervisor_id: supervisor_id,
         task_id: task_id
       }}
    else
      _invalid -> {:error, :invalid_effect_claim}
    end
  end

  defp validate_claim(_claim), do: {:error, :invalid_effect_claim}

  defp runtime_node(owner_name) do
    runtime_nodes = [node() | Node.list(:connected)] |> Enum.uniq()

    if length(runtime_nodes) > @max_runtime_nodes do
      {:error, :effect_claim_owner_unknown}
    else
      case Enum.find(runtime_nodes, &(Atom.to_string(&1) == owner_name)) do
        nil -> {:error, :effect_claim_owner_unknown}
        owner -> {:ok, owner}
      end
    end
  end

  defp exact_references(effects) do
    effects
    |> Enum.reduce_while({:ok, []}, fn
      %Effect{id: id, claim_token: claim_token}, {:ok, acc} ->
        case exact_reference(id, claim_token) do
          {:ok, reference} -> {:cont, {:ok, [reference | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end

      %{effect_id: id, claim_token: claim_token}, {:ok, acc} ->
        case exact_reference(id, claim_token) do
          {:ok, reference} -> {:cont, {:ok, [reference | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_effect_cancellation}}
    end)
    |> case do
      {:ok, references} -> {:ok, Enum.reverse(references) |> Enum.uniq()}
      {:error, _reason} = error -> error
    end
  end

  defp exact_reference(effect_id, claim_token) do
    with {:ok, effect_id} <- cast_uuid(effect_id),
         {:ok, claim_token} <- cast_uuid(claim_token) do
      {:ok, %{effect_id: effect_id, claim_token: claim_token}}
    end
  end

  defp prepare_agent_opts(opts) do
    allowed = [:user_id, :limit, :expected_runtime_owner_generation]

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      normalize_agent_prepared_opts(opts)
    else
      {:error, :invalid_effect_cancellation}
    end
  end

  defp normalize_agent_prepared_opts(%{
         limit: limit,
         user_id: user_id,
         expected_runtime_owner_generation: expected_runtime_owner_generation
       }) do
    validate_agent_prepared_opts(limit, user_id, expected_runtime_owner_generation)
  end

  defp normalize_agent_prepared_opts(opts) when is_list(opts) do
    validate_agent_prepared_opts(
      Keyword.get(opts, :limit, @default_plan_limit),
      Keyword.get(opts, :user_id),
      Keyword.get(opts, :expected_runtime_owner_generation)
    )
  end

  defp normalize_agent_prepared_opts(_opts), do: {:error, :invalid_effect_cancellation}

  defp validate_agent_prepared_opts(limit, user_id, expected_runtime_owner_generation) do
    with {:ok, limit} <- plan_limit(limit),
         {:ok, user_id} <- optional_user_id(user_id),
         {:ok, expected_runtime_owner_generation} <-
           cast_uuid(expected_runtime_owner_generation) do
      {:ok,
       %{
         limit: limit,
         user_id: user_id,
         expected_runtime_owner_generation: expected_runtime_owner_generation
       }}
    else
      _invalid -> {:error, :effect_cancellation_owner_generation_required}
    end
  end

  defp prepare_opts(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in [:user_id, :limit])) do
      normalize_prepared_opts(opts)
    else
      {:error, :invalid_effect_cancellation}
    end
  end

  defp normalize_prepared_opts(%{limit: limit, user_id: user_id}) do
    validate_prepared_opts(limit, user_id)
  end

  defp normalize_prepared_opts(opts) when is_list(opts) do
    validate_prepared_opts(
      Keyword.get(opts, :limit, @default_plan_limit),
      Keyword.get(opts, :user_id)
    )
  end

  defp normalize_prepared_opts(_opts), do: {:error, :invalid_effect_cancellation}

  defp validate_prepared_opts(limit, user_id) do
    with {:ok, limit} <- plan_limit(limit),
         {:ok, user_id} <- optional_user_id(user_id) do
      {:ok, %{limit: limit, user_id: user_id}}
    else
      _invalid -> {:error, :invalid_effect_cancellation}
    end
  end

  defp plan_limit(value) when is_integer(value) and value in 1..@max_plan_limit,
    do: {:ok, value}

  defp plan_limit(_value), do: {:error, :invalid_effect_cancellation}

  defp ensure_expected_user!(_binding, nil), do: :ok
  defp ensure_expected_user!(%Binding{user_id: user_id}, user_id), do: :ok
  defp ensure_expected_user!(_binding, _expected), do: Repo.rollback(:agent_owner_mismatch)

  defp ensure_expected_runtime_owner!(
         %AgentRuntimeLease{owner_token: owner_token, lease_until: lease_until},
         owner_token
       )
       when is_binary(owner_token) and not is_nil(lease_until) do
    if DateTime.compare(lease_until, DatabaseClock.now!()) == :gt do
      :ok
    else
      Repo.rollback(:effect_cancellation_owner_generation_lost)
    end
  end

  defp ensure_expected_runtime_owner!(_lease, _owner_token),
    do: Repo.rollback(:effect_cancellation_owner_generation_lost)

  defp cancellation_reason(value) when is_binary(value) and byte_size(value) in 1..255 do
    if String.valid?(value) and not Regex.match?(~r/[\x00-\x1F\x7F]/u, value),
      do: {:ok, value},
      else: {:error, :invalid_effect_cancellation}
  end

  defp cancellation_reason(_value), do: {:error, :invalid_effect_cancellation}

  defp cancellation_error(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> bound_error_code()

  defp cancellation_error(reason) when is_binary(reason) do
    reason |> Maraithon.Redaction.error_summary() |> bound_error_code()
  end

  defp cancellation_error(_reason), do: "effect_task_termination_unproven"

  defp bound_error_code(value) when is_binary(value) and byte_size(value) <= 255 do
    if String.valid?(value), do: value, else: "effect_task_termination_unproven"
  end

  defp bound_error_code(value) when is_binary(value) do
    value
    |> binary_part(0, 255)
    |> trim_incomplete_utf8()
  end

  defp trim_incomplete_utf8(value) do
    if String.valid?(value) do
      value
    else
      trim_incomplete_utf8(binary_part(value, 0, byte_size(value) - 1))
    end
  end

  defp owner_node(value) when is_binary(value) and byte_size(value) in 1..255 do
    if String.valid?(value) and not Regex.match?(~r/[\s\x00-\x1F\x7F]/u, value),
      do: {:ok, value},
      else: {:error, :invalid_effect_claim}
  end

  defp owner_node(_value), do: {:error, :invalid_effect_claim}

  defp optional_user_id(nil), do: {:ok, nil}

  defp optional_user_id(value) when is_binary(value) and byte_size(value) in 1..320 do
    if String.valid?(value) and not Regex.match?(~r/[\s\x00-\x1F\x7F]/u, value),
      do: {:ok, value},
      else: {:error, :invalid_user_id}
  end

  defp optional_user_id(_value), do: {:error, :invalid_user_id}

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_effect_cancellation}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_effect_cancellation}

  defp require_enabled do
    case ProtocolCutover.mode() do
      :exact -> :ok
      {:blocked, reason} -> {:error, {:effect_protocol_mismatch, reason}}
      _legacy -> {:error, :durable_effect_cancellation_disabled}
    end
  end

  defp require_transaction! do
    unless Repo.in_transaction?() do
      raise ArgumentError, "effect cancellation preparation requires a Repo transaction"
    end

    :ok
  end
end
