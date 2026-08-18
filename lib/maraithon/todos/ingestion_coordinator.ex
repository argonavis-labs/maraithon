defmodule Maraithon.Todos.IngestionCoordinator do
  @moduledoc """
  Single-node OTP coordinator for durable connector observations.

  CRM windows and canonical Todos remain PostgreSQL-authoritative. When the
  multinode runtime is intentionally disabled, this worker supplies the small
  missing execution bridge: it flushes low-volume windows after a short
  debounce and processes flushed windows under bounded supervised Tasks. It
  becomes dormant before multinode coordination is enabled so there is never a
  mixed ownership mode.
  """

  use GenServer

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Crm.Ingest
  alias Maraithon.Crm.Ingest.Window
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobHandler
  alias Maraithon.Runtime.Config

  require Logger

  @poll_interval_ms 10_000
  @window_debounce_seconds 120
  @provider_sync_interval_ms 10 * 60 * 1_000
  @provider_batch_size 25
  @batch_size 10
  @max_concurrency 2

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    enabled? = Application.get_env(:maraithon, :start_background_workers, true)
    if enabled?, do: send(self(), :poll)

    {:ok,
     %{
       task: nil,
       enabled?: enabled?,
       next_provider_sync_at_ms: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_info(:poll, %{enabled?: false} = state), do: {:noreply, state}

  def handle_info(:poll, %{task: nil} = state) do
    schedule_poll()

    if Config.multinode_coordination_enabled?() do
      {:noreply, state}
    else
      now_ms = System.monotonic_time(:millisecond)
      sync_providers? = now_ms >= state.next_provider_sync_at_ms

      task =
        Task.Supervisor.async_nolink(Maraithon.Todos.IngestionTaskSupervisor, fn ->
          run_cycle(sync_providers?)
        end)

      next_provider_sync_at_ms =
        if sync_providers?,
          do: now_ms + @provider_sync_interval_ms,
          else: state.next_provider_sync_at_ms

      {:noreply, %{state | task: task, next_provider_sync_at_ms: next_provider_sync_at_ms}}
    end
  end

  def handle_info(:poll, state) do
    schedule_poll()
    {:noreply, state}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    log_result(result)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("Todo ingestion coordinator cycle crashed", reason: inspect(reason))
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run_cycle(sync_providers?) do
    provider_summary =
      if sync_providers?, do: sync_gmail_accounts(), else: %{checked: 0, completed: 0}

    {:ok, flushed_count} =
      Ingest.sweep_windows_older_than(DateTime.utc_now(), @window_debounce_seconds)

    window_ids =
      from(window in Window,
        where: window.status == "flushed",
        order_by: [asc: window.flushed_at, asc: window.id],
        limit: @batch_size,
        select: window.id
      )
      |> Repo.all()

    results =
      window_ids
      |> Task.async_stream(&BackgroundJobHandler.process_ingestion_window/1,
        max_concurrency: @max_concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.to_list()

    %{
      flushed: flushed_count,
      selected: length(window_ids),
      completed: Enum.count(results, &completed?/1),
      failed: Enum.count(results, &(not completed?(&1))),
      provider_accounts_checked: provider_summary.checked,
      provider_syncs_completed: provider_summary.completed
    }
  end

  defp sync_gmail_accounts do
    accounts =
      from(account in ConnectedAccount,
        where: account.status == "connected",
        where: account.provider == "google" or like(account.provider, "google:%"),
        order_by: [asc: account.last_refreshed_at, asc: account.id],
        limit: @provider_batch_size
      )
      |> Repo.all()
      |> Enum.filter(&Gmail.enabled_for_account?/1)

    results =
      accounts
      |> Task.async_stream(
        fn account ->
          Gmail.sync_history(account.user_id, account, provider: account.provider)
        end,
        max_concurrency: @max_concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.to_list()

    %{
      checked: length(accounts),
      completed: Enum.count(results, fn result -> match?({:ok, {:ok, _summary}}, result) end)
    }
  end

  defp completed?({:ok, {:ok, _result}}), do: true
  defp completed?(_result), do: false

  defp log_result(%{flushed: 0, selected: 0, provider_accounts_checked: 0}), do: :ok

  defp log_result(summary) when is_map(summary) do
    Logger.info("Todo ingestion coordinator completed a bounded cycle", summary)
  end

  defp log_result(other) do
    Logger.warning("Todo ingestion coordinator returned an unexpected result",
      result: inspect(other)
    )
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end
end
