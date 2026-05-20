defmodule Maraithon.Runtime.AgentSupervisor do
  @moduledoc """
  Dynamic supervisor for agent processes.
  """

  alias Maraithon.Runtime.Agent

  @doc """
  Start an agent process under the supervisor.
  """
  def start_agent(agent) do
    spec = {Agent, agent}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Stop an agent process.
  """
  def stop_agent(pid, reason \\ "manual_stop")

  def stop_agent(pid, reason) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      send(pid, {:agent_dispatch, {:control, :stop, reason}})

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          :ok
      after
        5_000 ->
          Process.demonitor(ref, [:flush])
          DynamicSupervisor.terminate_child(__MODULE__, pid)
      end
    else
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
