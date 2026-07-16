defmodule Maraithon.Runtime.FreshnessSweep do
  @moduledoc """
  Periodically detects silently-dead sources and flags them proactively
  (SPEC 10 R2).

  `Maraithon.SourceFreshness.mark_error/4` (and the active failure sites
  that call `Maraithon.ConnectedAccounts.report_access_issue/3`) only fire
  when something actively fails. If a source just stops delivering — an
  expired push watch, a cron that silently stopped running — nothing
  notices. This mirrors `Maraithon.Runtime.TokenRefresher` and
  `Maraithon.Runtime.WatchRenewer`'s shape (periodic tick, batched work,
  per-account error isolation) but walks connected accounts and source
  cursors looking for staleness instead of doing the sync/renewal work
  itself.

  Three conditions are flagged, each routed through
  `ConnectedAccounts.report_access_issue/3` (which itself no-ops for
  reasons it doesn't recognize as terminal, and is naturally idempotent
  via the existing per-channel/reason reconnect-notification tracking):

    * `stale` — `SourceFreshness.for_account/2` already computes a
      provider-appropriate staleness threshold; report as `source_stale`.
    * `never_synced` — only report as `source_stale` once the account has
      been connected for longer than `never_synced_after_hours` (a fresh
      connection is expected to be `never_synced` for a little while;
      only a connection that's stayed that way is worth flagging).
    * `watch_expired` — a `source_cursors` row whose `watch_expires_at` is
      already in the past. `Maraithon.Runtime.WatchRenewer` renews watches
      well before they expire (default 24h lookahead); an already-expired
      watch means renewal attempts have been failing. The sweep flags,
      `WatchRenewer` renews — this module never calls the Google APIs.

  The sweep also *un-flags*: a Telegram account it soft-flagged
  (`source_stale`/`watch_expired`) is probed with `getChat` each cycle and
  marked successful when the channel answers. Without this, a soft flag is
  self-sustaining — error status filters the account out of every outbound
  path, so no traffic can ever prove it alive again, and briefings stay
  dead until the user happens to message the bot (prod 2026-07-16: six
  silent days). Hard failures (send rejected, bot blocked) are never
  soft-flagged and are left alone.
  """

  use GenServer

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursor
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.Config
  alias Maraithon.SourceFreshness

  require Logger

  @name __MODULE__
  @default_interval_ms :timer.hours(1)
  @default_batch_size 500
  @default_initial_delay_ms :timer.seconds(15)
  # Roomier than the per-provider stale thresholds (SourceFreshness) so a
  # still-onboarding backfill on a slower provider isn't flagged as broken
  # while its first sync is legitimately still running.
  @default_never_synced_after_hours 72

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
          Config.positive_integer(:freshness_sweep_interval_ms, @default_interval_ms)
        ),
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

    if result.checked > 0 or result.flagged > 0 or result.healed > 0 do
      Logger.info("Source freshness sweep cycle",
        checked: result.checked,
        flagged: result.flagged,
        healed: result.healed
      )
    end

    if is_pid(state.observer) do
      send(state.observer, {:freshness_sweep_cycle, result})
    end

    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Source freshness sweep cycle failed", reason: Exception.message(error))
      schedule_tick(state.interval_ms)
      {:noreply, state}
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
