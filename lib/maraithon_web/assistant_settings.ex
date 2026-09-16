defmodule MaraithonWeb.AssistantSettings do
  @moduledoc "Shared, credential-free assistant settings for web and native clients."
  import Ecto.Query
  alias Maraithon.{AssistantIdentities, CalendarLinks, OAuth, Repo, SourceLabels}
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Delegations.{Gates, Preferences}

  def load(user_id, params \\ %{}) do
    if Gates.enabled?(user_id) do
      identity = AssistantIdentities.get(user_id)

      accounts =
        from(a in ConnectedAccount,
          where:
            a.user_id == ^user_id and a.status == "connected" and
              (a.provider == "google" or like(a.provider, "google:%")),
          select: map(a, [:id, :provider, :external_account_id, :metadata, :scopes])
        )
        |> Repo.all()
        |> Enum.map(
          &%{
            id: &1.id,
            label: SourceLabels.account(&1),
            can_send: OAuth.gmail_send_scopes?(&1.scopes)
          }
        )

      selected =
        integer(params["assistant_account"]) || (identity && identity.gmail_connected_account_id)

      selected = if Enum.any?(accounts, &(&1.id == selected)), do: selected
      account = Enum.find(accounts, &(&1.id == selected))

      permission_error =
        if account && not account.can_send,
          do: MaraithonWeb.DelegationCopy.error(:gmail_sending_permission_required)

      {aliases, error} =
        if selected do
          case AssistantIdentities.send_as(user_id, selected) do
            {:ok, aliases} ->
              {Enum.map(aliases, &%{email: &1["sendAsEmail"], primary: &1["isPrimary"] == true}),
               permission_error}

            {:error, reason} ->
              {[], MaraithonWeb.DelegationCopy.error(reason)}
          end
        else
          {[], nil}
        end

      data = if identity, do: Map.drop(identity.data, ["_bound"]), else: %{"disclose_ai" => true}
      preferences = Preferences.get(user_id)

      calendars =
        Enum.map(
          Preferences.calendar_accounts(user_id),
          &%{id: &1.id, label: SourceLabels.account(&1)}
        )

      unavailable = Preferences.calendar_ids(preferences) -- Enum.map(calendars, & &1.id)

      links =
        Enum.map(
          CalendarLinks.list_active_links(user_id),
          &%{id: &1.id, label: "#{CalendarLinks.display_label(&1)} (#{&1.duration_minutes} min)"}
        )

      selected_link = preferences["calendar_link_id"]

      links =
        if selected_link not in [nil, ""] and not Enum.any?(links, &(&1.id == selected_link)),
          do: links ++ [%{id: selected_link, label: "Unavailable booking link"}],
          else: links

      %{
        enabled: true,
        accounts: accounts,
        calendar_accounts:
          calendars ++ Enum.map(unavailable, &%{id: &1, label: "Unavailable account"}),
        booking_links: links,
        selected_account: selected,
        aliases: aliases,
        error: error,
        identity: Map.put(data, "gmail_mode", (identity && identity.gmail_mode) || "account"),
        preferences: preferences,
        timezones: Maraithon.Timezones.options(),
        numeric_preferences:
          Enum.map(numeric_preferences(), fn {key, label, min, max} ->
            %{key: key, label: label, min: min, max: max}
          end)
      }
    else
      %{enabled: false}
    end
  end

  def save_identity(user_id, attrs) do
    if Gates.enabled?(user_id) do
      attrs =
        attrs
        |> Map.put("gmail_connected_account_id", integer(attrs["gmail_connected_account_id"]))
        |> Map.put("disclose_ai", truthy?(attrs["disclose_ai"]))
        |> Map.put("cc_user_on_first_send", truthy?(attrs["cc_user_on_first_send"]))

      AssistantIdentities.configure(user_id, attrs)
    else
      {:error, :delegations_disabled}
    end
  end

  def save_preferences(user_id, attrs) do
    if Gates.enabled?(user_id) do
      defaults = Preferences.defaults()

      values =
        Map.new(Map.take(attrs, Map.keys(defaults)), fn {key, value} ->
          default = defaults[key]

          normalized =
            cond do
              key == "booking_calendar_account_id" ->
                if value in [nil, ""], do: nil, else: integer(value) || value

              key == "calendar_link_id" and value in [nil, ""] ->
                nil

              is_integer(default) ->
                integer(value)

              is_boolean(default) ->
                truthy?(value)

              is_list(default) and is_list(value) ->
                value |> Enum.reject(&(&1 == "")) |> Enum.map(&integer/1)

              true ->
                value
            end

          {key, normalized}
        end)

      Preferences.put(user_id, values)
    else
      {:error, :delegations_disabled}
    end
  end

  def numeric_preferences,
    do: [
      {"default_duration_min", "Meeting length (minutes)", 5, 240},
      {"buffer_min", "Meeting buffer (minutes)", 0, 120},
      {"lead_time_hours", "Scheduling notice (hours)", 0, 720},
      {"max_meetings_per_day", "Meetings per day", 1, 24},
      {"as_user_undo_seconds", "Undo window as me (seconds)", 0, 3600},
      {"as_assistant_undo_seconds", "Undo window as assistant (seconds)", 0, 3600},
      {"follow_up_business_days", "Working days between follow-ups", 1, 180},
      {"reminders_per_cycle", "Reminders before waiting", 0, 10}
    ]

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil
  defp truthy?(value), do: value in [true, "true", "on", "1"]
end
