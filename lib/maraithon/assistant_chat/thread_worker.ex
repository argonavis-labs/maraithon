defmodule Maraithon.AssistantChat.ThreadWorker do
  @moduledoc """
  Per-mobile-thread assistant runner worker.
  """

  use GenServer, restart: :temporary

  alias Maraithon.AssistantChat

  require Logger

  @registry Maraithon.AssistantChat.ThreadRegistry
  @supervisor Maraithon.AssistantChat.ThreadSupervisor

  def enqueue(%{conversation_id: conversation_id} = request) when is_binary(conversation_id) do
    if async_enabled?() do
      conversation_id
      |> ensure_worker()
      |> GenServer.cast({:run, request})

      :ok
    else
      AssistantChat.run_queued_request(request)
    end
  end

  def start_link(conversation_id) do
    GenServer.start_link(__MODULE__, conversation_id,
      name: {:via, Registry, {@registry, conversation_id}}
    )
  end

  def child_spec(conversation_id) do
    %{
      id: {__MODULE__, conversation_id},
      start: {__MODULE__, :start_link, [conversation_id]},
      restart: :temporary
    }
  end

  @impl true
  def init(conversation_id), do: {:ok, %{conversation_id: conversation_id}}

  @impl true
  def handle_cast({:run, request}, state) do
    _ = AssistantChat.run_queued_request(request)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Mobile assistant thread worker crashed",
        conversation_id: state.conversation_id,
        reason: Exception.message(error)
      )

      {:noreply, state}
  end

  defp ensure_worker(conversation_id) do
    case Registry.lookup(@registry, conversation_id) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, conversation_id}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  defp async_enabled? do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:async_enabled, true)
  end
end
