defmodule Maraithon.Effects do
  @moduledoc """
  Effect outbox for managing side effects.
  """

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Effects.Effect

  @max_params_bytes 160_000
  @max_param_binary_bytes 128_000
  @max_result_bytes 512_000
  @max_result_binary_bytes 256_000
  @max_tool_name_bytes 255

  @doc """
  Request an effect to be executed.
  """
  def request(agent_id, effect_type, tool_name, params, opts \\ %{}) do
    with {:ok, durable_params} <- durable_request_params(effect_type, tool_name, params) do
      request_prepared(agent_id, effect_type, tool_name, durable_params, opts)
    end
  end

  @doc false
  def request_prepared(agent_id, effect_type, tool_name, params, opts \\ %{}) do
    effect_id = opts[:effect_id] || Ecto.UUID.generate()
    idempotency_key = opts[:idempotency_key] || Ecto.UUID.generate()

    with {:ok, prepared} <- prepare_params(tool_name, params) do
      do_request(agent_id, effect_type, prepared, effect_id, idempotency_key)
    end
  end

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
       ) and encoded_within_limit?(result, @max_result_bytes) do
      {:ok, result}
    else
      {:error, :invalid_effect_result}
    end
  end

  def prepare_result(_result), do: {:error, :invalid_effect_result}

  defp do_request(agent_id, effect_type, params, effect_id, idempotency_key) do
    attrs = %{
      id: effect_id,
      agent_id: agent_id,
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
  end

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

  @doc """
  Atomically cancels active effects whose continuation belonged to an earlier
  agent process.

  Agent checkpoints are idle-only and do not persist a waiting effect's
  continuation. Recovery must therefore cancel both queued and claimed work
  before starting a new cycle. A database failure is allowed to raise so the
  agent cannot continue with an ambiguous outbox.
  """
  def cancel_active_for_agent(agent_id, reason \\ "agent_recovered")
      when is_binary(agent_id) and is_binary(reason) do
    {count, _rows} =
      Repo.update_all(
        from(effect in Effect,
          where: effect.agent_id == ^agent_id,
          where: effect.status in ["pending", "claimed"]
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

    {:ok, count}
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
