defmodule Maraithon.Runtime.ProactiveCheckIn do
  @moduledoc """
  Durable per-user proactive-delivery work.

  Queue hygiene is performed by the recurring coordinator; model planning is
  enqueued into the dedicated fair user lane. There is no local scheduler PID.
  """

  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.DeliveryPlanner
  alias Maraithon.TelegramAssistant.ProactiveQueue

  def run_once(opts \\ []) do
    recovered = ProactiveQueue.recover_stale_planned()
    expired = expire_stale_candidates()
    planner = run_delivery_planner(opts)

    planner
    |> compatibility_summary()
    |> Map.merge(%{expired: expired, recovered: recovered, planner: planner})
  end

  @doc "Runs only the cheap global queue-recovery/expiry coordinator work."
  def run_hygiene(now \\ DateTime.utc_now()) do
    %{
      recovered: ProactiveQueue.recover_stale_planned(now),
      expired: expire_stale_candidates(now)
    }
  end

  def run_delivery_planner(opts \\ []) do
    if TelegramAssistant.proactive_delivery_planner_enabled?() do
      DeliveryPlanner.run_for_due_users(opts)
    else
      :disabled
    end
  end

  @doc "Executes one tenant partition in the dedicated model/user lane."
  def run_for_user(user_id, opts \\ [])

  def run_for_user(user_id, opts) when is_binary(user_id) do
    result =
      if TelegramAssistant.proactive_delivery_planner_enabled?() do
        DeliveryPlanner.run_for_user(user_id, opts)
      else
        {:ok, %{user_id: user_id, planned: 0, delivered: 0, held: 0, failed: 0}}
      end

    _ = ProactiveQueue.rotate_pending_user(user_id)
    result
  end

  def run_for_user(_user_id, _opts), do: {:error, :invalid_user}

  def expire_stale_candidates(now \\ DateTime.utc_now()) do
    ProactiveQueue.expire_stale(now)
  end

  defp compatibility_summary(%{} = planner) do
    %{
      sent: Map.get(planner, :delivered, 0),
      held: Map.get(planner, :held, 0),
      suppressed: 0,
      failed: Map.get(planner, :failed, 0),
      disabled: 0
    }
  end

  defp compatibility_summary(_planner) do
    %{sent: 0, held: 0, suppressed: 0, failed: 0, disabled: 0}
  end
end
