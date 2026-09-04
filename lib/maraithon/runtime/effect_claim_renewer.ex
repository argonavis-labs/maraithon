defmodule Maraithon.Runtime.EffectClaimRenewer do
  @moduledoc """
  Independently renews generation-fenced Effect claims from coupled task
  authority. Cancellation RPCs and EffectRunner polling cannot starve this
  heartbeat loop.
  """

  use GenServer

  import Ecto.Query

  alias Maraithon.Effects.{Cancellation, Effect}
  alias Maraithon.Repo
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.EffectTaskSupervisor
  alias Maraithon.Runtime.Coordination.{Protocol, TaskAssignment, TaskClaims}

  require Logger

  @default_interval_ms 5_000
  @default_ttl_ms 30_000
  @min_ttl_ms 30_000
  @max_ttl_ms 300_000
  @physical_teardown_margin_ms 10_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def renew_now, do: GenServer.call(__MODULE__, :renew_now, 10_000)

  @impl true
  def init(_opts) do
    ttl_ms =
      RuntimeConfig.positive_integer(:effect_claim_liveness_ttl_ms, @default_ttl_ms)
      |> max(@min_ttl_ms)
      |> min(@max_ttl_ms)

    requested_interval =
      RuntimeConfig.positive_integer(:effect_claim_heartbeat_interval_ms, @default_interval_ms)

    max_safe_interval = max(div(ttl_ms, 3), 1)
    interval_ms = min(requested_interval, max_safe_interval)

    if interval_ms != requested_interval do
      Logger.warning("Effect claim heartbeat interval clamped below one third of its TTL",
        failure_code: "effect_claim_heartbeat_interval_clamped",
        configured_interval_ms: requested_interval,
        effective_interval_ms: interval_ms,
        ttl_ms: ttl_ms
      )
    end

    schedule_renewal(interval_ms)

    {:ok,
     %{
       interval_ms: interval_ms,
       ttl_ms: ttl_ms,
       renewal_deadlines: %{},
       last_authority_observed_ms: monotonic_ms()
     }}
  end

  @impl true
  def handle_call(:renew_now, _from, state) do
    case renew_active_claims(state) do
      {:fatal, result, state} ->
        {:stop, :effect_claim_authority_uncertain, result, state}

      {result, state} ->
        {:reply, result, state}
    end
  end

  @impl true
  def handle_info(:renew_effect_claims, state) do
    pass_started_ms = monotonic_ms()

    case renew_active_claims(state) do
      {:fatal, _result, state} ->
        {:stop, :effect_claim_authority_uncertain, state}

      {_result, state} ->
        schedule_renewal(next_renewal_delay_ms(state, pass_started_ms))
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp renew_active_claims(state) do
    case EffectTaskSupervisor.active_identities() do
      {:ok, []} ->
        state = %{
          state
          | renewal_deadlines: %{},
            last_authority_observed_ms: monotonic_ms()
        }

        {{:ok, %{active: 0, lost: 0}}, state}

      {:ok, identities} ->
        now_ms = monotonic_ms()
        state = observe_identities(state, identities, now_ms)
        deadline_ms = earliest_renewal_deadline!(state, identities)

        case renew_identities(identities, state.ttl_ms, deadline_ms) do
          {:ok,
           %{
             lost: lost_identities,
             preactivation: preactivation_identities,
             unchanged: unchanged_identities
           }} ->
            if deadline_ms <= monotonic_ms() do
              renewal_failed(state, :effect_claim_heartbeat_deadline_exceeded)
            else
              case terminate_lost_identities(lost_identities) do
                :ok ->
                  if deadline_ms <= monotonic_ms() do
                    renewal_failed(state, :effect_claim_heartbeat_deadline_exceeded)
                  else
                    state =
                      record_successful_renewal(
                        state,
                        identities,
                        lost_identities,
                        preactivation_identities,
                        unchanged_identities,
                        now_ms
                      )

                    {{:ok, %{active: length(identities), lost: length(lost_identities)}}, state}
                  end

                {:error, reason} ->
                  renewal_failed(state, {:effect_claim_termination_unproved, reason})
              end
            end

          {:error, reason} ->
            renewal_failed(state, {:effect_claim_heartbeat_failed, reason})
        end

      {:error, reason} ->
        renewal_failed(state, reason)
    end
  rescue
    error ->
      renewal_failed(state, {:effect_claim_heartbeat_exception, error})
  catch
    :exit, reason -> renewal_failed(state, {:effect_claim_heartbeat_exit, reason})
  end

  defp observe_identities(state, identities, now_ms) do
    # A newly observed task could have claimed immediately after the previous
    # authoritative enumeration, even if this pass was delayed. Anchor its
    # first deadline to that prior observation rather than assuming one normal
    # heartbeat interval of lag.
    first_deadline_ms =
      state.last_authority_observed_ms + state.ttl_ms - @physical_teardown_margin_ms

    deadlines =
      Map.new(identities, fn identity ->
        key = identity_key(identity)
        {key, Map.get(state.renewal_deadlines, key, {identity, first_deadline_ms})}
      end)

    %{
      state
      | renewal_deadlines: deadlines,
        last_authority_observed_ms: now_ms
    }
  end

  defp earliest_renewal_deadline!(state, identities) do
    identities
    |> Enum.map(fn identity ->
      {_identity, deadline_ms} = Map.fetch!(state.renewal_deadlines, identity_key(identity))
      deadline_ms
    end)
    |> Enum.min()
  end

  defp terminate_lost_identities(identities) do
    Enum.reduce_while(identities, :ok, fn identity, :ok ->
      case Cancellation.terminate_physical_identity_on_owner(identity) do
        {:ok, _physical_termination_proof} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
        other -> {:halt, {:error, {:unexpected_termination_result, other}}}
      end
    end)
  catch
    :exit, reason -> {:error, {:termination_exit, reason}}
  end

  defp record_successful_renewal(
         state,
         identities,
         lost_identities,
         preactivation_identities,
         unchanged_identities,
         now_ms
       ) do
    lost_keys = MapSet.new(lost_identities, &identity_key/1)
    preactivation_keys = MapSet.new(preactivation_identities, &identity_key/1)
    unchanged_keys = MapSet.new(unchanged_identities, &identity_key/1)
    deadline_ms = max(state.ttl_ms - @physical_teardown_margin_ms, 1)

    deadlines =
      identities
      |> Enum.reject(&MapSet.member?(lost_keys, identity_key(&1)))
      |> Map.new(fn identity ->
        key = identity_key(identity)

        if MapSet.member?(preactivation_keys, key) or MapSet.member?(unchanged_keys, key) do
          # A pristine reserved handoff is recognized, not renewed. Keep its
          # original physical-teardown deadline aligned with its finite durable
          # leases instead of manufacturing a fresh local renewal window. The
          # same rule applies when a running task remains live but its upstream
          # node/partition/Agent lease cap has not advanced yet.
          {key, Map.fetch!(state.renewal_deadlines, key)}
        else
          {key, {identity, now_ms + deadline_ms}}
        end
      end)

    %{state | renewal_deadlines: deadlines}
  end

  defp renewal_failed(state, reason) do
    # Renewal uncertainty is itself loss of local execution authority. Do not
    # synchronously enumerate or terminate through the Authority here: it may
    # be the failed sibling, and per-task calls can delay teardown beyond the
    # claim TTL. This abnormal return stops the Renewer immediately; the
    # coupled :one_for_all supervisor then tears down the exact TaskSupervisor
    # and all provider tasks as the physical backstop.
    Logger.warning("Effect claim heartbeat failed closed",
      failure_code: Maraithon.Redaction.error_class(reason),
      error_class: heartbeat_failure_class(reason),
      remembered_local_tasks: map_size(state.renewal_deadlines)
    )

    {:fatal, {:error, :effect_claim_heartbeat_failed}, state}
  end

  defp heartbeat_failure_class({wrapper, reason})
       when wrapper in [
              :effect_claim_heartbeat_failed,
              :effect_claim_heartbeat_exception,
              :effect_claim_heartbeat_exit,
              :effect_claim_termination_unproved
            ],
       do: heartbeat_failure_class(reason)

  defp heartbeat_failure_class(%Postgrex.Error{postgres: %{code: code}}) when is_atom(code),
    do: "postgres_#{code}"

  defp heartbeat_failure_class(reason), do: Maraithon.Redaction.error_class(reason)

  defp identity_key(identity) do
    {
      identity.effect_id,
      identity.agent_id,
      identity.claim_token,
      identity.assignment_id,
      identity.supervisor_id,
      identity.task_id
    }
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp renew_identities([], _ttl_ms, _deadline_ms),
    do: {:ok, %{lost: [], preactivation: [], unchanged: []}}

  defp renew_identities(identities, ttl_ms, deadline_ms) do
    transaction_timeout_ms = max(deadline_ms - monotonic_ms(), 1)

    case Repo.transaction(
           fn ->
             configure_renewal_statement_timeout!(deadline_ms)

             coordination_mode =
               case Protocol.lock_effect_pair!() do
                 {:active, epoch} -> {:active, epoch}
                 other -> Repo.rollback({:runtime_effect_protocol_pair_mismatch, other})
               end

             owner_node = Atom.to_string(node())

             {lost, preactivation, unchanged} =
               identities
               |> Enum.sort_by(&identity_key/1)
               |> Enum.reduce({[], [], []}, fn identity, {lost, preactivation, unchanged} ->
                 configure_renewal_statement_timeout!(deadline_ms)

                 case renew_identity_in_transaction!(
                        identity,
                        owner_node,
                        ttl_ms,
                        coordination_mode
                      ) do
                   :renewed -> {lost, preactivation, unchanged}
                   :preactivation -> {lost, [identity | preactivation], unchanged}
                   :unchanged -> {lost, preactivation, [identity | unchanged]}
                   :lost -> {[identity | lost], preactivation, unchanged}
                 end
               end)

             %{
               lost: Enum.reverse(lost),
               preactivation: Enum.reverse(preactivation),
               unchanged: Enum.reverse(unchanged)
             }
           end,
           timeout: transaction_timeout_ms
         ) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp renew_identity_in_transaction!(identity, owner_node, ttl_ms, coordination_mode) do
    stored =
      Repo.one(
        from effect in Effect,
          where: effect.id == ^identity.effect_id,
          where: effect.agent_id == ^identity.agent_id,
          where: effect.status in ["claimed", "executing"],
          where: effect.claim_token == ^identity.claim_token,
          where: effect.claim_owner_node == ^owner_node,
          where: effect.claim_supervisor_id == ^identity.supervisor_id,
          where: effect.claim_task_id == ^identity.task_id,
          where: effect.coordination_task_assignment_id == ^identity.assignment_id,
          where: is_nil(effect.cancellation_state),
          where: effect.claim_expires_at > fragment("timezone('UTC', clock_timestamp())"),
          where:
            fragment(
              "EXISTS (SELECT 1 FROM agent_runtime_leases AS effect_owner_lease WHERE effect_owner_lease.agent_id = ? AND effect_owner_lease.owner_token = ? AND effect_owner_lease.ready_at IS NOT NULL AND effect_owner_lease.draining_at IS NULL AND effect_owner_lease.lease_until > timezone('UTC', clock_timestamp()))",
              effect.agent_id,
              effect.runtime_owner_generation
            ),
          lock: "FOR UPDATE"
      )

    case stored do
      nil ->
        :lost

      %Effect{} = effect ->
        case renew_coordination_assignment!(effect, ttl_ms, coordination_mode) do
          :preactivation when effect.status == "claimed" ->
            # Both finite durable leases were checked under their exact row
            # locks. Do not heartbeat or extend either one before activation.
            :preactivation

          :preactivation ->
            Repo.rollback(:coordination_task_authority_lost)

          {:renewed, expires_at} ->
            query =
              from(stored in Effect,
                where: stored.id == ^effect.id,
                where: stored.agent_id == ^effect.agent_id,
                where: stored.status == ^effect.status,
                where: stored.claim_token == ^effect.claim_token,
                where: stored.claim_owner_node == ^owner_node,
                where: stored.claim_supervisor_id == ^effect.claim_supervisor_id,
                where: stored.claim_task_id == ^effect.claim_task_id,
                where: stored.coordination_task_assignment_id == ^identity.assignment_id,
                where: is_nil(stored.cancellation_state),
                update: [
                  set: [
                    claim_heartbeat_at: fragment("timezone('UTC', clock_timestamp())"),
                    claim_expires_at: ^expires_at,
                    updated_at: fragment("timezone('UTC', clock_timestamp())")
                  ]
                ]
              )

            case Repo.update_all(query, []) do
              {1, _rows} -> :renewed
              _lost_or_mismatched -> Repo.rollback(:coordination_task_authority_lost)
            end

          {:unchanged, expires_at} ->
            if DateTime.compare(effect.claim_expires_at, expires_at) == :eq,
              do: :unchanged,
              else: Repo.rollback(:coordination_task_authority_lost)
        end
    end
  end

  defp renew_coordination_assignment!(
         %Effect{} = effect,
         ttl_ms,
         {:active, activation_epoch}
       ) do
    unless activation_epoch == effect.coordination_activation_epoch,
      do: Repo.rollback(:coordination_task_authority_lost)

    assignment = effect_assignment!(effect)

    result =
      TaskClaims.renew_effect_in_transaction!(
        assignment,
        effect.agent_id,
        effect.runtime_owner_generation,
        ttl_ms
      )

    case result do
      {:renewed, %TaskAssignment{state: "running"} = value} ->
        unless exact_assignment?(value, assignment),
          do: Repo.rollback(:coordination_task_authority_lost)

        {:renewed, value.lease_expires_at}

      {:unchanged, %TaskAssignment{state: "running"} = value} ->
        unless exact_assignment?(value, assignment),
          do: Repo.rollback(:coordination_task_authority_lost)

        {:unchanged, value.lease_expires_at}

      {:preactivation,
       %TaskAssignment{
         state: "reserved",
         provider_boundary: "not_entered",
         ready_at: nil
       } = value} ->
        unless exact_assignment?(value, assignment),
          do: Repo.rollback(:coordination_task_authority_lost)

        :preactivation

      _mismatched ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  defp renew_coordination_assignment!(%Effect{}, _ttl_ms, _mode),
    do: Repo.rollback(:coordination_task_authority_lost)

  defp effect_assignment!(%Effect{
         id: work_id,
         claim_token: claim_token,
         claim_supervisor_id: supervisor_id,
         claim_task_id: local_task_id,
         coordination_task_assignment_id: assignment_id,
         coordination_activation_epoch: activation_epoch,
         coordination_partition_id: partition_id,
         coordination_partition_epoch: partition_epoch,
         coordination_node_incarnation_id: node_incarnation_id
       })
       when is_binary(work_id) and is_binary(claim_token) and is_binary(supervisor_id) and
              is_binary(local_task_id) and is_binary(assignment_id) and
              is_binary(activation_epoch) and is_integer(partition_id) and
              is_integer(partition_epoch) and is_binary(node_incarnation_id) do
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
    }
  end

  defp effect_assignment!(%Effect{}), do: Repo.rollback(:coordination_task_authority_lost)

  defp exact_assignment?(actual, expected) do
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

  defp configure_renewal_statement_timeout!(deadline_ms) do
    remaining_ms = deadline_ms - monotonic_ms()

    if remaining_ms <= 0 do
      Repo.rollback(:effect_claim_heartbeat_deadline_exceeded)
    end

    timeout = "#{remaining_ms}ms"
    Repo.query!("SELECT set_config('statement_timeout', $1, true)", [timeout], log: false)
    Repo.query!("SELECT set_config('lock_timeout', $1, true)", [timeout], log: false)
    :ok
  end

  defp next_renewal_delay_ms(state, pass_started_ms) do
    now_ms = monotonic_ms()
    cadence_delay_ms = max(state.interval_ms - (now_ms - pass_started_ms), 0)

    deadline_delay_ms =
      case Map.values(state.renewal_deadlines) do
        [] ->
          cadence_delay_ms

        deadlines ->
          earliest_ms = deadlines |> Enum.map(&elem(&1, 1)) |> Enum.min()
          max(earliest_ms - now_ms - state.interval_ms, 0)
      end

    min(cadence_delay_ms, deadline_delay_ms)
  end

  defp schedule_renewal(interval_ms) do
    Process.send_after(self(), :renew_effect_claims, interval_ms)
  end
end
