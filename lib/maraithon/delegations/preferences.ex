defmodule Maraithon.Delegations.Preferences do
  @moduledoc "Shared scheduling, actor, and rolling-budget defaults."
  import Ecto.Query
  alias Maraithon.{AssistantIdentities, BriefingSchedules, Repo, Timezones}
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Delegations.{Preference, SlotRanking}
  alias Maraithon.PrivacyErasure.WriteFence

  @defaults %{
    "timezone" => "America/Toronto",
    "work_days" => [1, 2, 3, 4, 5],
    "work_start" => "08:00",
    "work_end" => "18:00",
    "time_preference" => "any",
    "day_preference" => "earliest",
    "default_duration_min" => 30,
    "buffer_min" => 15,
    "lead_time_hours" => 24,
    "max_meetings_per_day" => 6,
    "calendar_account_ids" => [],
    "booking_calendar_account_id" => nil,
    "video_link" => nil,
    "calendar_link_id" => nil,
    "as_user_undo_seconds" => 120,
    "as_assistant_undo_seconds" => 0,
    "sends_per_7d" => 6,
    "reminders_per_cycle" => 2,
    "model_calls_per_turn" => 3,
    "micro_usd_per_30d" => 250_000,
    "user_micro_usd_per_day" => 1_000_000,
    "follow_up_business_days" => 3,
    "proposals_enabled" => true
  }
  @ranges %{
    "default_duration_min" => 5..240,
    "buffer_min" => 0..120,
    "lead_time_hours" => 0..720,
    "max_meetings_per_day" => 1..24,
    "as_user_undo_seconds" => 0..3600,
    "as_assistant_undo_seconds" => 0..3600,
    "sends_per_7d" => 1..100,
    "reminders_per_cycle" => 0..10,
    "model_calls_per_turn" => 1..10,
    "micro_usd_per_30d" => 1..100_000_000,
    "user_micro_usd_per_day" => 1..100_000_000,
    "follow_up_business_days" => 1..180
  }

  def defaults, do: @defaults

  def get(user_id) do
    case Repo.get_by(Preference, user_id: user_id) |> Preference.hydrate() do
      nil -> Map.put(@defaults, "timezone", user_timezone(user_id))
      row -> stored_preferences(row.data || %{})
    end
  end

  def put(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    Repo.transaction(fn ->
      Maraithon.DurablePayload.require_current_mutation!()
      WriteFence.lock_user_writable!(user_id)
      row = Repo.get_by(Preference, user_id: user_id) |> Preference.hydrate()

      data =
        Map.merge(
          stored_preferences((row && row.data) || %{}),
          Map.take(attrs, Map.keys(@defaults))
        )

      with :ok <- validate(data),
           true <-
             owned_calendars?(user_id, calendar_ids(data)) and
               owned_link?(user_id, data["calendar_link_id"]) do
        (row || %Preference{user_id: user_id})
        |> Preference.changeset(%{data: data})
        |> Repo.insert_or_update!()
      else
        false -> Repo.rollback(:invalid_calendar_accounts)
        error -> Repo.rollback(error)
      end
    end)
  end

  def calendar_accounts(user_id) do
    assistant_ids = AssistantIdentities.assistant_account_ids(user_id)

    Repo.all(
      from a in ConnectedAccount,
        where: a.user_id == ^user_id and a.status == "connected" and a.id not in ^assistant_ids,
        where: a.provider == "google" or like(a.provider, "google:%"),
        order_by: [asc: fragment("? <> 'google'", a.provider), asc: a.id]
    )
  end

  def calendar_ids(prefs),
    do:
      Enum.uniq(List.wrap(prefs["booking_calendar_account_id"]) ++ prefs["calendar_account_ids"])

  defp owned_calendars?(_, []), do: true

  defp owned_calendars?(user_id, ids) do
    available = MapSet.new(calendar_accounts(user_id), & &1.id)
    Enum.all?(ids, &MapSet.member?(available, &1))
  end

  # Before an explicit booking setting existed, the first selected account organized invites.
  defp stored_preferences(data) do
    data =
      Map.put_new(
        data,
        "booking_calendar_account_id",
        List.first(data["calendar_account_ids"] || [])
      )

    Map.merge(@defaults, Map.take(data, Map.keys(@defaults)))
  end

  defp owned_link?(_, id) when id in [nil, ""], do: true

  defp owned_link?(user_id, id) do
    match?({:ok, _}, Ecto.UUID.cast(id)) and
      Repo.exists?(
        from l in Maraithon.CalendarLinks.CalendarLink,
          where: l.id == ^id and l.user_id == ^user_id
      )
  end

  def validate(data) do
    cond do
      not Enum.all?(@ranges, fn {key, range} -> is_integer(data[key]) and data[key] in range end) ->
        :invalid_limits

      data["timezone"] not in Enum.map(Timezones.options(), & &1.value) ->
        :invalid_timezone

      not valid_days?(data["work_days"]) ->
        :invalid_work_days

      not valid_hours?(data["work_start"], data["work_end"]) ->
        :invalid_work_hours

      not SlotRanking.valid?(data) ->
        :invalid_slot_preferences

      not is_boolean(data["proposals_enabled"]) ->
        :invalid_proposals_setting

      not valid_accounts?(data["calendar_account_ids"]) or
        not (is_nil(data["booking_calendar_account_id"]) or
                 (is_integer(data["booking_calendar_account_id"]) and
                    data["booking_calendar_account_id"] > 0)) or
          length(calendar_ids(data)) > 10 ->
        :invalid_calendar_accounts

      not valid_link?(data["video_link"]) ->
        :invalid_video_link

      data["calendar_link_id"] != nil and not is_binary(data["calendar_link_id"]) ->
        :invalid_calendar_link

      true ->
        :ok
    end
  end

  def local_time(now, prefs) do
    zone = prefs["timezone"]
    fallback = Timezones.config_updates(zone)["timezone_offset_hours"] || 0
    DateTime.add(now, Timezones.offset_at(zone, now, fallback), :hour)
  end

  def next_work_time(now, prefs) do
    local = local_time(now, prefs)
    {:ok, start} = Time.from_iso8601(prefs["work_start"] <> ":00")
    {:ok, finish} = Time.from_iso8601(prefs["work_end"] <> ":00")
    time = DateTime.to_time(local)

    cond do
      Date.day_of_week(local) not in prefs["work_days"] -> next_day(now, prefs)
      Time.compare(time, start) == :lt -> from_local(DateTime.to_date(local), start, prefs)
      Time.compare(time, finish) != :lt -> next_day(now, prefs)
      true -> now
    end
  end

  def follow_up_at(now, prefs) do
    local = local_time(now, prefs)

    date =
      advance_days(DateTime.to_date(local), prefs["follow_up_business_days"], prefs["work_days"])

    from_local(date, DateTime.to_time(local), prefs) |> next_work_time(prefs)
  end

  def from_local(date, time, prefs) do
    local = DateTime.new!(date, time, "Etc/UTC")
    zone = prefs["timezone"]
    fallback = Timezones.config_updates(zone)["timezone_offset_hours"] || 0
    DateTime.add(local, -Timezones.offset_for_local(zone, local, fallback), :hour)
  end

  defp next_day(now, prefs) do
    date = local_time(now, prefs) |> DateTime.to_date() |> Date.add(1)
    from_local(date, ~T[00:00:00], prefs) |> next_work_time(prefs)
  end

  defp advance_days(date, 0, _days), do: date

  defp advance_days(date, n, days) do
    next = Date.add(date, 1)
    advance_days(next, n - if(Date.day_of_week(next) in days, do: 1, else: 0), days)
  end

  defp valid_days?(days), do: is_list(days) and days != [] and Enum.all?(days, &(&1 in 1..7))

  defp valid_accounts?(ids),
    do: is_list(ids) and length(ids) <= 10 and Enum.all?(ids, &(is_integer(&1) and &1 > 0))

  defp valid_link?(nil), do: true
  defp valid_link?(""), do: true

  defp valid_link?(value) when is_binary(value),
    do:
      byte_size(value) <= 500 and
        match?(%URI{scheme: "https", host: host} when is_binary(host), URI.parse(value))

  defp valid_link?(_), do: false

  defp valid_hours?(start, finish) when is_binary(start) and is_binary(finish) do
    with {:ok, a} <- Time.from_iso8601(start <> ":00"),
         {:ok, b} <- Time.from_iso8601(finish <> ":00") do
      Time.compare(a, b) == :lt
    else
      _ -> false
    end
  end

  defp valid_hours?(_, _), do: false

  defp user_timezone(user_id) do
    case BriefingSchedules.summarize_for_prompt(user_id) do
      %{timezone_name: zone} -> Timezones.normalize(zone) || @defaults["timezone"]
      _ -> @defaults["timezone"]
    end
  end
end
