defmodule Maraithon.Effects do
  @moduledoc """
  Effect outbox for managing side effects.
  """

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Effects.Effect
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
  @ambiguous_cancellation_envelope %{
    "status" => "error",
    "reason" => %{"type" => "atom", "value" => "effect_outcome_ambiguous"}
  }

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
         {:ok, prepared} <- prepare_params(tool_name, params) do
      do_request(
        agent_id,
        effect_type,
        prepared,
        effect_id,
        idempotency_key,
        agent_run_id,
        agent_run_step_id
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
         agent_run_step_id
       ) do
    if valid_run_link?(agent_id, agent_run_id, agent_run_step_id) do
      owner_user_id =
        Repo.one(from(agent in Agent, where: agent.id == ^agent_id, select: agent.user_id))

      attrs = %{
        id: effect_id,
        agent_id: agent_id,
        owner_user_id: owner_user_id,
        agent_run_id: agent_run_id,
        agent_run_step_id: agent_run_step_id,
        effect_type: to_string(effect_type),
        params: params,
        idempotency_key: idempotency_key,
        status: "pending",
        attempts: 0,
        max_attempts: 3
      }

      case %Effect{} |> Effect.changeset(attrs) |> Repo.insert() do
        {:ok, effect} -> {:ok, effect.id}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_effect_run_context}
    end
  end

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

    {count, _rows} = Repo.update_all(query, [])

    {:ok, count == 1}
  end

  @doc false
  def acknowledge_terminal_result(effect_id, agent_id)
      when is_binary(effect_id) and is_binary(agent_id) do
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

    {count, _rows} = Repo.update_all(query, [])
    {:ok, count}
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

    {count, _rows} = Repo.update_all(query, [])
    {:ok, count}
  end

  def acknowledge_terminal_results_for_run(_run_id, _agent_id),
    do: {:error, :invalid_effect_acknowledgement}

  @doc false
  def get_terminal_result(effect_id, agent_id)
      when is_binary(effect_id) and is_binary(agent_id) do
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
  end

  def get_terminal_result(_effect_id, _agent_id), do: nil

  @doc """
  Cancel active effects without treating an in-flight command as safely stopped.

  Pending work is cancelled immediately. Claimed work has no termination proof
  at this context-only boundary, so it is terminalized as ambiguous rather than
  made eligible for replay or reported as safely cancelled.
  """
  def cancel_active_for_agent(agent_id, reason \\ "agent_recovered")
      when is_binary(agent_id) and is_binary(reason) do
    with {:ok, %{overflow?: false} = cancellation} <-
           begin_cancel_active_for_agent(agent_id, reason),
         {:ok, _summary} <- finish_cancel_active_for_agent(agent_id, cancellation.claims) do
      {:ok, cancellation.count}
    else
      {:ok, %{overflow?: true}} -> {:error, :effect_cancellation_overflow}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def begin_cancel_active_for_agent(agent_id, reason)
      when is_binary(agent_id) and is_binary(reason) do
    Repo.transaction(fn ->
      {pending_count, _rows} =
        Repo.update_all(
          from(effect in Effect,
            where: effect.agent_id == ^agent_id,
            where: effect.status == "pending"
          ),
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
          ),
          set: [
            status: "cancelling",
            retry_after: nil,
            error: reason,
            updated_at: DateTime.utc_now()
          ]
        )

      claims =
        Repo.all(
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
        )

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
  def finish_cancel_active_for_agent(agent_id, expected_claims)
      when is_binary(agent_id) and is_list(expected_claims) and
             length(expected_claims) <= @max_cancellation_claims do
    # A killed task may already have crossed its external side-effect boundary.
    # Termination proof is required before the Agent may resume, but every
    # previously claimed outcome remains conservatively ambiguous. Each write
    # is fenced by its original claim generation so concurrent cancellation
    # cannot terminalize newly fenced work.
    Repo.transaction(fn ->
      ambiguous_count =
        Enum.reduce(expected_claims, 0, fn claim, count ->
          query = cancellation_claim_query(agent_id, claim)

          {updated, _rows} =
            Repo.update_all(query,
              set: [
                status: "failed",
                result: nil,
                error: "effect_outcome_ambiguous",
                result_envelope: @ambiguous_cancellation_envelope,
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

    query =
      if is_nil(claimed_by),
        do: where(query, [effect], is_nil(effect.claimed_by)),
        else: where(query, [effect], effect.claimed_by == ^claimed_by)

    if is_nil(claimed_at),
      do: where(query, [effect], is_nil(effect.claimed_at)),
      else: where(query, [effect], effect.claimed_at == ^claimed_at)
  end

  @doc """
  Check if an effect has already been executed (for idempotency).
  """
  def check_idempotency(idempotency_key) do
    case Repo.get_by(Effect, idempotency_key: idempotency_key) do
      %Effect{status: "completed", result: result} -> {:cached, result}
      %Effect{status: "failed", error: error} -> {:cached_error, error}
      _ -> :not_found
    end
  end
end
