defmodule Maraithon.Runtime.SlackConversationReconciler do
  @moduledoc """
  Bounded Slack anti-entropy for one connected workspace.

  Events API ingress remains the instant path. This planner rotates over every
  readable channel, DM, and MPIM and fans a small due set into independent
  provider jobs. Each child owns a durable per-conversation cursor, paginates
  history and replies, and advances only after every fetched message is stored
  as a durable observation.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.{Slack, SourceCursor, SourceCursors}
  alias Maraithon.Repo
  alias Maraithon.Runtime.{BackgroundJob, Config}
  alias Maraithon.Tools.SlackHelpers

  @child_job "runtime_partition:slack_conversation_reconcile"
  @conversation_page_limit 200
  @history_page_limit 200
  @reply_page_limit 200
  @max_pages 2_000
  # The discovery coordinator runs every minute in production. Ten keeps one
  # complete 90-conversation workspace rotation under ten minutes without a
  # burst: children still use independent provider partitions and the shared
  # Slack rate-limit lane supplies back-pressure.
  @default_batch_size 10
  @default_initial_lookback_seconds 48 * 60 * 60
  @default_overlap_seconds 60 * 60

  @doc "Returns a bounded, fair set of readable conversations not already running."
  def plan(account, opts \\ [])

  def plan(%ConnectedAccount{status: "connected"} = account, opts) do
    with {:ok, team_id} <- team_id(account),
         {:ok, token} <-
           SlackHelpers.resolve_access_token(account.user_id, team_id, token_preference: "user"),
         {:ok, conversations} <- list_all_conversations(token.access_token) do
      due =
        conversations
        |> Enum.filter(&readable?/1)
        |> reject_active(account)
        |> sort_by_cursor_age(account)
        |> Enum.take(batch_size(opts))
        |> Enum.map(fn conversation ->
          %{
            channel_id: conversation["id"],
            conversation_kind: conversation_kind(conversation),
            dedupe_key: child_dedupe_key(account.id, conversation["id"])
          }
        end)

      {:ok,
       %{
         team_id: team_id,
         readable_conversations: Enum.count(conversations, &readable?/1),
         due: due
       }}
    end
  end

  def plan(%ConnectedAccount{}, _opts), do: {:skip, :account_not_connected}
  def plan(_account, _opts), do: {:error, :invalid_slack_reconciliation_account}

  @doc "Reconciles one exact conversation window and advances only its cursor."
  def run_conversation(account, channel_id, conversation_kind, opts \\ [])

  def run_conversation(
        %ConnectedAccount{status: "connected"} = account,
        channel_id,
        conversation_kind,
        opts
      )
      when is_binary(channel_id) and is_binary(conversation_kind) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:second)

    with {:ok, team_id} <- team_id(account),
         {:ok, token} <-
           SlackHelpers.resolve_access_token(account.user_id, team_id, token_preference: "user"),
         {oldest, expected_lower} <- conversation_window(account, channel_id, now, opts),
         newest = Integer.to_string(DateTime.to_unix(now, :second)),
         {:ok, roots} <- fetch_all_history(token.access_token, channel_id, oldest, newest),
         {:ok, replies} <-
           fetch_thread_replies(token.access_token, channel_id, roots, oldest, newest),
         messages <- exact_window_messages(roots ++ replies, oldest, newest),
         :ok <- persist_messages(account, team_id, channel_id, messages) do
      {:ok,
       %{
         outcome: "reconciled",
         account_id: account.id,
         conversation_kind: conversation_kind,
         source_items: length(messages),
         root_messages: length(exact_window_messages(roots, oldest, newest)),
         thread_replies:
           replies
           |> exact_window_messages(oldest, newest)
           |> Enum.count(&(is_binary(&1["thread_ts"]) and &1["thread_ts"] != "")),
         lower_cursor: expected_lower,
         upper_cursor: newest,
         deferred_watermarks: [
           %{
             account_id: account.id,
             kind: cursor_kind(channel_id),
             value: newest,
             expected_lower_value: expected_lower
           }
         ],
         model_calls: 0
       }}
    end
  end

  def run_conversation(%ConnectedAccount{}, _channel_id, _conversation_kind, _opts),
    do: {:skip, :account_not_connected}

  def run_conversation(_account, _channel_id, _conversation_kind, _opts),
    do: {:error, :invalid_slack_reconciliation_account}

  def child_job_type, do: @child_job

  def child_dedupe_key(account_id, channel_id)
      when is_integer(account_id) and is_binary(channel_id) do
    digest =
      channel_id
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    "runtime-partition:slack-conversation:#{digest}:#{account_id}"
  end

  defp team_id(%ConnectedAccount{provider: provider}) when is_binary(provider) do
    case String.split(provider, ":", parts: 3) do
      ["slack", team_id] when team_id != "" -> {:ok, team_id}
      _other -> {:error, :invalid_slack_workspace_provider}
    end
  end

  defp list_all_conversations(access_token),
    do: list_all_conversations(access_token, nil, [], 0)

  defp list_all_conversations(access_token, cursor, acc, page_count)
       when page_count < @max_pages do
    opts =
      [
        types: ["public_channel", "private_channel", "mpim", "im"],
        exclude_archived: false,
        limit: @conversation_page_limit
      ]
      |> maybe_put_cursor(cursor)

    case Slack.list_conversations(access_token, opts) do
      {:ok, response} ->
        conversations = acc ++ normalize_list(response["channels"])
        next_cursor = response |> get_in(["response_metadata", "next_cursor"]) |> string()

        if next_cursor,
          do: list_all_conversations(access_token, next_cursor, conversations, page_count + 1),
          else: {:ok, Enum.uniq_by(conversations, & &1["id"])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_all_conversations(_access_token, _cursor, _acc, _page_count),
    do: {:error, :slack_conversation_pagination_limit}

  defp reject_active(conversations, account) do
    keys = Enum.map(conversations, &child_dedupe_key(account.id, &1["id"]))

    active =
      BackgroundJob
      |> where(
        [job],
        job.job_type == ^@child_job and job.dedupe_key in ^keys and
          job.status in ["pending", "running"]
      )
      |> select([job], job.dedupe_key)
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(conversations, &MapSet.member?(active, child_dedupe_key(account.id, &1["id"])))
  end

  defp sort_by_cursor_age(conversations, account) do
    kinds = Enum.map(conversations, &cursor_kind(&1["id"]))

    cursors =
      SourceCursor
      |> where(
        [cursor],
        cursor.connected_account_id == ^account.id and cursor.kind in ^kinds
      )
      |> Repo.all()
      |> Map.new(&{&1.kind, &1})

    Enum.sort_by(conversations, fn conversation ->
      case Map.get(cursors, cursor_kind(conversation["id"])) do
        nil -> {0, ~U[1970-01-01 00:00:00Z], conversation["id"]}
        cursor -> {1, cursor.updated_at, conversation["id"]}
      end
    end)
  end

  defp conversation_window(account, channel_id, now, opts) do
    cursor = SourceCursors.get(account.id, cursor_kind(channel_id))

    case cursor && cursor.value do
      value when is_binary(value) ->
        lower = max(parse_seconds(value, 0) - overlap_seconds(opts), 0)
        {Integer.to_string(lower), value}

      _missing ->
        lower = max(DateTime.to_unix(now, :second) - initial_lookback_seconds(opts), 0)
        {Integer.to_string(lower), nil}
    end
  end

  defp fetch_all_history(access_token, channel_id, oldest, newest),
    do: fetch_all_history(access_token, channel_id, oldest, newest, nil, [], 0)

  defp fetch_all_history(access_token, channel_id, oldest, newest, cursor, acc, page_count)
       when page_count < @max_pages do
    opts =
      [
        oldest: oldest,
        latest: newest,
        inclusive: true,
        limit: @history_page_limit
      ]
      |> maybe_put_cursor(cursor)

    case Slack.get_conversation_history(access_token, channel_id, opts) do
      {:ok, response} ->
        messages = acc ++ normalize_list(response["messages"])
        next_cursor = response |> get_in(["response_metadata", "next_cursor"]) |> string()

        cond do
          next_cursor ->
            fetch_all_history(
              access_token,
              channel_id,
              oldest,
              newest,
              next_cursor,
              messages,
              page_count + 1
            )

          response["has_more"] == true ->
            {:error, :slack_history_pagination_incomplete}

          true ->
            {:ok, dedupe_messages(messages)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all_history(_token, _channel, _oldest, _newest, _cursor, _acc, _page_count),
    do: {:error, :slack_history_pagination_limit}

  defp fetch_thread_replies(access_token, channel_id, roots, oldest, newest) do
    roots
    |> Enum.filter(&(positive_integer(&1["reply_count"]) > 0))
    |> Enum.reduce_while({:ok, []}, fn root, {:ok, replies} ->
      case fetch_all_replies(access_token, channel_id, root["ts"], oldest, newest) do
        {:ok, thread_messages} -> {:cont, {:ok, replies ++ thread_messages}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_all_replies(access_token, channel_id, thread_ts, oldest, newest),
    do: fetch_all_replies(access_token, channel_id, thread_ts, oldest, newest, nil, [], 0)

  defp fetch_all_replies(
         access_token,
         channel_id,
         thread_ts,
         oldest,
         newest,
         cursor,
         acc,
         page_count
       )
       when page_count < @max_pages do
    opts =
      [
        oldest: oldest,
        latest: newest,
        inclusive: true,
        limit: @reply_page_limit
      ]
      |> maybe_put_cursor(cursor)

    case Slack.get_thread_replies(access_token, channel_id, thread_ts, opts) do
      {:ok, response} ->
        messages = acc ++ normalize_list(response["messages"])
        next_cursor = response |> get_in(["response_metadata", "next_cursor"]) |> string()

        cond do
          next_cursor ->
            fetch_all_replies(
              access_token,
              channel_id,
              thread_ts,
              oldest,
              newest,
              next_cursor,
              messages,
              page_count + 1
            )

          response["has_more"] == true ->
            {:error, :slack_thread_pagination_incomplete}

          true ->
            {:ok, dedupe_messages(messages)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all_replies(
         _token,
         _channel,
         _thread,
         _oldest,
         _newest,
         _cursor,
         _acc,
         _page_count
       ),
       do: {:error, :slack_thread_pagination_limit}

  defp persist_messages(account, team_id, channel_id, messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case Slack.ingest_reconciled_message(account, team_id, channel_id, message) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp exact_window_messages(messages, oldest, newest) do
    lower = parse_seconds(oldest, 0)
    upper = parse_seconds(newest, 0)

    messages
    |> normalize_list()
    |> Enum.filter(fn message ->
      ts = message |> Map.get("ts") |> parse_timestamp_seconds()
      ts > lower and ts <= upper
    end)
    |> dedupe_messages()
  end

  defp dedupe_messages(messages) do
    Enum.uniq_by(messages, &string(&1["ts"]))
  end

  defp cursor_kind(channel_id) do
    digest =
      channel_id
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 22)

    "slack_conversation:#{digest}"
  end

  defp readable?(%{"id" => id, "is_im" => true}) when is_binary(id) and id != "", do: true
  defp readable?(%{"id" => id, "is_mpim" => true}) when is_binary(id) and id != "", do: true
  defp readable?(%{"id" => id, "is_member" => true}) when is_binary(id) and id != "", do: true
  defp readable?(_conversation), do: false

  defp conversation_kind(%{"is_im" => true}), do: "dm"
  defp conversation_kind(%{"is_mpim" => true}), do: "group_dm"
  defp conversation_kind(%{"is_private" => true}), do: "private_channel"
  defp conversation_kind(_conversation), do: "public_channel"

  defp maybe_put_cursor(opts, nil), do: opts
  defp maybe_put_cursor(opts, cursor), do: Keyword.put(opts, :cursor, cursor)

  defp normalize_list(values) when is_list(values), do: values
  defp normalize_list(_values), do: []

  defp string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp string(_value), do: nil

  defp parse_seconds(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _invalid -> default
    end
  end

  defp parse_seconds(_value, default), do: default

  defp parse_timestamp_seconds(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _invalid -> -1
    end
  end

  defp parse_timestamp_seconds(_value), do: -1

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: 0

  defp batch_size(opts) do
    Keyword.get(
      opts,
      :batch_size,
      Config.positive_integer(:slack_reconciliation_batch_size, @default_batch_size)
    )
    |> bounded_positive_integer(@default_batch_size, 100)
  end

  defp initial_lookback_seconds(opts) do
    Keyword.get(opts, :initial_lookback_seconds, @default_initial_lookback_seconds)
    |> bounded_positive_integer(@default_initial_lookback_seconds, 31 * 24 * 60 * 60)
  end

  defp overlap_seconds(opts) do
    Keyword.get(opts, :overlap_seconds, @default_overlap_seconds)
    |> bounded_positive_integer(@default_overlap_seconds, 24 * 60 * 60)
  end

  defp bounded_positive_integer(value, _default, maximum)
       when is_integer(value) and value > 0,
       do: min(value, maximum)

  defp bounded_positive_integer(_value, default, _maximum), do: default
end
