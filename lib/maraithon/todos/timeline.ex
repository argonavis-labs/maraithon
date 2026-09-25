defmodule Maraithon.Todos.Timeline do
  @moduledoc "A todo's chronological context, projected from durable turns, actions and source messages."
  import Ecto.Query
  alias Maraithon.{Repo, Todos, TelegramConversations}
  alias Maraithon.TelegramAssistant.PreparedAction
  alias Maraithon.Todos.{ActivityEvent, ConversationContext}

  def for_conversation(conversation) do
    with id when is_binary(id) <- TelegramConversations.linked_todo_id(conversation),
         todo when not is_nil(todo) <- Todos.get_for_user(conversation.user_id, id) do
      build(todo, conversation)
    else
      _ -> []
    end
  end

  def for_todo(nil), do: []

  def for_todo(todo) do
    case TelegramConversations.get_mobile_thread_for_todo(todo.user_id, todo.id) do
      nil -> lifecycle(todo)
      conversation -> build(todo, conversation)
    end
  end

  defp build(todo, conversation) do
    actions =
      Repo.all(
        from a in PreparedAction,
          where: a.user_id == ^todo.user_id and a.conversation_id == ^conversation.id,
          order_by: [desc: a.inserted_at],
          limit: 60
      )
      |> Enum.map(&PreparedAction.hydrate_payload/1)

    references = [
      {todo.source, Map.merge(todo.metadata || %{}, todo.action_draft || %{})}
      | Enum.map(actions, &{provider(&1), reference_payload(&1)})
    ]

    replies =
      references
      |> Enum.uniq()
      |> Enum.take(12)
      |> Enum.flat_map(fn {provider, payload} ->
        ConversationContext.messages(todo.user_id, provider, payload, 40)
      end)
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(
        &(&1.from_user == false && is_binary(&1.at) && &1.at >= iso(todo.inserted_at))
      )
      |> Enum.map(fn m ->
        entry(
          m.id,
          "reply",
          if(m.provider == "imessage", do: "Message from ", else: "Reply from ") <> m.speaker,
          m.text,
          m.at,
          m.provider
        )
      end)

    (lifecycle(todo) ++
       turns(conversation.turns || []) ++ Enum.flat_map(actions, &action_entries/1) ++ replies)
    |> Enum.sort_by(&{&1.occurred_at || "", &1.id})
    |> Enum.take(-160)
  end

  defp lifecycle(todo) do
    events =
      Repo.all(
        from e in ActivityEvent,
          where: e.user_id == ^todo.user_id and e.todo_id == ^todo.id,
          order_by: [desc: e.occurred_at],
          limit: 60
      )

    created =
      entry(
        "todo:" <> todo.id,
        "created",
        "Todo appeared",
        todo.title,
        iso(todo.inserted_at),
        todo.source
      )

    [
      created
      | Enum.flat_map(events, fn e ->
          if e.event_type == "created",
            do: [],
            else: [
              entry(
                e.id,
                e.event_type,
                case e.event_type do
                  "marked_done" -> "Marked done"
                  "deleted" -> "Dismissed"
                  _ -> "Todo updated"
                end,
                e.metadata["note"],
                iso(e.occurred_at),
                e.todo_source
              )
            ]
        end)
    ]
  end

  defp turns(turns) do
    Enum.flat_map(turns, fn turn ->
      data = turn.structured_data || %{}

      cond do
        data["message_class"] == "todo_chat_primer" ->
          []

        turn.role == "user" ->
          [
            entry(
              "chat:" <> turn.id,
              "chat",
              "You chatted",
              turn.text,
              iso(turn.inserted_at),
              nil,
              turn.id
            )
          ]

        turn.role == "assistant" && turn.turn_kind not in ["action_result", "system_notice"] ->
          [
            entry(
              "chat:" <> turn.id,
              "assistant",
              "Maraithon replied",
              turn.text,
              iso(turn.inserted_at),
              nil,
              turn.id
            )
          ] ++
            legacy_draft(turn, data)

        true ->
          []
      end
    end)
  end

  defp legacy_draft(turn, %{"draft_card" => %{} = card} = data) do
    if is_nil(data["prepared_action_id"]) do
      [
        entry(
          "draft:" <> turn.id,
          "draft",
          "Draft prepared",
          card["body"],
          iso(turn.inserted_at),
          card["provider"],
          turn.id
        )
      ]
    else
      []
    end
  end

  defp legacy_draft(_, _), do: []

  defp action_entries(a) do
    provider = provider(a)
    body = a.payload["body"] || a.payload["text"] || a.preview_text

    draft =
      entry(
        "draft:" <> a.id,
        "draft",
        label(provider) <> " draft prepared",
        body,
        iso(a.inserted_at),
        provider
      )

    outcome =
      case a.status do
        "executed" ->
          {"sent",
           if(provider in ~w(gmail slack imessage),
             do: "Sent via " <> label(provider),
             else: "Action completed"
           ), a.executed_at}

        "rejected" ->
          {"cancelled",
           if(a.error == "draft_replaced", do: "Draft replaced", else: "Draft cancelled"),
           a.updated_at}

        "confirmed" ->
          {"sending", "Sending via " <> label(provider), a.confirmed_at}

        "failed" ->
          {"failed", "Could not send", a.updated_at}

        "execution_unknown" ->
          {"unknown", "Send not confirmed", a.updated_at}

        "expired" ->
          {"expired", "Draft expired", a.updated_at}

        _ ->
          nil
      end

    if outcome do
      {kind, title, at} = outcome
      [draft, entry("outcome:" <> a.id, kind, title, body, iso(at), provider)]
    else
      [draft]
    end
  end

  def reference_payload(action) do
    result = action.payload["_maraithon_execution_result"] || %{}
    identity = action.payload["_maraithon_reconciliation_identity"] || %{}

    action.payload
    |> Map.merge(Map.take(identity, ~w(provider)))
    |> Map.merge(
      Map.take(result, ~w(thread_id google_provider provider team_id channel thread_ts))
    )
    |> then(fn payload ->
      if action.action_type == "slack_post" and is_nil(payload["thread_ts"]) and
           is_binary(result["ts"]), do: Map.put(payload, "thread_ts", result["ts"]), else: payload
    end)
  end

  defp provider(%{action_type: type}) when type in ~w(gmail_send gmail_draft_send), do: "gmail"
  defp provider(%{action_type: "slack_post"}), do: "slack"
  defp provider(%{action_type: "imessage_send"}), do: "imessage"
  defp provider(%{action_type: "browser_interact"}), do: "browser"
  defp provider(_), do: "calendar"
  defp label("gmail"), do: "Gmail"
  defp label("slack"), do: "Slack"
  defp label("imessage"), do: "Messages"
  defp label(_), do: "Action"

  defp entry(id, kind, title, body, at, provider, message_id \\ nil),
    do: %{
      id: id,
      kind: kind,
      title: title,
      body: if(is_binary(body), do: String.slice(body, 0, 2_000)),
      occurred_at: at,
      provider: provider,
      message_id: message_id
    }

  defp iso(%DateTime{} = date), do: DateTime.to_iso8601(date)
  defp iso(_), do: nil
end
