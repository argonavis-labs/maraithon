defmodule Maraithon.Delegations.SlackSource do
  @moduledoc "Bounded Slack conversation evidence shared by preflight, refresh and ingress."
  alias Maraithon.Connectors.Slack
  alias Maraithon.Delegations.SlackIdentity
  @max_messages 100

  def fetch(user_id, identity, channel, thread, opts \\ []) do
    with {:ok, token} <- SlackIdentity.read_token(user_id, identity, channel),
         {:ok, response} <-
           Slack.get_thread_replies(token, channel, thread, limit: @max_messages),
         true <- complete?(response),
         {:ok, messages} <-
           include_dm_history(token, channel, thread, response["messages"], opts),
         {:ok, snapshot} <- snapshot(messages, identity["account_id"], channel, thread) do
      {:ok, snapshot}
    else
      {:error, _} = error -> error
      _ -> {:error, :source_gap}
    end
  end

  defp include_dm_history(token, "D" <> _ = channel, thread, messages, opts) do
    if opts[:include_unthreaded?] do
      with {:ok, history} <-
             Slack.get_conversation_history(token, channel,
               oldest: thread,
               inclusive: true,
               limit: @max_messages
             ),
           true <- complete?(history) and is_list(history["messages"]) do
        raw =
          Enum.filter(history["messages"], &(&1["thread_ts"] in [nil, thread]))
          |> Enum.map(&Map.update(&1, "thread_ts", thread, fn value -> value || thread end))

        groups = Enum.group_by(messages ++ raw, & &1["ts"])

        if Enum.all?(groups, fn {_, copies} ->
             copies |> Enum.map(&normalize(&1, channel, thread)) |> Enum.uniq() |> length() == 1
           end),
           do: {:ok, Enum.map(groups, fn {_, copies} -> hd(copies) end)},
           else: {:error, :source_gap}
      else
        {:error, _} = error -> error
        _ -> {:error, :source_gap}
      end
    else
      {:ok, messages}
    end
  end

  defp include_dm_history(_, _, _, messages, _), do: {:ok, messages}

  defp complete?(response),
    do:
      response["has_more"] != true and
        get_in(response, ["response_metadata", "next_cursor"]) in [nil, ""] and
        is_list(response["messages"])

  def snapshot(raw, account_id, channel, thread) when is_list(raw) do
    messages = Enum.map(raw, &normalize(&1, channel, thread))
    ids = Enum.map(messages, & &1["message_id"])

    if length(messages) in 1..@max_messages and length(Enum.uniq(ids)) == length(ids) and
         thread in ids and Enum.all?(messages, &(valid?(&1) and &1["thread_id"] == thread)) and
         Enum.all?(raw, fn m ->
           (m["ts"] || m["message_id"]) == thread or
             (m["thread_ts"] || m["thread_id"]) == thread
         end) do
      data = %{
        "provider" => "slack",
        "account_id" => account_id,
        "channel" => channel,
        "thread_id" => thread,
        "complete" => true,
        "read_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "messages" => Enum.sort_by(messages, & &1["message_id"])
      }

      case Maraithon.DurablePayload.prepare_map(data, 240_000) do
        {:ok, _} = result -> result
        _ -> {:error, :source_gap}
      end
    else
      {:error, :source_gap}
    end
  end

  def snapshot(_, _, _, _), do: {:error, :source_gap}

  def normalize(raw, channel, root) when is_map(raw) do
    id = raw["target_ts"] || raw["message_id"] || raw["ts"]
    edited = get_in(raw, ["edited", "ts"])

    revision =
      if raw["event_type"] in ~w(message_changed message_deleted),
        do: raw["event_ts"],
        else: edited || raw["revision_at"] || id

    data = %{
      "provider" => "slack",
      "message_id" => id,
      "thread_id" => raw["thread_ts"] || raw["thread_id"] || root,
      "channel" => raw["channel"] || channel,
      "from" => raw["user"] || raw["from"] || raw["bot_id"],
      "text_body" => raw["text"] || raw["text_body"],
      "bot_id" => raw["bot_id"],
      "client_msg_id" => raw["client_msg_id"],
      "revision_at" => revision,
      "internal_date" => iso(id),
      "deleted" => raw["event_type"] == "message_deleted" || raw["deleted"] == true
    }

    Map.put(data, "revision", Maraithon.Delegations.Scope.hash(data))
  end

  def normalize(_, _, _), do: %{}

  def valid?(m),
    do:
      is_binary(m["from"]) and m["from"] != "" and
        is_binary(m["text_body"]) and not is_nil(time(m["message_id"])) and
        not is_nil(time(m["revision_at"])) and not is_nil(time(m["thread_id"]))

  def time(value) when is_binary(value) do
    with [_, seconds, micros] <- Regex.run(~r/^(\d{10})\.(\d{6})$/, value),
         {:ok, date} <-
           DateTime.from_unix(
             String.to_integer(seconds) * 1_000_000 + String.to_integer(micros),
             :microsecond
           ),
         do: date,
         else: (_ -> nil)
  end

  def time(_), do: nil
  defp iso(value), do: if(date = time(value), do: DateTime.to_iso8601(date))

  def classify(message, scope, own_action? \\ false) do
    own = scope["identity"]["user_id"]
    operator = scope["identity"]["operator_user_id"]
    text = String.downcase(String.trim(message["text_body"] || ""))

    cond do
      not valid?(message) or message["deleted"] == true ->
        "source_gap"

      own_action? ->
        "own_send"

      message["from"] == operator ->
        "human_send"

      message["from"] == own ->
        if(scope["actor"] == "as_user", do: "human_send", else: "auto_reply")

      is_binary(message["bot_id"]) ->
        "auto_reply"

      message["from"] not in (scope["counterparty_user_ids"] || []) ->
        "scope_change"

      text in ["stop", "please stop", "unsubscribe", "please stop messaging me"] ->
        "stop"

      true ->
        "reply"
    end
  end

  def participants(snapshot, identity),
    do:
      snapshot["messages"]
      |> Enum.filter(
        &(is_nil(&1["bot_id"]) and
            &1["from"] not in [identity["user_id"], identity["operator_user_id"]])
      )
      |> Enum.map(& &1["from"])
      |> Enum.uniq()
end
