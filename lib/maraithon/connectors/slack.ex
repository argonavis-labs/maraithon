defmodule Maraithon.Connectors.Slack do
  @moduledoc """
  Slack Events API connector.

  Receives Slack events via the Events API and publishes normalized events to PubSub.

  ## Topic Format

  Events are published to `slack:{team_id}:{channel_id}`

  Example: `slack:T01234567:C01234567`

  For DMs: `slack:{team_id}:dm:{user_id}`

  ## Event Types

  - `message` - Message posted to channel
  - `message_changed` - Message edited
  - `message_deleted` - Message deleted
  - `reaction_added` - Reaction added to message
  - `reaction_removed` - Reaction removed
  - `member_joined_channel` - User joined channel
  - `app_mention` - Bot was mentioned

  ## How it Works

  1. Install Slack app to workspace via OAuth
  2. Configure Event Subscriptions in Slack app settings
  3. Point Request URL to `/webhooks/slack`
  4. Subscribe to user message events (`message.channels`, `message.groups`,
     `message.im`, and `message.mpim`) plus the required bot events
  5. Slack sends signed events to the webhook for durable agent ingress

  ## Configuration

      config :maraithon, :slack,
        client_id: "your_client_id",
        client_secret: "your_client_secret",
        signing_secret: "your_signing_secret"
  """

  @behaviour Maraithon.Connectors.Connector

  alias Maraithon.OAuth.Slack, as: SlackOAuth
  alias Maraithon.Connectors.Connector
  alias Maraithon.Runtime.PeriodicJobs

  require Logger

  @slack_excerpt_max_chars 8_000
  @slack_metadata_item_limit 20
  @slack_metadata_text_max_chars 1_000

  # ===========================================================================
  # Webhook Handling
  # ===========================================================================

  @impl true
  def verify_signature(conn, raw_body) do
    timestamp = get_header(conn, "x-slack-request-timestamp")
    signature = get_header(conn, "x-slack-signature")

    if is_nil(timestamp) or is_nil(signature) do
      {:error, :missing_headers}
    else
      SlackOAuth.verify_signature(raw_body, timestamp, signature)
    end
  end

  @impl true
  def handle_webhook(_conn, params) do
    case params["type"] do
      "url_verification" ->
        # Slack challenge for webhook verification
        {:challenge, params["challenge"]}

      "event_callback" ->
        handle_event(params)

      type ->
        {:ignore, "unknown type: #{type}"}
    end
  end

  # ===========================================================================
  # Event Handling
  # ===========================================================================

  defp handle_event(params) do
    event = params["event"]
    team_id = params["team_id"]
    event_type = event["type"]

    case event_type do
      "message" ->
        handle_message_event(team_id, event, params)

      "app_mention" ->
        handle_app_mention(team_id, event, params)

      "reaction_added" ->
        handle_reaction(team_id, event, params, "reaction_added")

      "reaction_removed" ->
        handle_reaction(team_id, event, params, "reaction_removed")

      "member_joined_channel" ->
        handle_member_event(team_id, event, params, "member_joined")

      "member_left_channel" ->
        handle_member_event(team_id, event, params, "member_left")

      _ ->
        # Generic handler for other events
        topic = build_topic(team_id, event["channel"])

        normalized =
          build_slack_event(
            event_type,
            %{
              team_id: team_id,
              event: event
            },
            params
          )

        {:ok, topic, normalized}
    end
  end

  defp handle_message_event(team_id, event, params) do
    channel = event["channel"]
    sender_id = event["user"] || event["bot_id"]
    topic = build_topic(team_id, channel, sender_id)

    # Determine event type based on subtype
    event_type =
      case event["subtype"] do
        "message_changed" -> "message_changed"
        "message_deleted" -> "message_deleted"
        nil -> "message"
        subtype -> "message_#{subtype}"
      end

    data = %{
      team_id: team_id,
      channel_id: channel,
      user_id: sender_id,
      self_user_id: authorized_user_id(params),
      text: event["text"],
      ts: event["ts"],
      thread_ts: event["thread_ts"],
      blocks: event["blocks"],
      files: parse_files(event["files"]),
      edited: event["edited"]
    }

    normalized = build_slack_event(event_type, data, params)

    case ingest_slack_message(team_id, Map.put(event, "user", sender_id), event_type) do
      :ok ->
        Logger.info("Slack message received",
          team_id: team_id,
          channel: channel,
          user: sender_id
        )

        {:ok, topic, normalized}

      {:error, reason} ->
        {:error, {:slack_message_persistence_failed, reason}}
    end
  end

  defp ingest_slack_message(team_id, event, event_type) when is_binary(team_id) do
    if content_bearing_slack_message?(event_type, event) do
      with :ok <- validate_slack_message_identity(event),
           {:ok, durable_content} <- durable_slack_content(event),
           {:ok, accounts} <- lookup_slack_accounts(team_id) do
        Enum.reduce_while(accounts, :ok, fn %{user_id: user_id} = account, :ok ->
          with :ok <-
                 maybe_observe_slack_message(
                   user_id,
                   account,
                   team_id,
                   event,
                   durable_content
                 ),
               :ok <- wake_source_account(account, "slack_message") do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    else
      :ok
    end
  end

  defp ingest_slack_message(_team_id, _event, _event_type), do: :ok

  defp content_bearing_slack_message?(event_type, event) do
    event_type not in ["message_changed", "message_deleted"] and
      (event_type == "app_mention" or String.starts_with?(event_type, "message")) and
      ((is_binary(event["text"]) and event["text"] != "") or
         (is_list(event["files"]) and event["files"] != []) or
         (is_list(event["blocks"]) and event["blocks"] != []))
  end

  defp validate_slack_message_identity(event) do
    cond do
      not is_binary(event["user"]) or event["user"] == "" ->
        {:error, :missing_slack_message_sender}

      not is_binary(event["channel"]) or event["channel"] == "" ->
        {:error, :missing_slack_message_channel}

      not is_binary(event["ts"]) or event["ts"] == "" ->
        {:error, :missing_slack_message_timestamp}

      not valid_slack_timestamp?(event["ts"]) ->
        {:error, :invalid_slack_message_timestamp}

      true ->
        :ok
    end
  end

  defp valid_slack_timestamp?(ts) when is_binary(ts) do
    case Float.parse(ts) do
      {seconds, ""} when seconds >= 0 -> true
      _other -> false
    end
  end

  defp valid_slack_timestamp?(_ts), do: false

  defp lookup_slack_accounts(team_id) do
    accounts = Maraithon.ConnectedAccounts.list_connected_provider("slack:#{team_id}")

    accounts =
      case accounts do
        [] ->
          case Maraithon.ConnectedAccounts.get_connected_by_external_account("slack", team_id) do
            nil -> []
            account -> [account]
          end

        connected ->
          connected
      end

    {:ok, accounts}
  rescue
    exception ->
      Logger.warning("Slack account lookup failed",
        team_id: team_id,
        failure_code: Maraithon.Redaction.error_class(exception)
      )

      {:error, :slack_account_lookup_failed}
  catch
    kind, reason ->
      Logger.warning("Slack account lookup failed",
        team_id: team_id,
        failure_code: Maraithon.Redaction.error_class({kind, reason})
      )

      {:error, :slack_account_lookup_failed}
  end

  defp maybe_observe_slack_message(user_id, account, team_id, event, durable_content) do
    source_account = account.external_account_id || team_id
    sender_id = event["user"]
    ts = event["ts"]

    cond do
      not is_binary(sender_id) or sender_id == "" ->
        {:error, :missing_slack_message_sender}

      not is_binary(ts) or ts == "" ->
        {:error, :missing_slack_message_timestamp}

      true ->
        occurred_at = parse_slack_ts(ts)

        participant = %{
          "role" => "from",
          "identifier" => %{"slack_id" => sender_id},
          "display_name" => nil
        }

        changeset =
          Maraithon.Crm.Observation.new(%{
            "user_id" => user_id,
            "source" => "slack",
            "source_account" => source_account,
            "source_item_id" => "#{team_id}:#{event["channel"]}:#{ts}",
            "occurred_at" => occurred_at,
            "direction" => slack_message_direction(account, sender_id),
            "participants" => [participant],
            "subject" => nil,
            "excerpt" => durable_content.excerpt,
            "metadata" => %{
              "team_id" => team_id,
              "channel" => event["channel"],
              "ts" => ts,
              "thread_ts" => event["thread_ts"],
              "files" => durable_content.files,
              "file_count" => durable_content.file_count,
              "blocks" => durable_content.blocks,
              "block_count" => durable_content.block_count
            }
          })

        case Maraithon.Crm.Ingest.observe(user_id, changeset) do
          {:ok, :buffered, _observation_id} ->
            :ok

          {:ok, :flushed, _observation_id, _job_id} ->
            :ok

          {:ok, :duplicate} ->
            :ok

          {:error, reason} ->
            Logger.warning("CRM ingest skipped a Slack message",
              user_id: user_id,
              ts: ts,
              reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  end

  defp durable_slack_content(event) when is_map(event) do
    files = compact_slack_files(event["files"])
    blocks = compact_slack_blocks(event["blocks"])

    excerpt =
      [normalize_content_text(event["text"])] ++
        Enum.map(files, &slack_file_excerpt/1) ++ Enum.map(blocks, &Map.get(&1, "text"))

    excerpt =
      excerpt
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.join("\n")
      |> clip_text()
      |> normalize_content_text()

    if is_binary(excerpt) do
      {:ok,
       %{
         excerpt: excerpt,
         files: files,
         file_count: count_slack_items(event["files"]),
         blocks: blocks,
         block_count: count_slack_items(event["blocks"])
       }}
    else
      {:error, :missing_slack_message_durable_content}
    end
  end

  defp durable_slack_content(_event), do: {:error, :missing_slack_message_durable_content}

  defp compact_slack_files(files) when is_list(files) do
    files
    |> Enum.take(@slack_metadata_item_limit)
    |> Enum.map(&compact_slack_file/1)
    |> Enum.reject(&is_nil/1)
  end

  defp compact_slack_files(_files), do: []

  defp compact_slack_file(file) when is_map(file) do
    preview =
      normalize_content_text(
        file["preview_plain_text"] || file["preview"] ||
          get_in(file, ["initial_comment", "comment"])
      )

    compact =
      %{
        "id" => normalize_content_text(file["id"]),
        "name" => normalize_content_text(file["name"]),
        "title" => normalize_content_text(file["title"]),
        "mimetype" => normalize_content_text(file["mimetype"]),
        "filetype" => normalize_content_text(file["filetype"]),
        "mode" => normalize_content_text(file["mode"]),
        "size" => normalize_non_negative_integer(file["size"]),
        "preview" => clip_metadata_text(preview)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if map_size(compact) == 0, do: nil, else: compact
  end

  defp compact_slack_file(_file), do: nil

  defp compact_slack_blocks(blocks) when is_list(blocks) do
    blocks
    |> Enum.take(@slack_metadata_item_limit)
    |> Enum.map(&compact_slack_block/1)
    |> Enum.reject(&is_nil/1)
  end

  defp compact_slack_blocks(_blocks), do: []

  defp compact_slack_block(block) when is_map(block) do
    text =
      block
      |> slack_block_texts()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.join(" ")
      |> clip_metadata_text()
      |> normalize_content_text()

    if is_binary(text) do
      %{
        "type" => normalize_content_text(block["type"]),
        "block_id" => normalize_content_text(block["block_id"]),
        "text" => text
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defp compact_slack_block(_block), do: nil

  defp slack_block_texts(value) when is_binary(value), do: [normalize_content_text(value)]

  defp slack_block_texts(value) when is_list(value),
    do: Enum.flat_map(value, &slack_block_texts/1)

  defp slack_block_texts(value) when is_map(value) do
    ["text", "alt_text", "title", "fields", "elements"]
    |> Enum.flat_map(fn key -> slack_block_texts(Map.get(value, key)) end)
  end

  defp slack_block_texts(_value), do: []

  defp slack_file_excerpt(file) when is_map(file) do
    label = file["title"] || file["name"] || file["id"]
    type = file["mimetype"] || file["filetype"]

    heading =
      ["Slack file", label, type && "(#{type})"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(": ")

    [heading, file["preview"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" — ")
    |> normalize_content_text()
  end

  defp slack_file_excerpt(_file), do: nil

  defp count_slack_items(items) when is_list(items), do: length(items)
  defp count_slack_items(_items), do: 0

  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative_integer(_value), do: nil

  defp clip_metadata_text(nil), do: nil

  defp clip_metadata_text(text) when is_binary(text),
    do: String.slice(text, 0, @slack_metadata_text_max_chars)

  defp clip_metadata_text(_text), do: nil

  defp normalize_content_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_content_text(_text), do: nil

  defp slack_message_direction(account, sender_id) do
    metadata = account.metadata || %{}

    connected_user_id =
      metadata["authed_user_id"] || metadata[:authed_user_id] ||
        metadata["slack_user_id"] || metadata[:slack_user_id]

    if is_binary(connected_user_id) and connected_user_id == sender_id,
      do: "outbound",
      else: "inbound"
  end

  defp parse_slack_ts(ts) when is_binary(ts) do
    case Float.parse(ts) do
      {seconds, ""} when seconds >= 0 ->
        microseconds = round(seconds * 1_000_000)
        DateTime.from_unix!(microseconds, :microsecond)

      _other ->
        raise ArgumentError, "invalid Slack timestamp"
    end
  end

  defp parse_slack_ts(_), do: DateTime.utc_now()

  defp clip_text(nil), do: nil

  defp clip_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.slice(0, @slack_excerpt_max_chars)
  end

  defp clip_text(_), do: nil

  defp handle_app_mention(team_id, event, params) do
    channel = event["channel"]
    topic = build_topic(team_id, channel)

    data = %{
      team_id: team_id,
      channel_id: channel,
      user_id: event["user"],
      text: event["text"],
      ts: event["ts"],
      thread_ts: event["thread_ts"]
    }

    normalized = build_slack_event("app_mention", data, params)

    with :ok <- ingest_slack_message(team_id, event, "app_mention") do
      Logger.info("Slack app mention",
        team_id: team_id,
        channel: channel,
        user: event["user"]
      )

      {:ok, topic, normalized}
    else
      {:error, reason} -> {:error, {:slack_message_persistence_failed, reason}}
    end
  end

  defp wake_source_account(account, reason) do
    case PeriodicJobs.wake_source_account(account) do
      {:ok, _result} ->
        :ok

      {:error, wake_reason} ->
        Logger.warning("Slack source account wakeup enqueue failed",
          account_reference: Maraithon.Redaction.fingerprint(account.id),
          trigger: reason,
          failure_code: Maraithon.Redaction.error_class(wake_reason)
        )

        :ok
    end
  end

  defp handle_reaction(team_id, event, params, event_type) do
    # Reactions have item.channel
    channel = get_in(event, ["item", "channel"])
    topic = build_topic(team_id, channel)

    data = %{
      team_id: team_id,
      channel_id: channel,
      user_id: event["user"],
      reaction: event["reaction"],
      item_type: get_in(event, ["item", "type"]),
      item_ts: get_in(event, ["item", "ts"])
    }

    normalized = build_slack_event(event_type, data, params)
    {:ok, topic, normalized}
  end

  defp handle_member_event(team_id, event, params, event_type) do
    channel = event["channel"]
    topic = build_topic(team_id, channel)

    data = %{
      team_id: team_id,
      channel_id: channel,
      user_id: event["user"],
      inviter: event["inviter"]
    }

    normalized = build_slack_event(event_type, data, params)
    {:ok, topic, normalized}
  end

  # ===========================================================================
  # Slack API Helpers
  # ===========================================================================

  @doc """
  Posts a message to a Slack channel.
  """
  def post_message(access_token, channel, text, opts \\ []) do
    body = %{
      channel: channel,
      text: text
    }

    body =
      if thread_ts = opts[:thread_ts] do
        Map.put(body, :thread_ts, thread_ts)
      else
        body
      end

    SlackOAuth.api_request(:post, "chat.postMessage", access_token, body)
  end

  @doc """
  Opens or resumes a DM/MPIM conversation with one or more Slack users.
  """
  def open_conversation(access_token, user_ids, opts \\ []) when is_list(user_ids) do
    body =
      %{
        users: Enum.join(user_ids, ",")
      }
      |> maybe_put_body(:return_im, opts[:return_im])

    SlackOAuth.api_request(:post, "conversations.open", access_token, body)
  end

  @doc """
  Gets channel info.
  """
  def get_channel_info(access_token, channel_id) do
    SlackOAuth.api_request(:get, "conversations.info?channel=#{channel_id}", access_token)
  end

  @doc """
  Gets user info.
  """
  def get_user_info(access_token, user_id) do
    SlackOAuth.api_request(:get, "users.info?user=#{user_id}", access_token)
  end

  @doc """
  Lists Slack conversations.
  """
  def list_conversations(access_token, opts \\ []) do
    query =
      %{}
      |> maybe_put_query(:types, encode_csv(opts[:types]))
      |> maybe_put_query(:exclude_archived, encode_bool(opts[:exclude_archived]))
      |> maybe_put_query(:limit, opts[:limit])
      |> maybe_put_query(:cursor, opts[:cursor])
      |> URI.encode_query()

    endpoint = append_query("conversations.list", query)
    SlackOAuth.api_request(:get, endpoint, access_token)
  end

  @doc """
  Fetches message history for one Slack conversation.
  """
  def get_conversation_history(access_token, channel_id, opts \\ []) do
    query =
      %{}
      |> Map.put(:channel, channel_id)
      |> maybe_put_query(:limit, opts[:limit])
      |> maybe_put_query(:oldest, opts[:oldest])
      |> maybe_put_query(:latest, opts[:latest])
      |> maybe_put_query(:inclusive, encode_bool(opts[:inclusive]))
      |> maybe_put_query(:cursor, opts[:cursor])
      |> URI.encode_query()

    endpoint = append_query("conversations.history", query)
    SlackOAuth.api_request(:get, endpoint, access_token)
  end

  @doc """
  Fetches replies in one Slack thread.
  """
  def get_thread_replies(access_token, channel_id, thread_ts, opts \\ []) do
    query =
      %{}
      |> Map.put(:channel, channel_id)
      |> Map.put(:ts, thread_ts)
      |> maybe_put_query(:limit, opts[:limit])
      |> maybe_put_query(:oldest, opts[:oldest])
      |> maybe_put_query(:latest, opts[:latest])
      |> maybe_put_query(:inclusive, encode_bool(opts[:inclusive]))
      |> maybe_put_query(:cursor, opts[:cursor])
      |> URI.encode_query()

    endpoint = append_query("conversations.replies", query)
    SlackOAuth.api_request(:get, endpoint, access_token)
  end

  @doc """
  Searches Slack messages with a user token.
  """
  def search_messages(access_token, query_text, opts \\ []) do
    query =
      %{}
      |> Map.put(:query, query_text)
      |> maybe_put_query(:count, opts[:count])
      |> maybe_put_query(:page, opts[:page])
      |> maybe_put_query(:sort, opts[:sort])
      |> maybe_put_query(:sort_dir, opts[:sort_dir])
      |> URI.encode_query()

    endpoint = append_query("search.messages", query)
    SlackOAuth.api_request(:get, endpoint, access_token)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp build_slack_event(event_type, data, params) do
    event = Connector.build_event(event_type, "slack", data, params)

    case params["event_id"] do
      event_id when is_binary(event_id) and event_id != "" ->
        event
        |> Map.put(:id, event_id)
        |> Map.put(:dedupe_key, "slack-event:#{event_id}")

      _missing_event_id ->
        event
    end
  end

  defp authorized_user_id(params) when is_map(params) do
    authorization_user_id(params["authorizations"]) ||
      first_string(params["authed_users"]) ||
      string_value(params["authed_user_id"])
  end

  defp authorized_user_id(_params), do: nil

  defp authorization_user_id(authorizations) when is_list(authorizations) do
    authorizations
    |> Enum.find_value(fn
      %{"user_id" => user_id, "is_bot" => false} -> string_value(user_id)
      _authorization -> nil
    end)
    |> case do
      nil ->
        Enum.find_value(authorizations, fn
          %{"user_id" => user_id} -> string_value(user_id)
          _authorization -> nil
        end)

      user_id ->
        user_id
    end
  end

  defp authorization_user_id(_authorizations), do: nil

  defp first_string(values) when is_list(values), do: Enum.find_value(values, &string_value/1)
  defp first_string(_values), do: nil

  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp string_value(_value), do: nil

  defp build_topic(team_id, nil), do: "slack:#{team_id}"
  defp build_topic(team_id, channel), do: "slack:#{team_id}:#{channel}"

  defp build_topic(team_id, channel, user_id) do
    if dm_channel?(channel) and is_binary(user_id) and user_id != "" do
      "slack:#{team_id}:dm:#{user_id}"
    else
      build_topic(team_id, channel)
    end
  end

  defp get_header(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value] -> value
      _ -> nil
    end
  end

  defp parse_files(nil), do: []

  defp parse_files(files) do
    Enum.map(files, fn f ->
      %{
        id: f["id"],
        name: f["name"],
        mimetype: f["mimetype"],
        url: f["url_private"],
        size: f["size"]
      }
    end)
  end

  defp maybe_put_body(body, _key, nil), do: body
  defp maybe_put_body(body, _key, ""), do: body
  defp maybe_put_body(body, key, value), do: Map.put(body, key, value)

  defp maybe_put_query(params, _key, nil), do: params
  defp maybe_put_query(params, _key, ""), do: params
  defp maybe_put_query(params, key, value), do: Map.put(params, key, value)

  defp append_query(endpoint, ""), do: endpoint
  defp append_query(endpoint, query), do: "#{endpoint}?#{query}"

  defp encode_csv(nil), do: nil

  defp encode_csv(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      normalized -> Enum.join(normalized, ",")
    end
  end

  defp encode_csv(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp encode_bool(value) when value in [true, "true", "TRUE", "1"], do: "true"
  defp encode_bool(value) when value in [false, "false", "FALSE", "0"], do: "false"
  defp encode_bool(_value), do: nil

  defp dm_channel?(channel) when is_binary(channel) do
    String.starts_with?(channel, "D")
  end

  defp dm_channel?(_channel), do: false
end
