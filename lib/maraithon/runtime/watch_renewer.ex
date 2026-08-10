defmodule Maraithon.Runtime.WatchRenewer do
  @moduledoc """
  Renews one durably partitioned Gmail or Calendar watch.

  The provider lane owns cadence, crash recovery, account serialization, and
  provider cooldown. This module deliberately has no GenServer or timer.
  """

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

  @default_lookahead_seconds 24 * 60 * 60
  @default_batch_size 50
  @gmail_kind "gmail_history_id"
  @calendar_kind "calendar_sync_token"

  @doc "Runs the bounded compatibility sweep synchronously."
  def run_once(opts \\ []) do
    state = %{
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
        )
    }

    run_cycle(state)
  end

  @doc "Executes one durable source-cursor partition."
  def run_cursor(cursor_id, opts \\ [])

  def run_cursor(cursor_id, opts) when is_binary(cursor_id) do
    lookahead_seconds =
      positive_integer_opt(
        opts,
        :lookahead_seconds,
        Config.positive_integer(:watch_renewal_lookahead_seconds, @default_lookahead_seconds)
      )

    case Repo.get(SourceCursor, cursor_id) do
      nil ->
        {:ok, %{outcome: "missing", cursor_id: cursor_id}}

      %SourceCursor{watch_expires_at: %DateTime{} = expires_at} = cursor ->
        now = Keyword.get(opts, :now, DateTime.utc_now())
        cutoff = DateTime.add(now, lookahead_seconds, :second)

        if DateTime.compare(expires_at, cutoff) in [:lt, :eq] do
          case renew_cursor(cursor) do
            :ok -> {:ok, %{outcome: "renewed", kind: cursor.kind}}
            {:error, _reason} = error -> error
          end
        else
          {:ok, %{outcome: "not_due", kind: cursor.kind}}
        end

      %SourceCursor{} = cursor ->
        {:ok, %{outcome: "not_watched", kind: cursor.kind}}
    end
  end

  def run_cursor(_cursor_id, _opts), do: {:error, :invalid_watch_partition}

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

  defp do_renew(
         %SourceCursor{connected_account_id: id, user_id: user_id, provider: provider} = cursor
       ) do
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

  defp renew_watch(_kind, _cursor, _account, _user_id, _token),
    do: {:error, :unsupported_cursor_kind}

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

  defp positive_integer_opt(opts, key, default) when is_list(opts) and is_atom(key) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
