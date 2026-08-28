defmodule Maraithon.Todos.Brief.Context do
  @moduledoc """
  Gathers everything a chief of staff would read before briefing the user on
  one todo: the saved work item, the decision card, the actual source thread
  (Gmail message and thread, Slack thread, local conversation), the people
  involved, the user's identity and voice, and the current time.

  Every fetch is bounded and degrades to "not available" so a slow or
  disconnected source never blocks the brief.
  """

  alias Maraithon.ActionCards
  alias Maraithon.Cards.SourceContext
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Connectors.Slack
  alias Maraithon.Crm
  alias Maraithon.Memory.UserVoice
  alias Maraithon.OAuth
  alias Maraithon.Tools
  alias Maraithon.Tools.SlackHelpers
  alias Maraithon.Todos
  alias Maraithon.Todos.{ActionDrafts, PublicMetadata, Todo}
  alias Maraithon.UserIdentity

  @source_timeout_ms 20_000
  @people_timeout_ms 5_000
  @voice_timeout_ms 3_000
  @max_body_chars 6_000
  @max_history_body_chars 3_000
  @max_thread_messages 12
  @max_slack_messages 30
  @max_slack_name_lookups 8
  @max_people 3

  @type t :: %{
          todo: map(),
          card: map(),
          source: map(),
          people: list(),
          identity: String.t() | nil,
          voice: String.t() | nil,
          now: String.t(),
          channel: String.t() | nil
        }

  @doc """
  Builds the brief context for a todo.

  Options:
    * `:on_progress` - `fn label -> any` called before each slow step
    * `:source_timeout_ms`, `:people_timeout_ms`, `:voice_timeout_ms`
  """
  @spec build(String.t(), Todo.t(), keyword()) :: t()
  def build(user_id, %Todo{} = todo, opts \\ []) when is_binary(user_id) do
    progress = Keyword.get(opts, :on_progress, fn _label -> :ok end)
    channel = reply_channel(todo)

    card =
      safe(fn -> ActionCards.for_todo(todo, include_disconnected: true) end, %{})

    progress.(source_progress_label(channel))

    source =
      bounded(
        fn -> source_thread(user_id, todo, channel) end,
        Keyword.get(opts, :source_timeout_ms, @source_timeout_ms),
        %{"status" => "unavailable"}
      )

    progress.("Checking who is involved")

    people =
      bounded(
        fn -> people(user_id, todo) end,
        Keyword.get(opts, :people_timeout_ms, @people_timeout_ms),
        []
      )

    voice =
      bounded(
        fn -> voice(user_id, channel) end,
        Keyword.get(opts, :voice_timeout_ms, @voice_timeout_ms),
        nil
      )

    %{
      todo: todo_section(todo),
      card: card_section(card),
      source: source,
      people: people,
      identity: safe(fn -> UserIdentity.prompt_block(user_id) end, nil),
      voice: voice,
      now: now_label(user_id),
      channel: channel
    }
  end

  @doc """
  The channel a reply would go out on for this todo, or nil when the source
  is not a conversation (calendar, files, notes).
  """
  def reply_channel(%Todo{} = todo) do
    metadata = todo.metadata || %{}
    draft = todo.action_draft || %{}

    cond do
      todo.source == "gmail" or todo.kind == "gmail_triage" -> "gmail"
      todo.source == "slack" -> "slack"
      todo.source == "whatsapp" -> "whatsapp"
      todo.source in ["imessage", "messages", "local_patterns", "desktop"] -> "imessage"
      read_string(draft, "channel") in ["gmail", "slack"] -> read_string(draft, "channel")
      present?(read_string(metadata, "chat_key")) -> "imessage"
      true -> nil
    end
  end

  @doc """
  Returns the bounded, user-facing source history stored with a brief.

  Connector errors and internal identifiers are deliberately left out so
  product surfaces can render this projection without another source read.
  """
  def source_history(%{source: %{} = source}) do
    messages =
      case Map.get(source, "thread") do
        values when is_list(values) and values != [] -> values
        _other -> List.wrap(Map.get(source, "message"))
      end

    messages
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn message ->
      %{
        "speaker" => display_address(read_string(message, "from")),
        "from" => read_string(message, "from"),
        "to" => read_string(message, "to"),
        "subject" => read_string(message, "subject"),
        "at" => read_string(message, "date"),
        "text" =>
          first_present([
            read_string(message, "body"),
            read_string(message, "snippet")
          ])
          |> truncate(@max_history_body_chars),
        "from_user" => Map.get(message, "is_from_user") == true
      }
      |> compact()
    end)
    |> Enum.reject(&(not present?(Map.get(&1, "text"))))
    |> Enum.take(-@max_thread_messages)
  end

  def source_history(_context), do: []

  @doc "The subject of the fetched source thread, when available."
  def source_subject(%{source: %{} = source}) do
    source
    |> Map.get("message", %{})
    |> read_string("subject")
  end

  def source_subject(_context), do: nil

  # ---------------------------------------------------------------------------
  # Todo and card
  # ---------------------------------------------------------------------------

  defp todo_section(%Todo{} = todo) do
    serialized = Todos.serialize_for_prompt(todo)
    metadata = PublicMetadata.todo(todo.metadata || %{})
    draft = todo.action_draft || %{}

    %{
      "title" => todo.title,
      "summary" => todo.summary,
      "next_action" => todo.next_action,
      "action_plan" => todo.action_plan,
      "notes" => todo.notes,
      "status" => todo.status,
      "priority" => todo.priority,
      "attention_mode" => todo.attention_mode,
      "direction" => todo.direction,
      "counterparty" => todo.counterparty_label,
      "due_at" => iso(todo.due_at),
      "source" => todo.source,
      "source_account" => todo.source_account_label,
      "source_occurred_at" => iso(todo.source_occurred_at),
      "created_at" => iso(todo.inserted_at),
      "nudge_count" => todo.nudge_count,
      "last_nudged_at" => iso(todo.last_nudged_at),
      "existing_draft" =>
        if(ActionDrafts.real_draft?(draft), do: ActionDrafts.preview(draft), else: nil),
      "existing_draft_subject" => read_string(draft, "subject"),
      "attention_profile" => Map.get(serialized, :attention_profile),
      "metadata" => metadata
    }
    |> compact()
  end

  defp card_section(card) when is_map(card) do
    context = read_map(card, "context_pack")

    %{
      "headline" => read_string(card, "headline"),
      "decision_prompt" => read_string(card, "decision_prompt"),
      "why_now" => read_string(card, "why_now"),
      "next_best_action" => read_string(card, "next_best_action"),
      "people" => Map.get(context, "people"),
      "thread_summary" => read_string(context, "summary"),
      "project_or_topic" => read_string(context, "project_or_topic"),
      "relationship_context" => read_string(context, "relationship_context"),
      "source_evidence" => Map.get(context, "source_evidence"),
      "sources_checked" => safe(fn -> ActionCards.source_health_note(card) end, nil),
      "estimated_effort" => read_string(card, "estimated_effort")
    }
    |> compact()
  end

  defp card_section(_card), do: %{}

  # ---------------------------------------------------------------------------
  # Source thread
  # ---------------------------------------------------------------------------

  defp source_thread(user_id, %Todo{} = todo, "gmail"), do: gmail_thread(user_id, todo)
  defp source_thread(user_id, %Todo{} = todo, "slack"), do: slack_thread(user_id, todo)
  defp source_thread(_user_id, %Todo{} = todo, _channel), do: local_or_excerpt_thread(todo)

  defp gmail_thread(user_id, %Todo{} = todo) do
    metadata = todo.metadata || %{}
    draft = todo.action_draft || %{}

    message_id =
      first_present([
        read_string(draft, "message_id"),
        read_string(draft, "source_message_id"),
        read_string(metadata, "message_id"),
        read_string(metadata, "source_message_id"),
        read_string(metadata, "gmail_message_id"),
        Gmail.normalize_id(todo.source_item_id)
      ])

    account =
      first_present([
        read_string(draft, "google_account_email"),
        read_string(metadata, "google_account_email"),
        read_string(metadata, "account_email"),
        read_string(metadata, "account"),
        todo.source_account_label
      ])

    provider =
      first_present([
        read_string(draft, "provider"),
        read_string(draft, "google_provider"),
        read_string(metadata, "google_provider")
      ])

    case message_id do
      nil ->
        local_or_excerpt_thread(todo)

      message_id ->
        args =
          %{
            "user_id" => user_id,
            "message_id" => message_id,
            "google_account_email" => account,
            "provider" => provider
          }
          |> compact()

        case Tools.execute("gmail_get_message", args, %{surface: "internal", user_id: user_id}) do
          {:ok, result} ->
            message = read_map(result, :message)
            thread_id = read_string(message, :thread_id) || read_string(metadata, "thread_id")
            message_provider = read_string(message, :google_provider) || provider

            %{
              "status" => "available",
              "provider" => "gmail",
              "message" => gmail_message_section(message),
              "thread" => gmail_thread_messages(user_id, thread_id, message_provider, message_id)
            }
            |> compact()

          {:error, reason} ->
            todo
            |> local_or_excerpt_thread()
            |> Map.put("status", "unavailable")
            |> Map.put("reason", safe_reason(reason))
        end
    end
  end

  defp gmail_message_section(message) when is_map(message) do
    body =
      first_present([
        read_string(message, :text_body),
        message |> read_string(:html_body) |> strip_html(),
        read_string(message, :snippet)
      ])

    %{
      "from" => read_string(message, :from),
      "to" => read_string(message, :to),
      "subject" => read_string(message, :subject),
      "date" => iso(Map.get(message, :internal_date)) || read_string(message, :date),
      "body" => body |> clean_email_body() |> truncate(@max_body_chars),
      "body_unavailable_reason" => read_string(message, :body_unavailable_reason)
    }
    |> compact()
  end

  defp gmail_message_section(_message), do: %{}

  defp gmail_thread_messages(user_id, thread_id, provider, source_message_id)
       when is_binary(thread_id) do
    opts = if is_binary(provider), do: [provider: provider], else: []

    case Gmail.fetch_thread_content(user_id, thread_id, opts) do
      {:ok, messages} when is_list(messages) and messages != [] ->
        messages
        |> Enum.sort_by(&thread_sort_key/1)
        |> Enum.take(-@max_thread_messages)
        |> Enum.map(fn message ->
          body =
            first_present([
              read_string(message, :text_body),
              message |> read_string(:html_body) |> strip_html(),
              read_string(message, :snippet)
            ])

          %{
            "from" => read_string(message, :from),
            "to" => read_string(message, :to),
            "subject" => read_string(message, :subject),
            "date" => iso(Map.get(message, :internal_date)) || read_string(message, :date),
            "body" => body |> clean_email_body() |> truncate(@max_body_chars),
            "snippet" => read_string(message, :snippet),
            "is_from_user" => "SENT" in Map.get(message, :labels, []),
            "is_source_message" => read_string(message, :message_id) == source_message_id
          }
          |> compact()
        end)

      _other ->
        nil
    end
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  defp gmail_thread_messages(_user_id, _thread_id, _provider, _source_message_id), do: nil

  defp thread_sort_key(message) do
    case Map.get(message, :internal_date) do
      %DateTime{} = at -> DateTime.to_unix(at)
      _ -> 0
    end
  end

  defp slack_thread(user_id, %Todo{} = todo) do
    metadata = todo.metadata || %{}
    draft = todo.action_draft || %{}

    team_id =
      first_present([
        read_string(draft, "team_id"),
        read_string(metadata, "team_id"),
        read_string(metadata, "workspace_id"),
        single_connected_slack_team_id(user_id)
      ])

    channel =
      first_present([
        read_string(draft, "channel_id"),
        read_string(draft, "channel"),
        read_string(metadata, "channel_id"),
        read_string(metadata, "channel"),
        slack_channel_from_item_id(todo.source_item_id)
      ])

    thread_ts =
      first_present([
        read_string(draft, "thread_ts"),
        read_string(metadata, "thread_ts"),
        read_string(metadata, "ts"),
        read_string(metadata, "message_ts"),
        slack_ts_from_item_id(todo.source_item_id)
      ])

    with true <- is_binary(team_id) and is_binary(channel),
         {:ok, messages} <- fetch_slack_messages(user_id, team_id, channel, thread_ts) do
      names = slack_display_names(user_id, team_id, messages)

      %{
        "status" => "available",
        "provider" => "slack",
        "channel_name" =>
          first_present([
            read_string(metadata, "channel_name"),
            read_string(metadata, "conversation_name")
          ]),
        "workspace_name" =>
          first_present([
            read_string(metadata, "workspace_name"),
            read_string(metadata, "team_name")
          ]),
        "thread_ts" => thread_ts,
        "messages" =>
          Enum.map(messages, fn message ->
            user = read_string(message, :user)

            %{
              "from" => Map.get(names, user) || user || read_string(message, :bot_id),
              "at" => slack_ts_to_iso(read_string(message, :ts)),
              "text" => truncate(read_string(message, :text), 1_500),
              "is_source_message" =>
                is_binary(thread_ts) and read_string(message, :ts) == thread_ts
            }
            |> compact()
          end)
      }
      |> compact()
    else
      false ->
        local_or_excerpt_thread(todo)

      {:error, reason} ->
        todo
        |> local_or_excerpt_thread()
        |> Map.put("status", "unavailable")
        |> Map.put("reason", safe_reason(reason))
    end
  end

  defp fetch_slack_messages(user_id, team_id, channel, thread_ts) when is_binary(thread_ts) do
    args = %{
      "user_id" => user_id,
      "team_id" => team_id,
      "channel" => channel,
      "thread_ts" => thread_ts,
      "limit" => @max_slack_messages
    }

    case Tools.execute("slack_get_thread_replies", args, %{surface: "internal", user_id: user_id}) do
      {:ok, %{replies: replies}} when is_list(replies) and replies != [] ->
        {:ok, replies}

      {:ok, _empty} ->
        # A top-level message without replies has no thread; read the
        # surrounding channel history instead so the model sees context.
        fetch_slack_messages(user_id, team_id, channel, nil)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_slack_messages(user_id, team_id, channel, _thread_ts) do
    args = %{
      "user_id" => user_id,
      "team_id" => team_id,
      "channel" => channel,
      "limit" => @max_slack_messages
    }

    case Tools.execute("slack_list_messages", args, %{surface: "internal", user_id: user_id}) do
      {:ok, %{messages: messages}} when is_list(messages) -> {:ok, Enum.reverse(messages)}
      {:ok, _other} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp slack_display_names(user_id, team_id, messages) do
    ids =
      messages
      |> Enum.map(&read_string(&1, :user))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(@max_slack_name_lookups)

    with [_ | _] <- ids,
         {:ok, token} <- SlackHelpers.resolve_access_token(user_id, team_id, []) do
      ids
      |> Enum.reduce(%{}, fn id, acc ->
        case Slack.get_user_info(token.access_token, id) do
          {:ok, %{"user" => user}} when is_map(user) ->
            name =
              first_present([
                read_string(user, "real_name"),
                user |> read_map("profile") |> read_string("display_name"),
                read_string(user, "name")
              ])

            if is_binary(name), do: Map.put(acc, id, name), else: acc

          _other ->
            acc
        end
      end)
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    _kind, _reason -> %{}
  end

  defp single_connected_slack_team_id(user_id) do
    user_id
    |> OAuth.list_user_tokens()
    |> Enum.map(fn
      %{provider: "slack:" <> rest} -> rest |> String.split(":", parts: 2) |> List.first()
      %{metadata: %{} = metadata} -> read_string(metadata, "team_id")
      _ -> nil
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> case do
      [team_id] -> team_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp slack_channel_from_item_id(value) when is_binary(value) do
    value |> String.split(":", parts: 2) |> List.first() |> non_empty()
  end

  defp slack_channel_from_item_id(_value), do: nil

  defp slack_ts_from_item_id(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [_channel, ts] -> non_empty(ts)
      _ -> nil
    end
  end

  defp slack_ts_from_item_id(_value), do: nil

  defp slack_ts_to_iso(ts) when is_binary(ts) do
    case Float.parse(ts) do
      {seconds, _} ->
        seconds |> trunc() |> DateTime.from_unix!() |> DateTime.to_iso8601()

      :error ->
        nil
    end
  rescue
    _ -> nil
  end

  defp slack_ts_to_iso(_ts), do: nil

  defp local_or_excerpt_thread(%Todo{} = todo) do
    context = safe(fn -> SourceContext.for_todo(todo) end, %{})

    %{
      "status" => "excerpt_only",
      "participants" => Map.get(context, "participants"),
      "conversation" => Map.get(context, "conversation")
    }
    |> compact()
  end

  # ---------------------------------------------------------------------------
  # People, voice, time
  # ---------------------------------------------------------------------------

  defp people(user_id, %Todo{} = todo) do
    people = Crm.people_for_resource(user_id, "todo", todo.id, limit: @max_people)

    user_id
    |> Crm.relationship_contexts(people, link_limit: 6, resource_type: "todo")
    |> Enum.map(fn context ->
      person = context.person

      %{
        "name" => person.display_name || Enum.join([person.first_name, person.last_name], " "),
        "relationship" => person.relationship,
        "preferred_channel" => person.preferred_communication_method,
        "communication_frequency" => person.communication_frequency,
        "last_interaction_at" => iso(person.last_interaction_at),
        "notes" => truncate(person.notes, 800),
        "open_work_with_them" =>
          context
          |> Map.get(:todos, [])
          |> Enum.filter(&(&1.status in ["open", "snoozed"]))
          |> Enum.reject(&(&1.id == todo.id))
          |> Enum.map(& &1.title)
          |> Enum.take(5)
      }
      |> compact()
    end)
  rescue
    _ -> []
  end

  defp voice(user_id, channel) when channel in ["gmail", "slack"] do
    case UserVoice.prompt_context(user_id, channel) do
      %{"status" => "available", "content" => content} when is_binary(content) ->
        truncate(content, 1_500)

      _ ->
        nil
    end
  end

  defp voice(_user_id, _channel), do: nil

  defp now_label(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case safe(fn -> Todos.user_timezone_context(user_id) end, nil) do
      %{timezone_name: name, offset_hours: offset} when is_binary(name) ->
        local = DateTime.add(now, offset * 3600, :second)
        "#{Calendar.strftime(local, "%A %B %-d, %Y %H:%M")} (#{name})"

      _ ->
        "#{Calendar.strftime(now, "%A %B %-d, %Y %H:%M")} UTC"
    end
  end

  defp source_progress_label("gmail"), do: "Reading the email thread"
  defp source_progress_label("slack"), do: "Reading the Slack thread"

  defp source_progress_label(channel) when channel in ["imessage", "whatsapp"],
    do: "Reading the conversation"

  defp source_progress_label(_channel), do: "Reading the source"

  # ---------------------------------------------------------------------------
  # Bounding and helpers
  # ---------------------------------------------------------------------------

  defp bounded(fun, timeout_ms, default) when is_function(fun, 0) do
    task = Task.async(fn -> safe(fun, default) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> value
      _ -> default
    end
  end

  defp safe(fun, default) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> default
  catch
    _kind, _reason -> default
  end

  defp strip_html(nil), do: nil

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<(script|style)[^>]*>.*?<\/\1>/is, " ")
    |> String.replace(~r/<br\s*\/?>|<\/p>|<\/div>|<\/tr>/i, "\n")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n\s*\n+/, "\n\n")
    |> String.trim()
    |> non_empty()
  end

  defp display_address(value) when is_binary(value) do
    case Regex.run(~r/^\s*"?([^"<]+?)"?\s*</, value) do
      [_all, name] -> String.trim(name)
      _other -> value |> String.split("@", parts: 2) |> List.first()
    end
  end

  defp display_address(_value), do: nil

  defp clean_email_body(value) when is_binary(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.split(
      ~r/\n(?:On .+?wrote:|From:\s.+\nSent:\s|-----Original Message-----)\s*/is,
      parts: 2
    )
    |> List.first()
    |> String.replace(~r/\n>.*(?:\n>.*)*/s, "")
    |> String.trim()
    |> non_empty()
  end

  defp clean_email_body(_value), do: nil

  defp truncate(nil, _max), do: nil

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> " [truncated]"
  end

  defp safe_reason(reason) when is_binary(reason), do: reason
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "unavailable"

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(_value), do: nil

  defp read_map(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, alt_key(key)) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_map(_map, _key), do: %{}

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, alt_key(key)) do
      value when is_binary(value) -> non_empty(String.trim(value))
      _ -> nil
    end
  end

  defp read_string(_map, _key), do: nil

  defp alt_key(key) when is_atom(key), do: Atom.to_string(key)

  defp alt_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  defp present?(value), do: not blank?(value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(map) when map == %{}, do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp compact(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end
end
