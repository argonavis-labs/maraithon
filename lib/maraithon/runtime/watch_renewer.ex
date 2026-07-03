defmodule Maraithon.Runtime.WatchRenewer do
  @moduledoc """
  Periodically re-issues Gmail/Calendar push watches before they expire.

  Google push watches are not permanent: Gmail watches last about 7 days and
  Calendar channels are created with a TTL (also up to 7 days). If nothing
  renews them, push ingestion silently stops. This mirrors
  `Maraithon.Runtime.TokenRefresher`'s shape (periodic tick, batched work,
  per-account error isolation) but walks `source_cursors` watch rows instead
  of OAuth tokens.
  """

  use GenServer

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Connectors.GoogleCalendar
  alias Maraithon.Connectors.SourceCursor
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.OAuth
  alias Maraithon.Repo
  alias Maraithon.Runtime.Config
  alias Maraithon.SourceFreshness

  require Logger

  @name __MODULE__
  @default_interval_ms :timer.minutes(30)
  @default_lookahead_seconds 24 * 60 * 60
  @default_batch_size 50
  @default_initial_delay_ms :timer.seconds(10)

  @gmail_kind "gmail_history_id"
  @calendar_kind "calendar_sync_token"

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, @name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms:
        positive_integer_opt(
          opts,
          :interval_ms,
          Config.positive_integer(:watch_renewal_interval_ms, @default_interval_ms)
        ),
      lookahead_seconds:
        positive_integer_opt(
          opts,
          :lookahead_seconds,
          Config.positive_integer(:watch_renewal_lookahead_seconds, @default_lookahead_seconds)
        ),
      batch_size:
        positive_integer_opt(
          opts,
          :batch_size,
          Config.positive_integer(:watch_renewal_batch_size, @default_batch_size)
        ),
      observer: Keyword.get(opts, :observer)
    }

    initial_delay_ms = positive_integer_opt(opts, :initial_delay_ms, @default_initial_delay_ms)
    schedule_tick(initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    result = run_cycle(state)

    if result.attempted > 0 do
      Logger.info("Watch renewal cycle",
        attempted: result.attempted,
        renewed: result.renewed,
        failed: result.failed
      )
    end

    if is_pid(state.observer) do
      send(state.observer, {:watch_renewal_cycle, result})
    end

    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Watch renewal cycle failed", reason: Exception.message(error))
      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  defp run_cycle(state) do
    SourceCursors.due_for_renewal(DateTime.utc_now(), state.lookahead_seconds, state.batch_size)
    |> Enum.reduce(%{attempted: 0, renewed: 0, failed: 0}, fn cursor, acc ->
      acc = %{acc | attempted: acc.attempted + 1}

      case renew_cursor(cursor) do
        :ok ->
          %{acc | renewed: acc.renewed + 1}

        {:error, reason} ->
          Logger.warning("Watch renewal failed",
            cursor_id: cursor.id,
            user_id: cursor.user_id,
            kind: cursor.kind,
            reason: inspect(reason)
          )

          %{acc | failed: acc.failed + 1}
      end
    end)
  end

  # Each cursor is renewed in isolation: an exception or crash here must not
  # take down the rest of the batch.
  defp renew_cursor(%SourceCursor{} = cursor) do
    do_renew(cursor)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp do_renew(%SourceCursor{connected_account_id: id, user_id: user_id, provider: provider} = cursor) do
    case Repo.get(ConnectedAccount, id) do
      nil ->
        {:error, :connected_account_not_found}

      %ConnectedAccount{} = account ->
        case OAuth.get_valid_access_token(user_id, provider) do
          {:ok, token} -> renew_watch(cursor.kind, cursor, account, user_id, token)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp renew_watch(@gmail_kind, _cursor, account, user_id, token) do
    case Gmail.setup_watch(user_id, token) do
      {:ok, watch} ->
        _ = SourceCursors.put(account, @gmail_kind, %{"watch_expires_at" => watch.expiration})

        _ =
          if watch.history_id do
            SourceCursors.ensure_value(account, @gmail_kind, to_string(watch.history_id))
          end

        # R2/R4: a successful renewal is the recovery signal for a
        # `watch_expired` flag from the freshness sweep.
        report_watch_recovery(user_id, account.provider)

        :ok

      {:error, reason} ->
        report_watch_issue(user_id, account.provider, reason)
        {:error, reason}
    end
  end

  defp renew_watch(@calendar_kind, cursor, account, user_id, token) do
    case GoogleCalendar.setup_watch(user_id, token) do
      {:ok, watch} ->
        SourceCursors.put(account, @calendar_kind, %{
          "watch_channel_id" => watch.id,
          "watch_resource_id" => watch.resource_id,
          "watch_expires_at" => watch.expiration
        })

        # `setup_watch` mints a brand new channel; the previous one (still
        # tracked on `cursor`, the row as it was before this renewal) keeps
        # delivering push notifications until its own TTL unless we stop it
        # explicitly - otherwise both channels fire, producing duplicate
        # webhook jobs (different channel_id -> different dedupe key). Best
        # effort: a failure here must not fail the renewal itself.
        stop_previous_calendar_watch(user_id, cursor, watch)

        report_watch_recovery(user_id, account.provider)

        :ok

      {:error, reason} ->
        report_watch_issue(user_id, account.provider, reason)
        {:error, reason}
    end
  end

  defp renew_watch(_kind, _cursor, _account, _user_id, _token), do: {:error, :unsupported_cursor_kind}

  defp stop_previous_calendar_watch(user_id, %SourceCursor{} = cursor, new_watch) do
    channel_id = cursor.watch_channel_id
    resource_id = cursor.watch_resource_id

    if is_binary(channel_id) and channel_id != "" and is_binary(resource_id) and
         resource_id != "" and channel_id != new_watch.id do
      case GoogleCalendar.stop_watch(user_id, channel_id, resource_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to stop previous Calendar watch channel after renewal",
            user_id: user_id,
            channel_id: channel_id,
            reason: inspect(reason)
          )

          :ok
      end
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("Failed to stop previous Calendar watch channel after renewal",
        user_id: user_id,
        reason: Exception.message(error)
      )

      :ok
  end

  defp report_watch_issue(user_id, provider, reason) do
    ConnectedAccounts.report_access_issue(user_id, provider, reason)
  rescue
    _ -> :ok
  end

  defp report_watch_recovery(user_id, provider) do
    SourceFreshness.mark_success(user_id, provider)
  rescue
    _ -> :ok
  end

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
  end

  defp positive_integer_opt(opts, key, default) when is_list(opts) and is_atom(key) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
