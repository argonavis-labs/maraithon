defmodule Maraithon.Runtime.EffectTaskSupervisor do
  @moduledoc """
  Couples exact Effect task identity to Task.Supervisor lifetime.

  Registry, authority, Task.Supervisor, and renewer use `:one_for_all` coupling.
  Any child failure therefore terminates every exact Effect task before a fresh
  authority identity can prove predecessor-supervisor absence. Registry contents
  alone are never absence proof.
  """

  use Supervisor

  alias Maraithon.Runtime.EffectTaskAuthority

  @registry Maraithon.Runtime.EffectTaskRegistry
  @task_supervisor Maraithon.Runtime.ExactEffectTaskSupervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reserve(effect_id, agent_id, claim_token) do
    with {:ok, effect_id} <- cast_uuid(effect_id),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, claim_token} <- cast_uuid(claim_token) do
      EffectTaskAuthority.reserve(effect_id, agent_id, claim_token)
    end
  catch
    :exit, _reason -> {:error, :effect_task_supervisor_unavailable}
  end

  def release(identity) when is_map(identity) do
    EffectTaskAuthority.release(identity)
  catch
    :exit, _reason -> {:error, :effect_task_supervisor_unavailable}
  end

  def register_current!(identity) when is_map(identity) do
    key = registry_key(identity)

    {:ok, _owner} =
      Registry.register(@registry, key, %{
        agent_id: identity.agent_id,
        effect_id: identity.effect_id,
        claim_token: identity.claim_token,
        supervisor_id: identity.supervisor_id,
        task_id: identity.task_id
      })

    :ok = EffectTaskAuthority.activate(identity)
    :ok
  end

  def terminate_exact(claim) when is_map(claim) do
    EffectTaskAuthority.terminate_exact(claim)
  catch
    :exit, _reason -> {:unknown, :effect_task_supervisor_unavailable}
  end

  def identity do
    EffectTaskAuthority.identity()
  catch
    :exit, _reason -> {:error, :effect_task_supervisor_unavailable}
  end

  def active_identities do
    EffectTaskAuthority.active_identities()
  catch
    :exit, _reason -> {:error, :effect_task_supervisor_unavailable}
  end

  def registry_key(identity) do
    {
      identity.effect_id,
      identity.claim_token,
      identity.supervisor_id,
      identity.task_id
    }
  end

  @impl true
  def init(_opts) do
    children = [
      {Maraithon.Runtime.EffectTaskRegistry, []},
      {EffectTaskAuthority, []},
      {Task.Supervisor, name: @task_supervisor},
      Maraithon.Runtime.EffectClaimRenewer
    ]

    Supervisor.init(children,
      strategy: :one_for_all,
      max_restarts: 20,
      max_seconds: 60
    )
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_effect_task_identity}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_effect_task_identity}
end
