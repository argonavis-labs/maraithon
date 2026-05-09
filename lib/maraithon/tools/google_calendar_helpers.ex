defmodule Maraithon.Tools.GoogleCalendarHelpers do
  @moduledoc false

  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google

  @default_api_base "https://www.googleapis.com/calendar/v3"
  @future_sort_value 9_999_999_999_999_999

  def list_events(user_id, opts \\ []) when is_binary(user_id) do
    calendar_id = Keyword.get(opts, :calendar_id, "primary")
    max_results = Keyword.get(opts, :max_results, 25)
    query = Keyword.get(opts, :query)
    time_min = Keyword.get(opts, :time_min, DateTime.utc_now() |> DateTime.to_iso8601())
    time_max = Keyword.get(opts, :time_max)
    provider = Keyword.get(opts, :provider)

    providers =
      user_id
      |> providers_for_search(provider)
      |> Enum.uniq()

    fetch_events_from_providers(
      user_id,
      providers,
      calendar_id,
      max_results,
      query,
      time_min,
      time_max
    )
  end

  def normalize_error(:no_token), do: {:error, "google_account_not_connected"}

  def normalize_error({:http_status, status, body}),
    do: {:error, "google_calendar_api_failed: #{status} #{body}"}

  def normalize_error(reason), do: {:error, "google_calendar_tool_failed: #{inspect(reason)}"}

  defp fetch_events_from_providers(
         _user_id,
         [],
         _calendar_id,
         _max_results,
         _query,
         _time_min,
         _time_max
       ),
       do: {:error, :no_token}

  defp fetch_events_from_providers(
         user_id,
         providers,
         calendar_id,
         max_results,
         query,
         time_min,
         time_max
       ) do
    {events, errors} =
      providers
      |> Task.async_stream(
        fn provider ->
          {provider,
           fetch_events_from_provider(
             user_id,
             provider,
             calendar_id,
             max_results,
             query,
             time_min,
             time_max
           )}
        end,
        max_concurrency: provider_concurrency(providers),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.reduce({[], []}, fn
        {:ok, {_provider, {:ok, provider_events}}}, {event_acc, error_acc} ->
          {provider_events ++ event_acc, error_acc}

        {:ok, {provider, {:error, reason}}}, {event_acc, error_acc} ->
          ConnectedAccounts.report_access_issue(user_id, provider, reason)
          {event_acc, [{provider, reason} | error_acc]}

        {:exit, reason}, {event_acc, error_acc} ->
          {event_acc, [{nil, reason} | error_acc]}
      end)

    case Enum.sort_by(events, &event_sort_value/1) |> Enum.take(max_results) do
      [] ->
        case List.first(errors) do
          {_provider, reason} -> {:error, reason}
          nil -> {:ok, []}
        end

      sorted_events ->
        {:ok, sorted_events}
    end
  end

  defp fetch_events_from_provider(
         user_id,
         provider,
         calendar_id,
         max_results,
         query,
         time_min,
         time_max
       ) do
    with {:ok, access_token} <- OAuth.get_valid_access_token(user_id, provider),
         {:ok, events} <-
           fetch_events(access_token, calendar_id, max_results, query, time_min, time_max) do
      {:ok,
       Enum.map(events, fn event ->
         event
         |> Map.put(:calendar_id, calendar_id)
         |> Map.put(:google_provider, provider)
         |> Map.put(:google_account_email, provider_account_email(provider))
       end)}
    end
  end

  defp fetch_events(access_token, calendar_id, max_results, query, time_min, time_max) do
    params =
      %{}
      |> Map.put(:singleEvents, true)
      |> Map.put(:orderBy, "startTime")
      |> Map.put(:maxResults, max_results)
      |> maybe_put(:q, query)
      |> maybe_put(:timeMin, time_min)
      |> maybe_put(:timeMax, time_max)
      |> URI.encode_query()

    encoded_calendar_id = URI.encode(calendar_id)
    url = "#{api_base_url()}/calendars/#{encoded_calendar_id}/events?#{params}"

    case Google.api_request(:get, url, access_token) do
      {:ok, response} when is_map(response) ->
        {:ok, parse_events(response["items"] || [])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_events(items) when is_list(items) do
    Enum.map(items, fn item ->
      %{
        event_id: item["id"],
        summary: item["summary"],
        description: item["description"],
        location: item["location"],
        status: item["status"],
        start: parse_event_time(item["start"]),
        end: parse_event_time(item["end"]),
        attendees: parse_attendees(item["attendees"]),
        organizer: get_in(item, ["organizer", "email"]),
        html_link: item["htmlLink"],
        created: item["created"],
        updated: item["updated"]
      }
    end)
  end

  defp parse_event_time(nil), do: nil

  defp parse_event_time(%{"dateTime" => date_time}) when is_binary(date_time) do
    case DateTime.from_iso8601(date_time) do
      {:ok, datetime, _offset} -> datetime
      _ -> date_time
    end
  end

  defp parse_event_time(%{"date" => date}) when is_binary(date) do
    %{date: date, all_day: true}
  end

  defp parse_event_time(_), do: nil

  defp parse_attendees(nil), do: []

  defp parse_attendees(attendees) when is_list(attendees) do
    Enum.map(attendees, fn attendee ->
      %{
        email: attendee["email"],
        display_name: attendee["displayName"],
        response_status: attendee["responseStatus"],
        organizer: attendee["organizer"] || false,
        self: attendee["self"] || false
      }
    end)
  end

  defp providers_for_search(user_id, provider) when provider in [nil, "", "google"] do
    connected_google_providers(user_id)
    |> case do
      [] -> ["google"]
      providers -> providers
    end
  end

  defp providers_for_search(_user_id, provider) when is_binary(provider), do: [provider]
  defp providers_for_search(_user_id, _provider), do: ["google"]

  defp connected_google_providers(user_id) when is_binary(user_id) do
    account_providers =
      user_id
      |> ConnectedAccounts.list_for_user()
      |> Enum.filter(fn account ->
        account.status == "connected" and String.starts_with?(account.provider, "google:")
      end)
      |> Enum.map(& &1.provider)

    token_providers =
      user_id
      |> OAuth.list_user_tokens()
      |> Enum.map(& &1.provider)
      |> Enum.filter(&String.starts_with?(&1, "google:"))

    (account_providers ++ token_providers)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp connected_google_providers(_user_id), do: []

  defp provider_account_email("google:" <> account_email), do: account_email
  defp provider_account_email(_provider), do: nil

  defp provider_concurrency(providers), do: providers |> length() |> max(1) |> min(4)

  defp event_sort_value(%{start: %DateTime{} = start}), do: DateTime.to_unix(start, :microsecond)

  defp event_sort_value(%{start: %{date: date}}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> Date.to_gregorian_days(parsed) * 86_400_000_000
      {:error, _reason} -> @future_sort_value
    end
  end

  defp event_sort_value(_event), do: @future_sort_value

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, ""), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp api_base_url do
    Application.get_env(:maraithon, :google_calendar, [])
    |> Keyword.get(:api_base_url, @default_api_base)
  end
end
