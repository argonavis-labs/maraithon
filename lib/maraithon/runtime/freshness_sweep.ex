defmodule Maraithon.Runtime.FreshnessSweep do
  @moduledoc """
  Evaluates one durable provider/account freshness partition.

  Selection, cadence, account fairness, and crash recovery live in the durable
  provider lane. Each invocation re-reads its row before changing health, so a
  renewal or sync that wins the race remains authoritative.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursor
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.Config
  alias Maraithon.SourceFreshness

  require Logger

  @default_batch_size 500
  @default_never_synced_after_hours 72

  @doc "Runs the bounded compatibility sweep synchronously."
  def run_once(opts \\ []) do
    state = state_from_opts(opts)
    run_cycle(state)
  end

  @doc "Checks one connected-account partition for stale or never-synced data."
  def run_account(account_id, opts \\ [])

  def run_account(account_id, opts) when is_integer(account_id) do
    state = state_from_opts(opts)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Repo.get(ConnectedAccount, account_id) do
      %ConnectedAccount{status: "connected"} = account ->
        outcome = flag_account(account, state, now)
        {:ok, %{outcome: to_string(outcome), account_id: account_id}}

      %ConnectedAccount{} ->
        {:ok, %{outcome: "not_connected", account_id: account_id}}

      nil ->
        {:ok, %{outcome: "missing", account_id: account_id}}
    end
  end

  def run_account(_account_id, _opts), do: {:error, :invalid_freshness_account_partition}

  @doc "Checks one source-cursor partition for an expired watch."
  def run_expired_watch(cursor_id, opts \\ [])

  def run_expired_watch(cursor_id, opts) when is_binary(cursor_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Repo.get(SourceCursor, cursor_id) do
      %SourceCursor{watch_expires_at: %DateTime{} = expires_at} = cursor ->
        if DateTime.compare(expires_at, now) == :lt do
          outcome = flag_expired_watch(cursor)
          {:ok, %{outcome: to_string(outcome), cursor_id: cursor_id}}
        else
          {:ok, %{outcome: "not_expired", cursor_id: cursor_id}}
        end

      %SourceCursor{} ->
        {:ok, %{outcome: "not_watched", cursor_id: cursor_id}}

      nil ->
        {:ok, %{outcome: "missing", cursor_id: cursor_id}}
    end
  end

  def run_expired_watch(_cursor_id, _opts),
    do: {:error, :invalid_freshness_watch_partition}

  @doc "Probes one sweep-soft-flagged Telegram account partition."
  def run_telegram_heal(account_id) when is_integer(account_id) do
    case Repo.get(ConnectedAccount, account_id) do
      %ConnectedAccount{provider: "telegram", status: "error"} = account ->
        if telegram_module().configured?() and soft_flagged?(account) do
          outcome = probe_and_heal(account)
          {:ok, %{outcome: to_string(outcome), account_id: account_id}}
        else
          {:ok, %{outcome: "not_probeable", account_id: account_id}}
        end

      %ConnectedAccount{} ->
        {:ok, %{outcome: "not_probeable", account_id: account_id}}

      nil ->
        {:ok, %{outcome: "missing", account_id: account_id}}
    end
  end

  def run_telegram_heal(_account_id), do: {:error, :invalid_telegram_heal_partition}

  defp state_from_opts(opts) do
    %{
      batch_size:
        positive_integer_opt(
          opts,
          :batch_size,
          Config.positive_integer(:freshness_sweep_batch_size, @default_batch_size)
        ),
      never_synced_after_hours:
        positive_integer_opt(
          opts,
          :never_synced_after_hours,
          Config.positive_integer(
            :freshness_sweep_never_synced_after_hours,
            @default_never_synced_after_hours
          )
        )
    }
  end

  defp run_cycle(state) do
    now = DateTime.utc_now()

    account_result = sweep_accounts(state, now)
    cursor_result = sweep_expired_watches(state, now)
    heal_result = heal_soft_flagged_telegram(state)

    %{
      checked: account_result.checked + cursor_result.checked,
      flagged: account_result.flagged + cursor_result.flagged,
      healed: heal_result.healed
    }
  end

  # Order by staleness (oldest-touched first, nulls — never refreshed — first
  # of all) instead of `desc: account.id`. With a fixed batch size and a
  # newest-first order, the same newest accounts get swept every cycle and
  # older ones never get checked at all. Real sync activity
  # (`mark_success`/`upsert_from_oauth`/etc.) bumps `last_refreshed_at`
  # forward, so a healthy account naturally rotates toward the back of the
  # queue and the worst offenders keep surfacing first.
  defp sweep_accounts(state, now) do
    ConnectedAccount
    |> where([account], account.status == "connected")
    |> order_by([account], asc_nulls_first: account.last_refreshed_at)
    |> limit(^state.batch_size)
    |> Repo.all()
    |> Enum.reduce(%{checked: 0, flagged: 0}, fn account, acc ->
      acc = %{acc | checked: acc.checked + 1}

      case flag_account(account, state, now) do
        :flagged -> %{acc | flagged: acc.flagged + 1}
        :ok -> acc
      end
    end)
  end

  defp flag_account(%ConnectedAccount{} = account, state, now) do
    snapshot = SourceFreshness.for_account(account, now: now)

    cond do
      snapshot.status == "stale" ->
        report_issue(account.user_id, account.provider, "source_stale")
        :flagged

      snapshot.status == "never_synced" and
          never_synced_overdue?(account, now, state.never_synced_after_hours) ->
        report_issue(account.user_id, account.provider, "source_stale")
        :flagged

      true ->
        :ok
    end
  rescue
    error ->
      Logger.warning("Freshness sweep failed to evaluate account",
        user_id: account.user_id,
        provider: account.provider,
        reason: Exception.message(error)
      )

      :ok
  end

  defp never_synced_overdue?(
         %ConnectedAccount{connected_at: %DateTime{} = connected_at},
         now,
         hours
       ) do
    DateTime.diff(now, connected_at, :hour) >= hours
  end

  # `connected_at` is set by every normal write path
  # (`ConnectedAccounts.upsert_from_oauth/3`, `upsert_manual/3`), so a
  # `never_synced` snapshot with a nil `connected_at` is otherwise
  # unreachable in practice; fall back to `inserted_at` (always present)
  # so a genuinely never-synced row still gets a threshold to compare
  # against instead of never being flagged.
  defp never_synced_overdue?(
         %ConnectedAccount{inserted_at: %DateTime{} = inserted_at},
         now,
         hours
       ) do
    DateTime.diff(now, inserted_at, :hour) >= hours
  end

  defp never_synced_overdue?(_account, _now, _hours), do: false

  defp sweep_expired_watches(state, now) do
    SourceCursors.expired(now, state.batch_size)
    |> Enum.reduce(%{checked: 0, flagged: 0}, fn cursor, acc ->
      acc = %{acc | checked: acc.checked + 1}

      case flag_expired_watch(cursor) do
        :flagged -> %{acc | flagged: acc.flagged + 1}
        :ok -> acc
      end
    end)
  end

  defp flag_expired_watch(%SourceCursor{user_id: user_id, provider: provider} = cursor) do
    if still_expired?(cursor) do
      report_issue(user_id, provider, "watch_expired")
      :flagged
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("Freshness sweep failed to flag expired watch",
        cursor_id: cursor.id,
        user_id: cursor.user_id,
        reason: Exception.message(error)
      )

      :ok
  end

  # Guards against a race with `Maraithon.Runtime.WatchRenewer`: the cursor
  # loaded by `sweep_expired_watches/2` may be stale by the time this runs
  # (renewal is batched, isolated, and can happen concurrently). Re-read the
  # row immediately before flagging and skip if the renewer already won the
  # race and pushed `watch_expires_at` back into the future.
  defp still_expired?(%SourceCursor{id: id}) do
    case Repo.get(SourceCursor, id) do
      %SourceCursor{watch_expires_at: %DateTime{} = watch_expires_at} ->
        DateTime.compare(watch_expires_at, DateTime.utc_now()) == :lt

      _ ->
        false
    end
  end

  defp report_issue(user_id, provider, reason) do
    ConnectedAccounts.report_access_issue(user_id, provider, reason)
  rescue
    _ -> :ok
  end

  # Undo only the sweep's own guesses: probe soft-flagged Telegram accounts
  # (see the moduledoc) and mark success when the channel answers. A probe
  # failure leaves the account exactly as it was.
  defp heal_soft_flagged_telegram(state) do
    if telegram_module().configured?() do
      ConnectedAccount
      |> where([account], account.provider == "telegram" and account.status == "error")
      |> order_by([account], asc_nulls_first: account.last_refreshed_at)
      |> limit(^state.batch_size)
      |> Repo.all()
      |> Enum.filter(&soft_flagged?/1)
      |> Enum.reduce(%{healed: 0}, fn account, acc ->
        case probe_and_heal(account) do
          :healed -> %{acc | healed: acc.healed + 1}
          :ok -> acc
        end
      end)
    else
      %{healed: 0}
    end
  end

  defp soft_flagged?(%ConnectedAccount{metadata: metadata}) do
    reason = get_in(metadata || %{}, ["last_error", "reason"])
    is_binary(reason) and reason in ConnectedAccounts.soft_reconnect_reasons()
  end

  defp probe_and_heal(%ConnectedAccount{} = account) do
    chat_id = account.external_account_id || get_in(account.metadata || %{}, ["chat_id"])

    with true <- is_binary(chat_id) and String.trim(chat_id) != "",
         {:ok, _chat} <- telegram_module().get_chat(chat_id),
         {:ok, _account} <- SourceFreshness.mark_success(account.user_id, "telegram", %{}) do
      Logger.info("Healed soft-flagged Telegram account",
        user_id: account.user_id,
        chat_id: chat_id
      )

      :healed
    else
      _ -> :ok
    end
  rescue
    error ->
      Logger.warning("Telegram self-heal probe failed",
        user_id: account.user_id,
        reason: Exception.message(error)
      )

      :ok
  end

  defp telegram_module do
    Application.get_env(:maraithon, :freshness_sweep, [])
    |> Keyword.get(:telegram_module, Maraithon.Connectors.Telegram)
  end

  defp positive_integer_opt(opts, key, default) when is_list(opts) and is_atom(key) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
