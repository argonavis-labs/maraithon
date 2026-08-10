defmodule Maraithon.Effects do
  @moduledoc """
  Effect outbox for managing side effects.
  """

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Effects.Cancellation
  alias Maraithon.Effects.CancellationPlan
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Effects.TerminalEnvelope
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.LLM

  @max_params_bytes 160_000
  @max_param_binary_bytes 128_000
  @max_result_bytes 512_000
  @max_result_binary_bytes 256_000
  @max_tool_name_bytes 255
  @result_dispatch_retry_ms 5_000
  @result_dispatch_retry_cap_ms 300_000
  @max_terminal_dispatch_batch 32
  @max_cancellation_claims 512
  @max_run_terminal_results 64

  @doc """
  Request an effect to be executed.
  """
  def request(agent_id, effect_type, tool_name, params, opts \\ %{}) do
    with {:ok, durable_params} <- durable_request_params(effect_type, tool_name, params) do
      request_prepared(agent_id, effect_type, tool_name, durable_params, opts)
    end
  end

  @doc false
  def request_prepared(agent_id, effect_type, tool_name, params, opts \\ %{})

  def request_prepared(agent_id, effect_type, tool_name, params, opts)
      when is_map(opts) or is_list(opts) do
    effect_id = opts[:effect_id] || Ecto.UUID.generate()
    idempotency_key = opts[:idempotency_key] || Ecto.UUID.generate()
    params = effect_type |> put_execution_lane(params) |> put_effect_protocol()

    with {:ok, agent_run_id} <- optional_uuid(opts[:agent_run_id]),
         {:ok, agent_run_step_id} <- optional_uuid(opts[:agent_run_step_id]),
         {:ok, runtime_owner_generation} <- optional_uuid(opts[:runtime_owner_generation]),
         {:ok, prepared} <- prepare_params(tool_name, params) do
      do_request(
        agent_id,
        effect_type,
        prepared,
        effect_id,
        idempotency_key,
        agent_run_id,
        agent_run_step_id,
        runtime_owner_generation
      )
    end
  end

  def request_prepared(_agent_id, _effect_type, _tool_name, _params, _opts),
    do: {:error, :invalid_effect_options}

  defp optional_uuid(nil), do: {:ok, nil}

  defp optional_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_effect_options}
    end
  end

  defp optional_uuid(_value), do: {:error, :invalid_effect_options}

  defp put_execution_lane(effect_type, params)
       when effect_type in [:llm_call, "llm_call"] and is_map(params) and not is_struct(params) do
    Map.put(params, "__maraithon_execution_lane", params |> LLM.execution_bucket() |> to_string())
  end

  defp put_execution_lane(_effect_type, params), do: params

  defp put_effect_protocol(params) when is_map(params) and not is_struct(params) do
    Map.put(params, "__maraithon_effect_protocol", 2)
  end

  defp put_effect_protocol(params), do: params

  defp durable_request_params(effect_type, tool_name, args)
       when effect_type in [:tool_call, "tool_call"] and is_binary(tool_name) and is_map(args) and
              not is_struct(args),
       do: {:ok, %{"args" => args}}

  defp durable_request_params(effect_type, _tool_name, params)
       when effect_type not in [:tool_call, "tool_call"],
       do: {:ok, params}

  defp durable_request_params(_effect_type, _tool_name, _params),
    do: {:error, :invalid_effect_params}

  @doc false
  def prepare_params(tool_name, params) when is_map(params) and not is_struct(params) do
    with :ok <- validate_tool_name(tool_name) do
      params = if is_nil(tool_name), do: params, else: Map.put(params, "tool", tool_name)

      if Maraithon.BoundedJSON.valid?(params, @max_params_bytes,
           max_binary_bytes: @max_param_binary_bytes,
           max_depth: 12,
           max_nodes: 20_000,
           max_map_entries: 2_000,
           max_list_items: 2_000
         ) and encoded_within_limit?(params, @max_params_bytes) do
        {:ok, params}
      else
        {:error, :invalid_effect_params}
      end
    end
  end

  def prepare_params(_tool_name, _params), do: {:error, :invalid_effect_params}

  @doc false
  def prepare_result(result) when is_map(result) and not is_struct(result) do
    if Maraithon.BoundedJSON.valid?(result, @max_result_bytes,
         max_binary_bytes: @max_result_binary_bytes,
         max_depth: 12,
         max_nodes: 20_000,
         max_map_entries: 2_000,
         max_list_items: 2_000
       ) do
      with {:ok, encoded} <- Jason.encode(result),
           true <- byte_size(encoded) <= @max_result_bytes,
           {:ok, canonical} when is_map(canonical) <- Jason.decode(encoded) do
        {:ok, canonical}
      else
        _invalid -> {:error, :invalid_effect_result}
      end
    else
      {:error, :invalid_effect_result}
    end
  rescue
    _error -> {:error, :invalid_effect_result}
  end

  def prepare_result(_result), do: {:error, :invalid_effect_result}

  defp do_request(
         agent_id,
         effect_type,
         params,
         effect_id,
         idempotency_key,
         agent_run_id,
         agent_run_step_id,
         runtime_owner_generation
       ) do
    case ProtocolCutover.mode() do
      :exact when is_nil(runtime_owner_generation) ->
        {:error, :effect_runtime_owner_generation_required}

      :exact ->
        case Repo.transaction(fn ->
               Cancellation.fence_effect_admission!(agent_id, runtime_owner_generation)
               fence_effect_run_link!(agent_id, agent_run_id, agent_run_step_id)

               case insert_request_row(
                      agent_id,
                      effect_type,
                      params,
                      effect_id,
                      idempotency_key,
                      agent_run_id,
                      agent_run_step_id,
                      runtime_owner_generation
                    ) do
                 {:ok, inserted_id} -> inserted_id
                 {:error, reason} -> Repo.rollback(reason)
               end
             end) do
          {:ok, inserted_id} -> {:ok, inserted_id}
          {:error, reason} -> {:error, reason}
        end

      :legacy when not is_nil(runtime_owner_generation) ->
        {:error, :durable_effect_cancellation_disabled}

      :legacy ->
        case Repo.transaction(fn ->
               ProtocolCutover.require_legacy_admission!()

               case insert_request(
                      agent_id,
                      effect_type,
                      params,
                      effect_id,
                      idempotency_key,
                      agent_run_id,
                      agent_run_step_id,
                      nil
                    ) do
                 {:ok, inserted_id} -> inserted_id
                 {:error, reason} -> Repo.rollback(reason)
               end
             end) do
          {:ok, inserted_id} -> {:ok, inserted_id}
          {:error, reason} -> {:error, reason}
        end

      {:blocked, reason} ->
        {:error, {:effect_protocol_mismatch, reason}}
    end
  end

  defp insert_request(
         agent_id,
         effect_type,
         params,
         effect_id,
         idempotency_key,
         agent_run_id,
         agent_run_step_id,
         runtime_owner_generation
       ) do
    if valid_run_link?(agent_id, agent_run_id, agent_run_step_id) do
      insert_request_row(
        agent_id,
        effect_type,
        params,
        effect_id,
        idempotency_key,
        agent_run_id,
        agent_run_step_id,
        runtime_owner_generation
      )
    else
      {:error, :invalid_effect_run_context}
    end
  end

  defp insert_request_row(
         agent_id,
         effect_type,
         params,
         effect_id,
         idempotency_key,
         agent_run_id,
         agent_run_step_id,
         runtime_owner_generation
       ) do
    owner_user_id =
      Repo.one(from(agent in Agent, where: agent.id == ^agent_id, select: agent.user_id))

    attrs = %{
      id: effect_id,
      agent_id: agent_id,
      owner_user_id: owner_user_id,
      agent_run_id: agent_run_id,
      agent_run_step_id: agent_run_step_id,
      runtime_owner_generation: runtime_owner_generation,
      effect_type: to_string(effect_type),
      params: params,
      legacy_params:
        if(is_nil(runtime_owner_generation), do: params, else: %{"redacted" => true}),
      effect_protocol_version: Map.get(params, "__maraithon_effect_protocol"),
      execution_lane: Map.get(params, "__maraithon_execution_lane"),
      idempotency_key: idempotency_key,
      status: "pending",
      attempts: 0,
      max_attempts: 3
    }

    case %Effect{} |> Effect.protocol_changeset(attrs) |> Repo.insert() do
      {:ok, effect} -> {:ok, effect.id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fence_effect_run_link!(_agent_id, nil, nil), do: :ok

  defp fence_effect_run_link!(agent_id, agent_run_id, agent_run_step_id)
       when is_binary(agent_run_id) and is_binary(agent_run_step_id) do
    # fence_effect_admission!/2 already holds this Agent row FOR UPDATE. Read
    # its published pointer before taking the canonical Run -> RunStep locks;
    # the pointer cannot change until this transaction commits.
    active_run_id =
      Repo.one(
        from(agent in Agent,
          where: agent.id == ^agent_id,
          select: agent.active_run_id
        )
      )

    run =
      Repo.one(
        from(run in AgentRun,
          where: run.id == ^agent_run_id,
          where: run.agent_id == ^agent_id,
          lock: "FOR UPDATE"
        )
      )

    unless match?(%AgentRun{id: ^active_run_id, status: "running"}, run) do
      Repo.rollback(:invalid_effect_run_context)
    end

    step =
      Repo.one(
        from(step in AgentRunStep,
          where: step.id == ^agent_run_step_id,
          where: step.agent_run_id == ^agent_run_id,
          where: step.agent_id == ^agent_id,
          lock: "FOR UPDATE"
        )
      )

    if match?(%AgentRunStep{status: "requested"}, step) do
      :ok
    else
      Repo.rollback(:invalid_effect_run_context)
    end
  end

  defp fence_effect_run_link!(_agent_id, _agent_run_id, _agent_run_step_id),
    do: Repo.rollback(:invalid_effect_run_context)

  defp valid_run_link?(_agent_id, nil, nil), do: true

  defp valid_run_link?(agent_id, agent_run_id, agent_run_step_id)
       when is_binary(agent_id) and is_binary(agent_run_id) and is_binary(agent_run_step_id) do
    Repo.exists?(
      from(step in AgentRunStep,
        join: run in AgentRun,
        on: run.id == step.agent_run_id,
        join: agent in Agent,
        on: agent.id == run.agent_id,
        where: step.id == ^agent_run_step_id,
        where: step.agent_run_id == ^agent_run_id,
        where: step.agent_id == ^agent_id,
        where: step.status == "requested",
        where: run.agent_id == ^agent_id,
        where: run.status == "running",
        where: agent.active_run_id == run.id
      )
    )
  end

  defp valid_run_link?(_agent_id, _agent_run_id, _agent_run_step_id), do: false

  defp encoded_within_limit?(value, max_bytes) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded) <= max_bytes
      {:error, _reason} -> false
    end
  rescue
    _error -> false
  end

  defp validate_tool_name(nil), do: :ok

  defp validate_tool_name(tool_name)
       when is_binary(tool_name) and byte_size(tool_name) > 0 and
              byte_size(tool_name) <= @max_tool_name_bytes do
    if String.valid?(tool_name), do: :ok, else: {:error, :invalid_effect_params}
  end

  defp validate_tool_name(_tool_name), do: {:error, :invalid_effect_params}

  @doc false
  def list_terminal_results_for_dispatch(limit \\ @max_terminal_dispatch_batch)
      when is_integer(limit) and limit in 1..@max_terminal_dispatch_batch do
    Repo.all(
      from(effect in Effect,
        join: agent in Agent,
        on: agent.id == effect.agent_id,
        # Keep run provenance in a correlated EXISTS so the same ownership
        # rule can be reused safely by the UPDATE reservation path.
        where: agent.status in ["running", "degraded"],
        where: agent.install_status == "enabled",
        where: fragment("? IS NOT DISTINCT FROM ?", effect.owner_user_id, agent.user_id),
        where:
          is_nil(effect.agent_run_id) or
            fragment(
              "EXISTS (SELECT 1 FROM agent_runs AS ownership_run WHERE ownership_run.id = ? AND ownership_run.agent_id = ? AND ownership_run.user_id IS NOT DISTINCT FROM ?)",
              effect.agent_run_id,
              effect.agent_id,
              effect.owner_user_id
            ),
        where: effect.status in ["completed", "failed"],
        where: not is_nil(effect.result_envelope),
        where: is_nil(effect.result_acknowledged_at),
        where:
          is_nil(effect.result_dispatch_after) or
            fragment("? <= timezone('UTC', NOW())", effect.result_dispatch_after),
        order_by: [
          asc_nulls_first: effect.result_dispatch_after,
          asc: effect.inserted_at,
          asc: effect.id
        ],
        limit: ^limit,
        select: struct(effect, [:id, :agent_id, :result_dispatch_attempts])
      )
    )
  end

  @doc false
  def reserve_terminal_result_dispatch(%Effect{id: effect_id, agent_id: agent_id} = effect) do
    attempts = min((effect.result_dispatch_attempts || 0) + 1, 1_000_000)
    exponent = min(attempts - 1, 6)

    retry_ms =
      min(@result_dispatch_retry_ms * Integer.pow(2, exponent), @result_dispatch_retry_cap_ms)

    query =
      from(stored in Effect,
        join: agent in Agent,
        on: agent.id == stored.agent_id,
        where: stored.id == ^effect_id,
        where: stored.agent_id == ^agent_id,
        where: fragment("? IS NOT DISTINCT FROM ?", stored.owner_user_id, agent.user_id),
        where:
          is_nil(stored.agent_run_id) or
            fragment(
              "EXISTS (SELECT 1 FROM agent_runs AS ownership_run WHERE ownership_run.id = ? AND ownership_run.agent_id = ? AND ownership_run.user_id IS NOT DISTINCT FROM ?)",
              stored.agent_run_id,
              stored.agent_id,
              stored.owner_user_id
            ),
        where: stored.status in ["completed", "failed"],
        where: not is_nil(stored.result_envelope),
        where: is_nil(stored.result_acknowledged_at),
        where:
          is_nil(stored.result_dispatch_after) or
            fragment("? <= timezone('UTC', NOW())", stored.result_dispatch_after),
        update: [
          set: [
            result_dispatched_at: fragment("timezone('UTC', NOW())"),
            result_dispatch_after:
              fragment("timezone('UTC', NOW()) + (? * INTERVAL '1 millisecond')", ^retry_ms),
            result_dispatch_attempts: ^attempts,
            updated_at: fragment("timezone('UTC', NOW())")
          ]
        ]
      )

    case effect_protocol_mutation(fn -> Repo.update_all(query, []) end) do
      {:ok, {count, _rows}} -> {:ok, count == 1}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def acknowledge_terminal_result(effect_id, agent_id)
      when is_binary(effect_id) and is_binary(agent_id) do
    with {:ok, effect_id} <- required_uuid(effect_id),
         {:ok, agent_id} <- required_uuid(agent_id) do
      query =
        from(effect in Effect,
          join: agent in Agent,
          on: agent.id == effect.agent_id,
          where: effect.id == ^effect_id,
          where: effect.agent_id == ^agent_id,
          where: fragment("? IS NOT DISTINCT FROM ?", effect.owner_user_id, agent.user_id),
          where:
            is_nil(effect.agent_run_id) or
              fragment(
                "EXISTS (SELECT 1 FROM agent_runs AS ownership_run WHERE ownership_run.id = ? AND ownership_run.agent_id = ? AND ownership_run.user_id IS NOT DISTINCT FROM ?)",
                effect.agent_run_id,
                effect.agent_id,
                effect.owner_user_id
              ),
          where: effect.status in ["completed", "failed"],
          where: not is_nil(effect.result_envelope),
          where: is_nil(effect.result_acknowledged_at),
          update: [
            set: [
              result_acknowledged_at: fragment("timezone('UTC', NOW())"),
              updated_at: fragment("timezone('UTC', NOW())")
            ]
          ]
        )

      case effect_protocol_mutation(fn -> Repo.update_all(query, []) end) do
        {:ok, {count, _rows}} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid_effect_acknowledgement}
    end
  end

  def acknowledge_terminal_result(_effect_id, _agent_id),
    do: {:error, :invalid_effect_acknowledgement}

  @doc false
  def list_terminal_results_for_run(run_id, agent_id)
      when is_binary(run_id) and is_binary(agent_id) do
    results =
      Repo.all(
        from(effect in Effect,
          join: agent in Agent,
          on: agent.id == effect.agent_id,
          join: run in AgentRun,
          on: run.id == effect.agent_run_id,
          where: effect.agent_run_id == ^run_id,
          where: effect.agent_id == ^agent_id,
          where: run.agent_id == ^agent_id,
          where: fragment("? IS NOT DISTINCT FROM ?", effect.owner_user_id, agent.user_id),
          where: fragment("? IS NOT DISTINCT FROM ?", run.user_id, effect.owner_user_id),
          where: effect.status in ["completed", "failed"],
          where: not is_nil(effect.result_envelope),
          where: is_nil(effect.result_acknowledged_at),
          order_by: [asc: effect.inserted_at, asc: effect.id],
          limit: ^(@max_run_terminal_results + 1)
        )
      )

    if length(results) <= @max_run_terminal_results,
      do: {:ok, results},
      else: {:error, :terminal_result_reconciliation_overflow}
  end

  def list_terminal_results_for_run(_run_id, _agent_id),
    do: {:error, :invalid_effect_reconciliation}

  @doc false
  def acknowledge_terminal_results_for_run(run_id, agent_id)
      when is_binary(run_id) and is_binary(agent_id) do
    query =
      from(effect in Effect,
        where: effect.agent_run_id == ^run_id,
        where: effect.agent_id == ^agent_id,
        where: effect.status in ["completed", "failed"],
        where: not is_nil(effect.result_envelope),
        where: is_nil(effect.result_acknowledged_at),
        update: [
          set: [
            result_acknowledged_at: fragment("timezone('UTC', NOW())"),
            updated_at: fragment("timezone('UTC', NOW())")
          ]
        ]
      )

    case effect_protocol_mutation(fn -> Repo.update_all(query, []) end) do
      {:ok, {count, _rows}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  def acknowledge_terminal_results_for_run(_run_id, _agent_id),
    do: {:error, :invalid_effect_acknowledgement}

  @doc """
  Interpret an already-loaded persisted Effect row using the terminal codec.
  """
  def terminal_result(%Effect{} = effect) do
    effect |> Effect.materialize_legacy_payload() |> TerminalEnvelope.decode()
  end

  @doc """
  Load and interpret an unacknowledged terminal Effect owned by the agent.

  The returned callback result always comes from the persisted row. The caller
  may use a mailbox notification only as a hint to perform this lookup.
  """
  def terminal_result(effect_id, agent_id)
      when is_binary(effect_id) and is_binary(agent_id) do
    with {:ok, canonical_effect_id} <- required_uuid(effect_id),
         {:ok, canonical_agent_id} <- required_uuid(agent_id) do
      case get_terminal_result(canonical_effect_id, canonical_agent_id) do
        %Effect{} = effect -> {:terminal, terminal_result(effect)}
        nil -> :not_terminal
      end
    else
      :error -> {:error, :invalid_effect_reference}
    end
  end

  def terminal_result(_effect_id, _agent_id), do: {:error, :invalid_effect_reference}

  @doc false
  def get_terminal_result(effect_id, agent_id)
      when is_binary(effect_id) and is_binary(agent_id) do
    with {:ok, effect_id} <- required_uuid(effect_id),
         {:ok, agent_id} <- required_uuid(agent_id) do
      Repo.one(
        from(effect in Effect,
          join: agent in Agent,
          on: agent.id == effect.agent_id,
          left_join: run in AgentRun,
          on: run.id == effect.agent_run_id,
          where: effect.id == ^effect_id,
          where: effect.agent_id == ^agent_id,
          where: fragment("? IS NOT DISTINCT FROM ?", effect.owner_user_id, agent.user_id),
          where:
            is_nil(effect.agent_run_id) or
              (run.agent_id == effect.agent_id and
                 fragment("? IS NOT DISTINCT FROM ?", run.user_id, effect.owner_user_id)),
          where: effect.status in ["completed", "failed"],
          where: not is_nil(effect.result_envelope),
          where: is_nil(effect.result_acknowledged_at),
          select: effect
        )
      )
    else
      :error -> nil
    end
  end

  def get_terminal_result(_effect_id, _agent_id), do: nil

  @doc """
  Stage exact Effect cancellation inside a standalone database transaction.

  The returned plan must be passed to `finish_cancel_active_for_agent_post_commit/1`
  only after this transaction (and any caller-owned outer transaction) commits.
  """
  def stage_cancel_active_for_agent(agent_id, reason, opts \\ []) do
    Cancellation.prepare(agent_id, reason, opts)
  end

  @doc """
  Stage exact Effect cancellation inside an existing caller-owned transaction.

  This is the transaction-only AgentIsolation composition point. It takes no
  process, Task.Supervisor, RPC, or network action and deliberately does not
  redesign the Binding transition itself.
  """
  def stage_cancel_active_for_agent!(agent_id, reason, opts \\ []) do
    Cancellation.prepare_in_transaction!(agent_id, reason, opts)
  end

  @doc "Execute a committed exact cancellation plan after transaction commit."
  def finish_cancel_active_for_agent_post_commit(%CancellationPlan{} = plan) do
    Cancellation.execute(plan)
  end

  def finish_cancel_active_for_agent_post_commit(_plan),
    do: {:error, :invalid_effect_cancellation_plan}

  @doc false
  def reconcile_exact_cancellations_for_agent(agent_id, limit \\ 32) do
    Cancellation.reconcile_agent(agent_id, limit)
  end

  @doc """
  Cancel active effects without treating an in-flight command as safely stopped.

  With durable cancellation enabled, this stages exact claim identities, routes
  termination after commit, and leaves every unproved owner durably cancelling.
  The bounded legacy bridge is reachable only while the feature gate is off.
  """
  def cancel_active_for_agent(agent_id, reason \\ "agent_recovered", opts \\ [])

  def cancel_active_for_agent(agent_id, reason, opts)
      when is_binary(agent_id) and is_binary(reason) and is_list(opts) do
    case ProtocolCutover.mode() do
      :exact ->
        case Cancellation.request(agent_id, reason, opts) do
          {:ok, summary} -> {:ok, summary.requested}
          {:pending, _summary} -> {:error, :effect_cancellation_pending}
          {:error, _reason} = error -> error
        end

      :legacy ->
        Maraithon.Runtime.EffectRunner.cancel_active_for_agent(agent_id, reason, opts)

      {:blocked, mismatch} ->
        {:error, {:effect_protocol_mismatch, mismatch}}
    end
  end

  @doc false
  def begin_cancel_active_for_agent(agent_id, reason)
      when is_binary(agent_id) and is_binary(reason) do
    case ProtocolCutover.mode() do
      :legacy ->
        begin_cancel_active_for_agent_legacy(agent_id, reason)

      :exact ->
        {:error, :legacy_effect_cancellation_disabled}

      {:blocked, mismatch} ->
        {:error, {:effect_protocol_mismatch, mismatch}}
    end
  end

  defp begin_cancel_active_for_agent_legacy(agent_id, reason) do
    Repo.transaction(fn ->
      ProtocolCutover.require_legacy_mutation!()
      ensure_no_exact_active_effects!(agent_id)

      {pending_count, _rows} =
        Repo.update_all(
          from(effect in Effect,
            where: effect.agent_id == ^agent_id,
            where: effect.status == "pending"
          )
          |> legacy_protocol_rows(),
          set: [
            status: "cancelled",
            claimed_by: nil,
            claimed_at: nil,
            retry_after: nil,
            error: reason,
            updated_at: DateTime.utc_now()
          ]
        )

      {claimed_count, _rows} =
        Repo.update_all(
          from(effect in Effect,
            where: effect.agent_id == ^agent_id,
            where: effect.status == "claimed"
          )
          |> legacy_protocol_rows(),
          set: [
            status: "cancelling",
            retry_after: nil,
            error: reason,
            updated_at: DateTime.utc_now()
          ]
        )

      claims =
        from(effect in Effect,
          where: effect.agent_id == ^agent_id,
          where: effect.status == "cancelling",
          order_by: [asc: effect.inserted_at, asc: effect.id],
          limit: ^(@max_cancellation_claims + 1),
          select: %{
            id: effect.id,
            claimed_by: effect.claimed_by,
            claimed_at: effect.claimed_at
          }
        )
        |> legacy_protocol_rows()
        |> Repo.all()

      overflow? = length(claims) > @max_cancellation_claims
      claims = Enum.take(claims, @max_cancellation_claims)

      %{
        count: pending_count + claimed_count,
        claims: claims,
        overflow?: overflow?
      }
    end)
  end

  @doc false
  def list_legacy_cancellation_agents(limit \\ 32)

  def list_legacy_cancellation_agents(limit) when is_integer(limit) and limit in 1..512 do
    case ProtocolCutover.mode() do
      :legacy ->
        agent_ids =
          from(effect in Effect,
            where: effect.status == "cancelling",
            where: is_nil(effect.runtime_owner_generation),
            distinct: true,
            order_by: [asc: effect.agent_id],
            limit: ^limit,
            select: effect.agent_id
          )
          |> Repo.all()

        {:ok, agent_ids}

      :exact ->
        {:error, :legacy_effect_cancellation_disabled}

      {:blocked, mismatch} ->
        {:error, {:effect_protocol_mismatch, mismatch}}
    end
  end

  def list_legacy_cancellation_agents(_limit),
    do: {:error, :invalid_effect_cancellation_limit}

  @doc false
  def finish_cancel_active_for_agent(agent_id, expected_claims)
      when is_binary(agent_id) and is_list(expected_claims) and
             length(expected_claims) <= @max_cancellation_claims do
    if self() == Process.whereis(Maraithon.Runtime.EffectRunner) do
      case ProtocolCutover.mode() do
        :legacy ->
          finish_cancel_active_for_agent_legacy(agent_id, expected_claims)

        :exact ->
          {:error, :legacy_effect_cancellation_disabled}

        {:blocked, mismatch} ->
          {:error, {:effect_protocol_mismatch, mismatch}}
      end
    else
      {:error, :legacy_effect_termination_proof_required}
    end
  end

  defp finish_cancel_active_for_agent_legacy(agent_id, expected_claims) do
    # A killed task may already have crossed its external side-effect boundary.
    # Termination proof is required before the Agent may resume, but every
    # previously claimed outcome remains conservatively ambiguous. Each write
    # is fenced by its original claim generation so concurrent cancellation
    # cannot terminalize newly fenced work.
    Repo.transaction(fn ->
      ProtocolCutover.require_legacy_mutation!()
      ensure_no_exact_active_effects!(agent_id)
      ensure_expected_claims_are_legacy!(agent_id, expected_claims)

      ambiguous_count =
        Enum.reduce(expected_claims, 0, fn claim, count ->
          query = cancellation_claim_query(agent_id, claim)

          {updated, _rows} =
            Repo.update_all(query,
              set: [
                status: "failed",
                result: nil,
                error: "effect_outcome_ambiguous",
                result_envelope: TerminalEnvelope.error(:effect_outcome_ambiguous),
                result_dispatched_at: nil,
                result_dispatch_after: nil,
                result_dispatch_attempts: 0,
                result_acknowledged_at: nil,
                completion_claimed_by: nil,
                completion_claimed_at: nil,
                claimed_by: nil,
                claimed_at: nil,
                retry_after: nil,
                updated_at: DateTime.utc_now()
              ]
            )

          count + updated
        end)

      %{cancelled: 0, ambiguous: ambiguous_count}
    end)
  end

  defp cancellation_claim_query(agent_id, %{
         id: id,
         claimed_by: claimed_by,
         claimed_at: claimed_at
       }) do
    query =
      from(effect in Effect,
        where: effect.agent_id == ^agent_id,
        where: effect.id == ^id,
        where: effect.status == "cancelling"
      )
      |> legacy_protocol_rows()

    query =
      if is_nil(claimed_by),
        do: where(query, [effect], is_nil(effect.claimed_by)),
        else: where(query, [effect], effect.claimed_by == ^claimed_by)

    if is_nil(claimed_at),
      do: where(query, [effect], is_nil(effect.claimed_at)),
      else: where(query, [effect], effect.claimed_at == ^claimed_at)
  end

  defp ensure_no_exact_active_effects!(agent_id) do
    base =
      from(effect in Effect,
        where: effect.agent_id == ^agent_id,
        where: effect.status in ["pending", "claimed", "cancelling"]
      )

    total = Repo.aggregate(base, :count, :id)
    legacy = base |> legacy_protocol_rows() |> Repo.aggregate(:count, :id)

    if total == legacy, do: :ok, else: Repo.rollback({:effect_protocol_mismatch, total - legacy})
  end

  defp ensure_expected_claims_are_legacy!(agent_id, expected_claims) do
    ids =
      Enum.flat_map(expected_claims, fn
        %{id: id} when is_binary(id) -> [id]
        _invalid -> []
      end)

    if length(ids) != length(expected_claims) do
      Repo.rollback(:invalid_effect_cancellation)
    end

    base =
      from(effect in Effect,
        where: effect.agent_id == ^agent_id,
        where: effect.id in ^ids
      )

    total = Repo.aggregate(base, :count, :id)
    legacy = base |> legacy_protocol_rows() |> Repo.aggregate(:count, :id)

    if total == legacy, do: :ok, else: Repo.rollback({:effect_protocol_mismatch, total - legacy})
  end

  defp legacy_protocol_rows(query) do
    from(effect in query,
      where: is_nil(effect.runtime_owner_generation),
      where: is_nil(effect.claim_token),
      where: is_nil(effect.claim_owner_node),
      where: is_nil(effect.claim_heartbeat_at),
      where: is_nil(effect.claim_expires_at),
      where: is_nil(effect.claim_supervisor_id),
      where: is_nil(effect.claim_task_id),
      where: is_nil(effect.cancellation_state),
      where: is_nil(effect.cancellation_reason),
      where: is_nil(effect.cancellation_requested_at),
      where: is_nil(effect.cancellation_target_claim_token),
      where: is_nil(effect.cancellation_last_attempt_at),
      where: is_nil(effect.cancellation_last_error),
      where: is_nil(effect.cancellation_settled_at)
    )
  end

  @doc """
  Encrypts and redacts one bounded batch of legacy Effect payload columns.

  This operator path is deliberately available only before exact protocol
  activation. Rows are locked with `SKIP LOCKED` so multiple workers can make
  resumable progress without a table rewrite.
  """
  def backfill_legacy_payload_encryption(limit \\ 100)

  def backfill_legacy_payload_encryption(limit) when is_integer(limit) and limit in 1..500 do
    case Repo.transaction(fn ->
           ProtocolCutover.require_legacy_mutation!()
           Maraithon.DurablePayloadContraction.require_authorized!()

           effects =
             Effect
             |> where(
               [effect],
               effect.payload_encryption_version != 1 or
                 is_nil(effect.payload_encryption_version) or
                 (is_nil(effect.payload_purged_at) and is_nil(effect.params)) or
                 fragment(
                   "? IS DISTINCT FROM '{\"redacted\": true}'::jsonb",
                   effect.legacy_params
                 ) or
                 not is_nil(effect.legacy_result)
             )
             |> order_by([effect], asc: effect.id)
             |> limit(^limit)
             |> lock("FOR UPDATE SKIP LOCKED")
             |> Repo.all()

           Enum.each(effects, fn effect ->
             params =
               if effect.legacy_params != %{"redacted" => true},
                 do: effect.legacy_params || %{},
                 else: effect.params || %{}

             result =
               if is_nil(effect.legacy_result), do: effect.result, else: effect.legacy_result

             attrs = %{
               params: params,
               result: result,
               legacy_params: %{"redacted" => true},
               legacy_result: nil,
               payload_encryption_version: 1,
               error: normalize_persisted_error(effect.error)
             }

             effect
             |> Effect.protocol_changeset(attrs)
             |> Repo.update!()
           end)

           length(effects)
         end) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:effect_payload_backfill_failed, Maraithon.Redaction.error_class(error)}}
  catch
    :exit, reason ->
      {:error, {:effect_payload_backfill_failed, Maraithon.Redaction.error_class(reason)}}
  end

  def backfill_legacy_payload_encryption(_limit), do: {:error, :invalid_payload_batch_size}

  @doc """
  Irreversibly clears eligible Effect content while retaining identity,
  idempotency, claim provenance, terminal envelope, and acknowledgement facts.
  """
  def purge_terminal_payloads(cutoff, limit \\ 100)

  def purge_terminal_payloads(%DateTime{} = cutoff, limit)
      when is_integer(limit) and limit in 1..500 do
    case Repo.transaction(fn ->
           ProtocolCutover.require_current_mutation!()

           Repo.query!(
             "SELECT set_config('maraithon.effect_payload_retention', " <>
               "'PURGE_ACKNOWLEDGED_PAYLOAD', true)",
             [],
             log: false
           )

           effects =
             Effect
             |> where([effect], is_nil(effect.payload_purged_at))
             |> where(
               [effect],
               (effect.status in ["completed", "failed"] and
                  not is_nil(effect.result_acknowledged_at) and
                  effect.result_acknowledged_at <= ^cutoff) or
                 (effect.status == "cancelled" and
                    ((not is_nil(effect.cancellation_settled_at) and
                        effect.cancellation_settled_at <= ^cutoff) or
                       (is_nil(effect.runtime_owner_generation) and effect.updated_at <= ^cutoff)))
             )
             |> order_by([effect], asc: effect.updated_at, asc: effect.id)
             |> limit(^limit)
             |> lock("FOR UPDATE SKIP LOCKED")
             |> Repo.all()

           now = Maraithon.Runtime.DatabaseClock.now!()

           Enum.each(effects, fn effect ->
             effect
             |> Effect.protocol_changeset(%{
               params: nil,
               legacy_params: %{"redacted" => true},
               result: nil,
               legacy_result: nil,
               payload_purged_at: now
             })
             |> Repo.update!()
           end)

           length(effects)
         end) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:effect_payload_purge_failed, Maraithon.Redaction.error_class(error)}}
  catch
    :exit, reason ->
      {:error, {:effect_payload_purge_failed, Maraithon.Redaction.error_class(reason)}}
  end

  def purge_terminal_payloads(_cutoff, _limit), do: {:error, :invalid_payload_retention}

  defp normalize_persisted_error(nil), do: nil
  defp normalize_persisted_error(error), do: Maraithon.Redaction.error_summary(error)

  @doc """
  Check if an effect has already been executed (for idempotency).
  """
  def check_idempotency(idempotency_key) when is_binary(idempotency_key) do
    with {:ok, idempotency_key} <- required_uuid(idempotency_key) do
      case Repo.get_by(Effect, idempotency_key: idempotency_key) do
        %Effect{status: status, payload_purged_at: %DateTime{}} = effect
        when status in ["completed", "failed", "cancelled"] ->
          {:cached_payload_expired, %{status: status, result_envelope: effect.result_envelope}}

        %Effect{status: status} = effect when status in ["completed", "failed"] ->
          case terminal_result(effect) do
            {:ok, result} -> {:cached, result}
            {:error, reason} -> {:cached_error, reason}
          end

        _nonterminal_or_missing ->
          :not_found
      end
    else
      :error -> :not_found
    end
  end

  def check_idempotency(_idempotency_key), do: :not_found

  defp effect_protocol_mutation(fun) when is_function(fun, 0) do
    if Repo.in_transaction?() do
      ProtocolCutover.require_current_mutation!()
      {:ok, fun.()}
    else
      Repo.transaction(fn ->
        ProtocolCutover.require_current_mutation!()
        fun.()
      end)
    end
  end

  defp required_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp required_uuid(_value), do: :error
end
