defmodule Maraithon.Crm.Ingest.Seed do
  @moduledoc """
  One-shot historical CRM ingestion for a user.

  Drives the existing connector adapters (Gmail, Google Calendar) over a
  bounded historical window so a freshly-deployed install can build up a CRM
  snapshot without waiting for natural webhook traffic to fill it in.

  Live webhook ingestion stays the steady-state path; this module is the
  back-loader. Each fetched item flows through `Crm.Ingest.observe/2` so
  dedupe, counter bumps, and window flushing all behave identically to the
  steady-state path.
  """

  alias Maraithon.Connectors.Gmail
  alias Maraithon.Connectors.GoogleCalendar
  alias Maraithon.Crm.Ingest

  require Logger

  @default_days 90
  @default_gmail_max 500

  @type result :: %{
          user_id: String.t(),
          days: pos_integer(),
          gmail: map(),
          calendar: map()
        }

  @doc """
  Ingest the last `days` of Gmail and Google Calendar history for the user.

  Options:

    * `:days` — historical window in days (default `90`).
    * `:gmail_max` — max Gmail messages to fetch (default `500`). Gmail's
      list API caps a single page at ~500.
    * `:dry_run?` — when true, fetches but does not call `Ingest.observe/2`.
  """
  @spec run_for_user(String.t(), keyword()) :: result()
  def run_for_user(user_id, opts \\ []) when is_binary(user_id) do
    days = Keyword.get(opts, :days, @default_days)
    gmail_max = Keyword.get(opts, :gmail_max, @default_gmail_max)
    dry_run? = Keyword.get(opts, :dry_run?, false)

    Logger.info("CRM ingest seed starting",
      user_id: user_id,
      days: days,
      gmail_max: gmail_max,
      dry_run: dry_run?
    )

    gmail = backfill_gmail(user_id, days, gmail_max, dry_run?)
    calendar = backfill_calendar(user_id, days, dry_run?)

    %{user_id: user_id, days: days, gmail: gmail, calendar: calendar}
  end

  defp backfill_gmail(user_id, days, gmail_max, dry_run?) do
    after_date =
      Date.utc_today()
      |> Date.add(-days)
      |> Date.to_iso8601()
      |> String.replace("-", "/")

    case Gmail.fetch_messages(user_id, max_results: gmail_max, query: "after:#{after_date}") do
      {:ok, messages} when is_list(messages) ->
        if dry_run? do
          %{status: "dry_run", fetched: length(messages)}
        else
          Gmail.ingest_messages(user_id, messages)

          case Ingest.flush_pending(user_id, "gmail") do
            {:ok, status} -> %{status: "ok", fetched: length(messages), flush: status}
            other -> %{status: "ok", fetched: length(messages), flush: inspect(other)}
          end
        end

      {:error, reason} ->
        Logger.warning("CRM ingest seed could not fetch Gmail",
          user_id: user_id,
          reason: inspect(reason)
        )

        %{status: "error", reason: inspect(reason)}
    end
  end

  defp backfill_calendar(user_id, days, dry_run?) do
    now = DateTime.utc_now()
    time_min = DateTime.add(now, -days * 24 * 3_600, :second) |> DateTime.to_iso8601()
    time_max = DateTime.add(now, 30 * 24 * 3_600, :second) |> DateTime.to_iso8601()

    if dry_run? do
      %{status: "dry_run", fetched: nil}
    else
      case GoogleCalendar.sync_calendar_events(user_id, time_min: time_min, time_max: time_max) do
        {:ok, events} when is_list(events) ->
          # sync_calendar_events already calls ingest_events + flush_pending.
          %{status: "ok", fetched: length(events)}

        {:error, reason} ->
          Logger.warning("CRM ingest seed could not fetch Calendar",
            user_id: user_id,
            reason: inspect(reason)
          )

          %{status: "error", reason: inspect(reason)}
      end
    end
  end
end
