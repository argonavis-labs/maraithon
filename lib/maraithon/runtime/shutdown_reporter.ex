defmodule Maraithon.Runtime.ShutdownReporter do
  @moduledoc """
  Records best-effort node shutdown incidents from the supervision tree.
  """

  use GenServer

  alias Maraithon.Runtime.IncidentLog

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def terminate(reason, _state) do
    IncidentLog.record(%{
      kind: :node_shutdown,
      reason: inspect(reason),
      metadata: %{"source" => "shutdown_reporter"}
    })

    :ok
  end
end
