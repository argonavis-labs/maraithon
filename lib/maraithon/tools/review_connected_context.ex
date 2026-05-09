defmodule Maraithon.Tools.ReviewConnectedContext do
  @moduledoc """
  First-class connected-source review primitive for the assistant.

  This tool gathers source evidence quickly. The model still decides what the
  evidence means, whether to learn CRM context, and what to tell the user.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Crm
  alias Maraithon.Memory
  alias Maraithon.OAuth
  alias Maraithon.OpenLoops

  alias Maraithon.Tools.{
    GmailHelpers,
    GoogleCalendarHelpers,
    GoogleContactsSearch,
    SlackSearchMessages
  }

  @default_limit 5
  @max_limit 12
  @body_excerpt_limit 1_600

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      query = optional_string(args, "query") || optional_string(args, "person") || ""
      limit = args |> optional_integer("max_results") |> normalize_limit()
      sources = requested_sources(args)

      {results, errors} =
        sources
        |> Task.async_stream(
          fn source -> {source, review_source(source, user_id, query, limit, args)} end,
          max_concurrency: min(length(sources), 5),
          ordered: true,
          timeout: 25_000
        )
        |> Enum.reduce({%{}, []}, fn
          {:ok, {source, {:ok, result}}}, {results, errors} ->
            {Map.put(results, source, result), errors}

          {:ok, {source, {:error, reason}}}, {results, errors} ->
            {Map.put(results, source, empty_source(source)),
             [
               %{source: source, reason: normalize_error(reason)} | errors
             ]}

          {:exit, reason}, {results, errors} ->
            {results, [%{source: "unknown", reason: inspect(reason)} | errors]}
        end)

      {:ok,
       %{
         source: "connected_context",
         query: empty_to_nil(query),
         reviewed_sources: Map.keys(results),
         results: results,
         source_observations: source_observations(results),
         errors: Enum.reverse(errors)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp review_source("crm", user_id, query, limit, _args) do
    people =
      user_id
      |> Crm.list_people(query: empty_to_nil(query), limit: limit)
      |> Enum.map(&Crm.serialize_for_prompt/1)

    {:ok, %{count: length(people), people: people}}
  end

  defp review_source("gmail", user_id, query, limit, args) do
    gmail_query = optional_string(args, "gmail_query") || default_gmail_query(query, args)

    case GmailHelpers.list_messages(user_id,
           query: gmail_query,
           max_results: limit,
           label_ids: []
         ) do
      {:ok, messages} ->
        messages = Enum.map(messages, &serialize_gmail_message/1)
        {:ok, %{query: gmail_query, count: length(messages), messages: messages}}

      error ->
        error
    end
  end

  defp review_source("google_contacts", user_id, query, limit, _args) do
    if String.trim(query) == "" do
      {:ok, %{count: 0, results: []}}
    else
      case GoogleContactsSearch.execute(%{
             "user_id" => user_id,
             "query" => query,
             "max_results" => limit
           }) do
        {:ok, result} -> {:ok, Map.take(result, [:count, :results, "count", "results"])}
        error -> error
      end
    end
  end

  defp review_source("calendar", user_id, query, limit, args) do
    with {:ok, events} <-
           GoogleCalendarHelpers.list_events(user_id,
             calendar_id: optional_string(args, "calendar_id") || "primary",
             provider:
               optional_string(args, "google_provider") || optional_string(args, "provider"),
             query: empty_to_nil(query),
             time_min: calendar_time_min(args),
             time_max: optional_string(args, "time_max"),
             max_results: limit
           ) do
      events = Enum.map(events, &serialize_calendar_event/1)
      {:ok, %{count: length(events), events: events}}
    end
  end

  defp review_source("slack", user_id, query, limit, _args) do
    if String.trim(query) == "" do
      {:ok, %{count: 0, matches: [], skipped: "query_required"}}
    else
      {matches, errors} =
        user_id
        |> slack_team_ids()
        |> Enum.map(fn team_id ->
          case SlackSearchMessages.execute(%{
                 "user_id" => user_id,
                 "team_id" => team_id,
                 "query" => query,
                 "count" => limit
               }) do
            {:ok, result} -> {:ok, result}
            {:error, reason} -> {:error, %{team_id: team_id, reason: normalize_error(reason)}}
          end
        end)
        |> Enum.reduce({[], []}, fn
          {:ok, result}, {matches, errors} ->
            {Enum.map(result.matches || [], &Map.put(&1, :team_id, result.team_id)) ++ matches,
             errors}

          {:error, error}, {matches, errors} ->
            {matches, [error | errors]}
        end)

      {:ok,
       %{count: length(matches), matches: Enum.take(matches, limit), errors: Enum.reverse(errors)}}
    end
  end

  defp review_source("open_loops", user_id, query, limit, _args) do
    {:ok,
     OpenLoops.snapshot(user_id,
       query: empty_to_nil(query),
       limit: limit,
       include_memory?: false
     )}
  end

  defp review_source("memory", user_id, query, limit, _args) do
    {:ok, Memory.prompt_context(user_id, query: query, limit: limit)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp review_source(source, _user_id, _query, _limit, _args),
    do: {:error, "unknown_source: #{source}"}

  defp requested_sources(args) do
    case optional_csv(args, "sources") do
      [] ->
        ~w(crm gmail google_contacts calendar slack open_loops memory)

      sources ->
        Enum.filter(
          sources,
          &(&1 in ~w(crm gmail google_contacts calendar slack open_loops memory))
        )
    end
  end

  defp default_gmail_query(query, args) do
    since_days =
      args
      |> optional_integer("since_days")
      |> case do
        value when is_integer(value) -> value |> max(1) |> min(365)
        _ -> 30
      end

    case String.trim(query) do
      "" -> "newer_than:#{since_days}d"
      query -> "#{query} newer_than:#{since_days}d"
    end
  end

  defp calendar_time_min(args) do
    case optional_string(args, "time_min") do
      value when is_binary(value) ->
        value

      nil ->
        since_days =
          args
          |> optional_integer("since_days")
          |> case do
            value when is_integer(value) -> value |> max(1) |> min(365)
            _ -> 30
          end

        DateTime.utc_now()
        |> DateTime.add(-since_days, :day)
        |> DateTime.to_iso8601()
    end
  end

  defp serialize_gmail_message(message) when is_map(message) do
    %{
      source: "gmail",
      resource_type: "gmail_thread",
      resource_id: message[:thread_id] || message["thread_id"],
      message_id: message[:message_id] || message["message_id"],
      title: message[:subject] || message["subject"],
      summary: message[:snippet] || message["snippet"],
      from: message[:from] || message["from"],
      to: message[:to] || message["to"],
      account: message[:google_account_email] || message["google_account_email"],
      google_provider: message[:google_provider] || message["google_provider"],
      occurred_at: to_iso8601(message[:internal_date] || message["internal_date"]),
      body_excerpt:
        body_excerpt(
          message[:text_body] || message["text_body"] || message[:html_body] ||
            message["html_body"]
        ),
      metadata: %{
        labels: message[:labels] || message["labels"] || [],
        internet_message_id: message[:internet_message_id] || message["internet_message_id"]
      }
    }
    |> compact_map()
  end

  defp serialize_gmail_message(_message), do: %{}

  defp serialize_calendar_event(event) when is_map(event) do
    attendees =
      event
      |> read_value(:attendees)
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    %{
      source: "calendar",
      resource_type: "calendar_event",
      resource_id: read_value(event, :event_id) || read_value(event, :id),
      title: read_value(event, :summary),
      summary: read_value(event, :description),
      location: read_value(event, :location),
      from: read_value(event, :organizer),
      to:
        attendees
        |> Enum.map(&(read_value(&1, :email) || read_value(&1, :display_name)))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(12)
        |> Enum.join(", ")
        |> empty_to_nil(),
      account: read_value(event, :google_account_email),
      google_provider: read_value(event, :google_provider),
      occurred_at: event |> read_value(:start) |> to_iso8601(),
      metadata: %{
        end: event |> read_value(:end) |> normalize_json_value(),
        html_link: read_value(event, :html_link),
        attendees: attendees
      }
    }
    |> compact_map()
  end

  defp serialize_calendar_event(_event), do: %{}

  defp source_observations(results) when is_map(results) do
    gmail_observations =
      results
      |> get_in(["gmail", :messages])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    calendar_observations =
      results
      |> get_in(["calendar", :events])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    slack_observations =
      results
      |> get_in(["slack", :matches])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&serialize_slack_observation/1)

    gmail_observations ++ calendar_observations ++ slack_observations
  end

  defp serialize_slack_observation(match) when is_map(match) do
    %{
      source: "slack",
      resource_type: "slack_message",
      resource_id: read_value(match, :permalink) || read_value(match, :ts),
      title: read_value(match, :channel_name) || read_value(match, :channel_id),
      summary: read_value(match, :text),
      from: read_value(match, :user),
      metadata: %{
        team_id: read_value(match, :team_id),
        channel_id: read_value(match, :channel_id),
        ts: read_value(match, :ts),
        permalink: read_value(match, :permalink)
      }
    }
    |> compact_map()
  end

  defp serialize_slack_observation(_match), do: %{}

  defp empty_source(source), do: %{count: 0, source: source}

  defp slack_team_ids(user_id) do
    user_id
    |> OAuth.list_user_tokens()
    |> Enum.map(& &1.provider)
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn
      "slack:" <> rest ->
        case String.split(rest, ":") do
          [team_id | _] when team_id != "" -> [team_id]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp normalize_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)
  defp normalize_limit(_value), do: @default_limit

  defp body_excerpt(nil), do: nil

  defp body_excerpt(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @body_excerpt_limit)
    |> empty_to_nil()
  end

  defp body_excerpt(_value), do: nil

  defp to_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp to_iso8601(%{date: date}) when is_binary(date), do: date
  defp to_iso8601(_value), do: nil

  defp read_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_json_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp normalize_json_value(%Date{} = date), do: Date.to_iso8601(date)

  defp normalize_json_value(value) when is_list(value),
    do: Enum.map(value, &normalize_json_value/1)

  defp normalize_json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_json_value(nested)} end)
  end

  defp normalize_json_value(value), do: value

  defp empty_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp empty_to_nil(value), do: value

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp normalize_error({:error, reason}), do: normalize_error(reason)
  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: inspect(reason)
end
