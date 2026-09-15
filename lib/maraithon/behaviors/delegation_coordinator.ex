defmodule Maraithon.Behaviors.DelegationCoordinator do
  @moduledoc "A small OTP coordinator for all of one user's durable conversations."
  @behaviour Maraithon.Behaviors.Behavior
  alias Maraithon.Delegations.Coordinator

  @impl true
  def init(_), do: %{"version" => 1, "work_cursor" => 0, "next_wake_at" => nil}
  @impl true
  def schema_version, do: 1
  @impl true
  def snapshot_state(state), do: Map.take(state, ~w(version work_cursor next_wake_at))
  @impl true
  def migrate_state(version, state, _), do: Map.put(state, "version", version)
  @impl true
  def reconcile_restored_state(state, _), do: snapshot_state(state)

  @impl true
  def handle_wakeup(%{"version" => 1} = state, %{write: write} = context) do
    case write.(fn now -> Coordinator.drain(context.user_id, context.agent_id, now, limit: 25) end) do
      {:ok, result} ->
        Enum.each(result.changed, fn id ->
          case Maraithon.Delegations.get(context.user_id, id) do
            nil -> :ok
            delegation -> Maraithon.Delegations.changed(delegation)
          end
        end)

        next = %{
          state
          | "work_cursor" => result.cursor,
            "next_wake_at" => DateTime.to_iso8601(result.next_wake)
        }

        {if(result.more?, do: :continue, else: :idle), next}

      {:error, _lost_authority} ->
        {:idle, state}
    end
  end

  def handle_wakeup(state, _), do: {:idle, state}

  @impl true
  def handle_effect_result(_, state, _), do: {:idle, state}

  @impl true
  def next_wakeup(%{"version" => 1, "next_wake_at" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> {:absolute, dt}
      _ -> :none
    end
  end

  def next_wakeup(%{"version" => 1}), do: {:relative, :timer.hours(6)}
  def next_wakeup(_), do: :none
end
