defmodule Maraithon.Delegations.SlackSource do
  @moduledoc "Resumable Slack pages, a complete evidence fingerprint, and six recent bodies."
  alias Maraithon.Connectors.Slack
  alias Maraithon.Delegations.{Scope, SlackIdentity, SlackIngress}
  @page_size 100
  @max_messages 10_000
  @max_pages 1_000

  # Preflight has no granted turn yet. Use the same bounded reader without
  # persisting authority or claiming that a partial read is complete.
  def fetch(user_id, identity, channel, thread, opts \\ []) do
    with {:ok, token} <- SlackIdentity.read_token(user_id, identity, channel),
         do:
           drain(
             token,
             start(identity["account_id"], channel, thread, opts),
             System.monotonic_time(:millisecond) + 15_000
           )
  end

  def read(context, key) do
    d = context.delegation
    scope = context.grant.data["scope"]
    channel = if d.provider_thread_id, do: d.slack_channel, else: scope["source_channel_id"]
    thread = d.provider_thread_id || scope["source_thread_id"]

    history? =
      not is_nil(d.provider_thread_id) and String.starts_with?(channel, "D") and
        SlackIngress.only_live_id(d.user_id, channel) == d.id

    initial =
      start(scope["identity"]["account_id"], channel, thread, include_unthreaded?: history?)

    state = context.run.prompt_snapshot[key] || initial

    with true <-
           Map.take(state, ~w(version account_id channel thread_id history)) ==
             Map.take(initial, ~w(version account_id channel thread_id history)),
         {:ok, token} <- SlackIdentity.read_token(d.user_id, scope["identity"], channel),
         {:ok, messages, state} <- page(token, state),
         {:ok, snapshot} <- completed(state) do
      {:ok, messages, snapshot, state}
    else
      false -> {:error, :source_gap}
      error -> error
    end
  end

  defp drain(token, state, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, {:http_error, "slack_preview_timeout"}}
    else
      with {:ok, _, state} <- page(token, state),
           {:ok, snapshot} <- completed(state),
           do: if(snapshot, do: {:ok, snapshot}, else: drain(token, state, deadline))
    end
  end

  defp start(account, channel, thread, opts) do
    %{
      "version" => 1,
      "account_id" => account,
      "channel" => channel,
      "thread_id" => thread,
      "history" => String.starts_with?(channel, "D") and opts[:include_unthreaded?] == true,
      "phase" => "replies",
      "cursor" => nil,
      "boundary" => nil,
      "last_id" => nil,
      "frontier" => nil,
      "root_revision" => nil,
      "pages" => 0,
      "message_count" => 0,
      "digests" => %{"replies" => "", "history" => ""},
      "cursors" => [],
      "authors" => [],
      "messages" => []
    }
  end

  defp page(token, %{"pages" => pages, "phase" => phase} = state)
       when pages < @max_pages and phase in ~w(replies history) do
    opts = [limit: @page_size, cursor: state["cursor"]]
    channel = state["channel"]
    thread = state["thread_id"]

    result =
      if phase == "replies" do
        Slack.get_thread_replies(
          token,
          channel,
          thread,
          opts ++ [oldest: state["boundary"], inclusive: false]
        )
      else
        Slack.get_conversation_history(
          token,
          channel,
          opts ++
            [oldest: thread, latest: state["boundary"], inclusive: is_nil(state["boundary"])]
        )
      end

    case result do
      {:ok, response} -> advance(state, response)
      {:error, {:slack_error, "invalid_cursor"}} -> resume_by_time(state)
      error -> error
    end
  end

  defp page(_, _), do: {:error, :source_gap}

  defp resume_by_time(%{"cursor" => cursor, "frontier" => last} = state)
       when is_binary(cursor) and is_binary(last) do
    # Slack cursors expire. The timestamp frontier is durable across a long
    # cooldown; it is advanced only with the page's authenticated evidence.
    {:ok, [], %{state | "cursor" => nil, "boundary" => last, "pages" => state["pages"] + 1}}
  end

  defp resume_by_time(_), do: {:error, :source_gap}

  defp advance(state, response) do
    cursor = get_in(response, ["response_metadata", "next_cursor"])
    cursor = if cursor in [nil, ""], do: nil, else: cursor
    raw = response["messages"]

    with true <- is_list(raw) and length(raw) <= @page_size and Enum.all?(raw, &is_map/1),
         true <- is_nil(cursor) or (is_binary(cursor) and byte_size(cursor) <= 2_048),
         cursor_hash = cursor && Scope.hash(cursor),
         false <- cursor_hash in state["cursors"],
         {:ok, messages, next} <- collect(state, raw),
         true <- not is_nil(next["root_revision"]) or not is_nil(cursor),
         true <- next["message_count"] <= @max_messages do
      next = %{
        next
        | "pages" => state["pages"] + 1,
          "frontier" => page_frontier(raw, state),
          "cursor" => cursor,
          "cursors" => if(cursor, do: [cursor_hash | state["cursors"]], else: state["cursors"])
      }

      next =
        cond do
          cursor ->
            next

          response["has_more"] == true ->
            nil

          state["phase"] == "replies" and state["history"] ->
            %{
              next
              | "phase" => "history",
                "last_id" => nil,
                "frontier" => nil,
                "boundary" => nil,
                "cursors" => []
            }

          true ->
            %{next | "phase" => "done"}
        end

      if next, do: bounded(messages, next), else: {:error, :source_gap}
    else
      _ -> {:error, :source_gap}
    end
  end

  defp page_frontier([], state), do: state["frontier"]

  defp page_frontier(raw, state) do
    ids = Enum.map(raw, &(&1["ts"] || &1["message_id"]))

    if Enum.all?(ids, &time/1),
      do: if(state["phase"] == "history", do: Enum.min(ids), else: Enum.max(ids)),
      else: nil
  end

  defp collect(state, raw) do
    root = state["thread_id"]
    history? = state["phase"] == "history"
    # Threaded messages have an authoritative copy in conversations.replies.
    copies_valid? =
      not history? or
        Enum.all?(raw, fn m ->
          case Enum.find(state["messages"], &(&1["message_id"] == (m["ts"] || m["message_id"]))) do
            nil -> true
            previous -> normalize(m, state["channel"], root)["revision"] == previous["revision"]
          end
        end)

    raw =
      if history?,
        do:
          Enum.filter(
            raw,
            &((&1["thread_ts"] || &1["thread_id"]) == nil or
                (&1["ts"] || &1["message_id"]) == root)
          ),
        else: raw

    messages = Enum.map(raw, &normalize(&1, state["channel"], root))
    ids = Enum.map(messages, & &1["message_id"])

    valid =
      Enum.all?(Enum.zip(raw, messages), fn {raw, m} ->
        valid?(m) and m["channel"] == state["channel"] and m["thread_id"] == root and
          (history? or m["message_id"] == root or (raw["thread_ts"] || raw["thread_id"]) == root)
      end)

    if copies_valid? and valid and length(Enum.uniq(ids)) == length(ids) do
      messages
      |> Enum.sort_by(& &1["message_id"], if(history?, do: :desc, else: :asc))
      |> Enum.reduce_while({:ok, [], state}, fn m, {:ok, accepted, state} ->
        case add(state, m, history?) do
          {:ok, state, true} -> {:cont, {:ok, [m | accepted], state}}
          {:ok, state, false} -> {:cont, {:ok, accepted, state}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, messages, next} -> {:ok, Enum.sort_by(messages, & &1["message_id"]), next}
        error -> error
      end
    else
      {:error, :source_gap}
    end
  end

  defp add(state, m, history?) do
    id = m["message_id"]
    root? = id == state["thread_id"]
    repeated_root? = root? and not is_nil(state["root_revision"])
    previous = state["last_id"]

    cond do
      repeated_root? ->
        if state["root_revision"] == m["revision"],
          do: {:ok, state, false},
          else: {:error, :source_gap}

      previous && if(history?, do: id >= previous, else: id <= previous) ->
        {:error, :source_gap}

      true ->
        phase = state["phase"]

        authors =
          if is_nil(m["bot_id"]),
            do: Enum.uniq([m["from"] | state["authors"]]),
            else: state["authors"]

        next = %{
          state
          | "last_id" => id,
            "root_revision" => if(root?, do: m["revision"], else: state["root_revision"]),
            "message_count" => state["message_count"] + 1,
            "authors" => authors,
            "digests" =>
              Map.put(
                state["digests"],
                phase,
                Scope.hash([state["digests"][phase], id, m["revision"]])
              ),
            "messages" =>
              Enum.sort_by([m | state["messages"]], & &1["message_id"]) |> Enum.take(-6)
        }

        {:ok, next, true}
    end
  end

  defp bounded(messages, state) do
    case Maraithon.DurablePayload.prepare_map(state, 240_000) do
      {:ok, state} -> {:ok, messages, state}
      _ -> {:error, :source_gap}
    end
  end

  defp completed(%{"phase" => "done", "root_revision" => root} = state) when is_binary(root) do
    snapshot =
      state
      |> Map.take(~w(account_id channel thread_id message_count messages authors))
      |> Map.merge(%{
        "provider" => "slack",
        "complete" => true,
        "read_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "fingerprint" => Scope.hash(state["digests"])
      })

    Maraithon.DurablePayload.prepare_map(snapshot, 240_000)
  end

  defp completed(%{"phase" => "done"}), do: {:error, :source_gap}
  defp completed(_), do: {:ok, nil}

  def snapshot(raw, account_id, channel, thread) when is_list(raw) do
    with true <- length(raw) in 1..@max_messages,
         {:ok, _, state} <- collect(start(account_id, channel, thread, []), raw),
         true <- not is_nil(state["root_revision"]),
         {:ok, _, state} <- bounded([], state),
         do: completed(%{state | "phase" => "done"}),
         else: (_ -> {:error, :source_gap})
  end

  def snapshot(_, _, _, _), do: {:error, :source_gap}

  def unchanged?(snapshot, previous) do
    old =
      if previous["fingerprint"],
        do: {:ok, previous},
        else:
          snapshot(
            previous["messages"],
            previous["account_id"],
            previous["channel"],
            previous["thread_id"]
          )

    match?({:ok, _}, old) and
      Map.take(snapshot, ~w(account_id channel thread_id fingerprint)) ==
        Map.take(elem(old, 1), ~w(account_id channel thread_id fingerprint))
  end

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

  def participants(snapshot, identity) do
    authors =
      snapshot["authors"] ||
        snapshot["messages"] |> Enum.filter(&is_nil(&1["bot_id"])) |> Enum.map(& &1["from"])

    Enum.reject(authors, &(&1 in [identity["user_id"], identity["operator_user_id"]]))
    |> Enum.uniq()
  end
end
