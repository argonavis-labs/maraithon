defmodule Maraithon.Effects do
  @moduledoc """
  Effect outbox for managing side effects.
  """

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Effects.Effect

  @doc """
  Request an effect to be executed.
  """
  def request(agent_id, effect_type, tool_name, params, opts \\ %{}) do
    effect_id = opts[:effect_id] || Ecto.UUID.generate()
    idempotency_key = opts[:idempotency_key] || Ecto.UUID.generate()

    params =
      if tool_name do
        Map.put(params, "tool", tool_name)
      else
        params
      end

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
