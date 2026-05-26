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
  alias Maraithon.SourceFreshness

  alias Maraithon.Tools.{
    BrowserHistorySearch,
    FilesSearch,
    GmailHelpers,
    GoogleCalendarHelpers,
    GoogleContactsSearch,
    MessagesSearch,
    NotesSearch,
    RemindersSearch,
    VoiceMemosSearch,
    SlackSearchMessages
  }

  @default_limit 5
  @max_limit 12
  @default_timeout_ms 12_000
  @max_timeout_ms 30_000
  @body_excerpt_limit 1_600
  @valid_sources ~w(
    crm gmail google_contacts calendar slack open_loops memory
    messages notes reminders files browser_history voice_memos
  )

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      query = optional_string(args, "query") || optional_string(args, "person") || ""
      limit = args |> optional_integer("max_results") |> normalize_limit()
      sources = requested_sources(args)
      timeout_ms = args |> optional_integer("timeout_ms") |> normalize_timeout()

      {results, errors} = run_source_reviews(sources, user_id, query, limit, args, timeout_ms)

      {:ok,
       %{
         source: "connected_context",
         query: empty_to_nil(query),
         reviewed_sources: Enum.filter(sources, &Map.has_key?(results, &1)),
         source_freshness: SourceFreshness.compact_for_prompt(user_id),
         results: results,
         source_observations: source_observations(results),
         errors: errors
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp run_source_reviews(sources, user_id, query, limit, args, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    tasks =
      Enum.map(sources, fn source ->
        {source, Task.async(fn -> review_source(source, user_id, query, limit, args) end)}
      end)

    tasks
    |> Enum.reduce({%{}, []}, fn {source, task}, {results, errors} ->
      remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

      case Task.yield(task, remaining_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, result}} ->
          {Map.put(results, source, result), errors}

        {:ok, {:error, reason}} ->
          {Map.put(results, source, empty_source(source)),
           [%{source: source, reason: normalize_error(reason)} | errors]}

        {:exit, reason} ->
          {Map.put(results, source, empty_source(source)),
           [%{source: source, reason: normalize_error(reason)} | errors]}

        nil ->
          {Map.put(results, source, empty_source(source)),
           [%{source: source, reason: "timeout_after_#{timeout_ms}ms"} | errors]}
      end
    end)
    |> then(fn {results, errors} -> {results, Enum.reverse(errors)} end)
  end

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

  defp review_source("messages", user_id, query, limit, _args) do
    search_local_source(MessagesSearch, "messages", "messages", user_id, query, limit)
  end

  defp review_source("notes", user_id, query, limit, _args) do
    search_local_source(NotesSearch, "notes", "notes", user_id, query, limit)
  end

  defp review_source("reminders", user_id, query, limit, _args) do
    search_local_source(RemindersSearch, "reminders", "reminders", user_id, query, limit)
  end

  defp review_source("files", user_id, query, limit, _args) do
    search_local_source(FilesSearch, "files", "files", user_id, query, limit)
  end

  defp review_source("browser_history", user_id, query, limit, _args) do
    search_local_source(BrowserHistorySearch, "browser_history", "visits", user_id, query, limit)
  end

  defp review_source("voice_memos", user_id, query, limit, _args) do
    search_local_source(VoiceMemosSearch, "voice_memos", "voice_memos", user_id, query, limit)
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

  defp search_local_source(module, source, collection_key, user_id, query, limit)
       when is_binary(query) do
    case String.trim(query) do
      "" ->
        {:ok, %{collection_key => [], source: source, count: 0, skipped: "query_required"}}

      _query ->
        module.execute(%{"user_id" => user_id, "query" => query, "limit" => limit})
    end
  end

  defp search_local_source(_module, source, collection_key, _user_id, _query, _limit) do
    {:ok, %{collection_key => [], source: source, count: 0, skipped: "query_required"}}
  end

  defp requested_sources(args) do
    case optional_csv(args, "sources") do
      [] ->
        @valid_sources

      sources ->
        valid =
          sources
          |> Enum.map(&canonical_source/1)
          |> Enum.filter(&(&1 in @valid_sources))
          |> Enum.uniq()

        case valid do
          [] -> @valid_sources
          valid_sources -> valid_sources
        end
    end
  end

  defp canonical_source(source) when is_binary(source) do
    source
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "imessage" -> "messages"
      "imessages" -> "messages"
      "text_messages" -> "messages"
      "texts" -> "messages"
      "apple_notes" -> "notes"
      "apple_note" -> "notes"
      "mac_notes" -> "notes"
      "browser" -> "browser_history"
      "history" -> "browser_history"
      "voice_memo" -> "voice_memos"
      "memos" -> "voice_memos"
      other -> other
    end
  end

  defp canonical_source(source), do: source

  defp normalize_timeout(value) when is_integer(value),
    do: value |> max(1_000) |> min(@max_timeout_ms)

  defp normalize_timeout(_value), do: @default_timeout_ms

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
    crm_observations =
      results
      |> get_in(["crm", :people])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&serialize_crm_observation/1)

    google_contact_observations =
      results
      |> get_in(["google_contacts", :results])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&serialize_google_contact_observation/1)

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

    message_observations =
      results
      |> get_in(["messages", :messages])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&serialize_message_observation/1)

    note_observations =
      results
      |> get_in(["notes", :notes])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&serialize_note_observation/1)

    reminder_observations =
      results
      |> get_in(["reminders", :reminders])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&serialize_reminder_observation/1)

    file_observations =
      results
      |> get_in(["files", :files])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&serialize_file_observation/1)

    browser_observations =
      results
      |> get_in(["browser_history", :visits])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&serialize_browser_observation/1)

    voice_memo_observations =
      results
      |> get_in(["voice_memos", :voice_memos])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&serialize_voice_memo_observation/1)

    open_loop_observations =
      results
      |> get_in(["open_loops", :buckets])
      |> open_loop_bucket_observations()

    memory_observations =
      results
      |> get_in(["memory", :memories])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&serialize_memory_observation/1)

    crm_observations ++
      google_contact_observations ++
      gmail_observations ++
      calendar_observations ++
      slack_observations ++
      message_observations ++
      note_observations ++
      reminder_observations ++
      file_observations ++
      browser_observations ++
      voice_memo_observations ++
      open_loop_observations ++
      memory_observations
  end

  defp serialize_crm_observation(person) when is_map(person) do
    name = read_value(person, :display_name)
    relationship = read_value(person, :relationship)
    notes = read_value(person, :notes)

    %{
      source: "crm",
      resource_type: "person",
      resource_id: read_value(person, :id),
      title: name,
      summary: Enum.find([relationship, notes], &present?/1),
      from: name,
      metadata: %{
        first_name: read_value(person, :first_name),
        last_name: read_value(person, :last_name),
        contact_details: read_value(person, :contact_details),
        communication_frequency: read_value(person, :communication_frequency),
        relationship_strength: read_value(person, :relationship_strength),
        affinity_score: read_value(person, :affinity_score),
        interaction_count: read_value(person, :interaction_count),
        last_interaction_at: normalize_json_value(read_value(person, :last_interaction_at))
      }
    }
    |> compact_map()
  end

  defp serialize_crm_observation(_person), do: %{}

  defp serialize_google_contact_observation(result) when is_map(result) do
    person = read_value(result, :person) || result
    name = google_contact_name(person)
    emails = google_contact_values(person, :emailAddresses, :value)
    organizations = google_contact_values(person, :organizations, :name)

    %{
      source: "google_contacts",
      resource_type: "contact",
      resource_id: read_value(person, :resourceName),
      title: name || List.first(emails),
      summary: organizations |> Enum.reject(&is_nil/1) |> Enum.join(", ") |> empty_to_nil(),
      to: Enum.join(emails, ", ") |> empty_to_nil(),
      metadata: %{
        organizations: organizations,
        phone_numbers: google_contact_values(person, :phoneNumbers, :value)
      }
    }
    |> compact_map()
  end

  defp serialize_google_contact_observation(_result), do: %{}

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

  defp serialize_message_observation(message) when is_map(message) do
    %{
      source: "imessage",
      resource_type: "message",
      resource_id: read_value(message, :message_id) || read_value(message, :guid),
      title: read_value(message, :chat_display_name) || read_value(message, :sender_handle),
      summary: read_value(message, :text_snippet),
      from:
        if(read_value(message, :is_from_me),
          do: "Kent",
          else: read_value(message, :sender_handle)
        ),
      occurred_at: read_value(message, :sent_at),
      metadata: %{
        chat_key: read_value(message, :chat_key),
        is_from_me: read_value(message, :is_from_me)
      }
    }
    |> compact_map()
  end

  defp serialize_message_observation(_message), do: %{}

  defp serialize_note_observation(note) when is_map(note) do
    %{
      source: "apple_notes",
      resource_type: "note",
      resource_id: read_value(note, :note_id) || read_value(note, :guid),
      title: read_value(note, :title),
      summary: read_value(note, :body_snippet) || read_value(note, :snippet),
      occurred_at: read_value(note, :modified_at),
      metadata: %{
        folder: read_value(note, :folder)
      }
    }
    |> compact_map()
  end

  defp serialize_note_observation(_note), do: %{}

  defp serialize_reminder_observation(reminder) when is_map(reminder) do
    %{
      source: "reminders",
      resource_type: "reminder",
      resource_id: read_value(reminder, :reminder_id) || read_value(reminder, :guid),
      title: read_value(reminder, :title),
      summary: read_value(reminder, :notes_snippet),
      occurred_at: read_value(reminder, :due_at) || read_value(reminder, :modified_at),
      metadata: %{
        list_name: read_value(reminder, :list_name),
        priority: read_value(reminder, :priority_label),
        is_completed: read_value(reminder, :is_completed)
      }
    }
    |> compact_map()
  end

  defp serialize_reminder_observation(_reminder), do: %{}

  defp serialize_file_observation(file) when is_map(file) do
    %{
      source: "files",
      resource_type: "file",
      resource_id: read_value(file, :file_id) || read_value(file, :guid),
      title: read_value(file, :filename),
      summary: read_value(file, :text_content_snippet) || read_value(file, :path),
      occurred_at: read_value(file, :modified_at),
      metadata: %{
        path: read_value(file, :path),
        extension: read_value(file, :extension),
        text_truncated: read_value(file, :text_truncated)
      }
    }
    |> compact_map()
  end

  defp serialize_file_observation(_file), do: %{}

  defp serialize_browser_observation(visit) when is_map(visit) do
    %{
      source: "browser_history",
      resource_type: "browser_visit",
      resource_id: read_value(visit, :visit_id) || read_value(visit, :guid),
      title: read_value(visit, :title) || read_value(visit, :host),
      summary: read_value(visit, :url),
      occurred_at: read_value(visit, :last_visited_at),
      metadata: %{
        browser: read_value(visit, :browser),
        host: read_value(visit, :host),
        visit_count: read_value(visit, :visit_count)
      }
    }
    |> compact_map()
  end

  defp serialize_browser_observation(_visit), do: %{}

  defp serialize_voice_memo_observation(memo) when is_map(memo) do
    %{
      source: "voice_memos",
      resource_type: "voice_memo",
      resource_id: read_value(memo, :memo_id) || read_value(memo, :guid),
      title: read_value(memo, :title),
      summary: read_value(memo, :transcript_snippet),
      occurred_at: read_value(memo, :created_at),
      metadata: %{
        duration_seconds: read_value(memo, :duration_seconds),
        has_audio: read_value(memo, :has_audio),
        audio_truncated: read_value(memo, :audio_truncated)
      }
    }
    |> compact_map()
  end

  defp serialize_voice_memo_observation(_memo), do: %{}

  defp open_loop_bucket_observations(buckets) when is_map(buckets) do
    buckets
    |> Enum.flat_map(fn {bucket, todos} ->
      todos
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.take(5)
      |> Enum.map(&serialize_open_loop_observation(&1, bucket))
    end)
  end

  defp open_loop_bucket_observations(_buckets), do: []

  defp serialize_open_loop_observation(todo, bucket) when is_map(todo) do
    %{
      source: "open_loops",
      resource_type: "todo",
      resource_id: read_value(todo, :id),
      title: read_value(todo, :title),
      summary: read_value(todo, :next_action) || read_value(todo, :context),
      from: read_value(todo, :person_name),
      metadata: %{
        bucket: to_string(bucket),
        status: read_value(todo, :status),
        priority: read_value(todo, :priority),
        due_at: normalize_json_value(read_value(todo, :due_at)),
        source: read_value(todo, :source),
        account: read_value(todo, :account)
      }
    }
    |> compact_map()
  end

  defp serialize_memory_observation(memory) when is_map(memory) do
    %{
      source: "memory",
      resource_type: read_value(memory, :kind) || "memory",
      resource_id: read_value(memory, :id),
      title: read_value(memory, :title),
      summary: read_value(memory, :summary) || read_value(memory, :content),
      metadata: %{
        confidence: read_value(memory, :confidence),
        importance: read_value(memory, :importance),
        polarity: read_value(memory, :polarity),
        tags: read_value(memory, :tags),
        source_ref_type: read_value(memory, :source_ref_type),
        source_ref_id: read_value(memory, :source_ref_id)
      }
    }
    |> compact_map()
  end

  defp serialize_memory_observation(_memory), do: %{}

  defp google_contact_name(person) when is_map(person) do
    person
    |> read_value(:names)
    |> List.wrap()
    |> Enum.find_value(fn name ->
      if is_map(name), do: read_value(name, :displayName) || read_value(name, :givenName)
    end)
  end

  defp google_contact_values(person, collection_key, value_key) when is_map(person) do
    person
    |> read_value(collection_key)
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&read_value(&1, value_key))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(8)
  end

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

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: value not in [nil, [], %{}]

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp normalize_error({:error, reason}), do: normalize_error(reason)
  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: inspect(reason)
end
