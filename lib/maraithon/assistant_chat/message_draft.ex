defmodule Maraithon.AssistantChat.MessageDraft do
  @moduledoc """
  Builds a native Messages draft from a user-scoped, known contact or message.
  Preparing a draft never sends; only the human-confirmed action may execute.
  """

  import Ecto.Query
  alias Maraithon.{Crm, LocalMessages, Repo, TelegramAssistant}
  alias Maraithon.TelegramAssistant.PreparedAction

  def prepare_action(context, args) do
    with {:ok, result} <- prepare(context.user_id, args) do
      if is_binary(args["todo_id"]) do
        card = result.draft_card

        payload = %{
          "recipient" => card.recipient,
          "recipient_name" => card.recipient_name,
          "body" => card.body,
          "todo_id" => args["todo_id"],
          "keep_todo_open" => true,
          "user_id" => context.user_id,
          "chat_key" => Maraithon.Todos.ConversationContext.message_chat(context.user_id, args)
        }

        with {:ok, action} <-
               replace_draft(%{
                 user_id: context.user_id,
                 chat_id: context.chat_id,
                 conversation_id: context.conversation_id,
                 run_id: context.run_id,
                 surface: context.surface,
                 action_type: "imessage_send",
                 target_type: "imessage_recipient",
                 target_id: card.recipient,
                 payload: payload,
                 preview_text: "Send a message to #{card.recipient_name} via your paired Mac.",
                 status: "awaiting_confirmation",
                 expires_at:
                   DateTime.add(
                     DateTime.utc_now(),
                     TelegramAssistant.confirmation_window_seconds(),
                     :second
                   )
               }) do
          {:ok,
           %{
             status: "awaiting_confirmation",
             prepared_action_id: action.id,
             requires_confirmation: true,
             draft_card: Map.put(card, :prepared_action_id, action.id),
             message: "Draft ready in the todo workspace. Review it and choose Send or Cancel."
           }}
        end
      else
        {:ok, result}
      end
    end
  end

  defp replace_draft(attrs) do
    Repo.transaction(fn ->
      Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(attrs.user_id)

      existing =
        Repo.one(
          from a in PreparedAction,
            where:
              a.user_id == ^attrs.user_id and a.action_type == "imessage_send" and
                a.payload_todo_id == ^attrs.payload["todo_id"] and
                a.status == "awaiting_confirmation",
            lock: "FOR UPDATE"
        )
        |> PreparedAction.hydrate_payload()

      if existing && existing.payload == attrs.payload &&
           not TelegramAssistant.prepared_action_expired?(existing) do
        existing
      else
        if existing do
          status =
            if TelegramAssistant.prepared_action_expired?(existing),
              do: "expired",
              else: "rejected"

          case TelegramAssistant.update_prepared_action(existing, %{
                 status: status,
                 error: "draft_replaced"
               }) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        case TelegramAssistant.create_prepared_action(attrs) do
          {:ok, action} -> action
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
  end

  def prepare(user_id, args) do
    recipient = text(args["recipient"])
    body = text(args["body"])

    with true <- valid_handle?(recipient),
         true <- is_binary(body) and byte_size(body) <= 16_384,
         {:ok, name} <- known_recipient(user_id, recipient, args["source_message_id"]) do
      {:ok,
       %{
         draft_card: %{
           provider: "imessage",
           title: "Message to #{name}",
           recipient: recipient,
           recipient_name: name,
           body: body,
           status: "Draft",
           open_label: "Review message"
         },
         message: "Draft ready for review in Messages. Nothing has been sent."
       }}
    else
      _ ->
        {:error,
         "Resolve an actual phone number or email from this user's People or Messages first; then provide a nonempty draft body."}
    end
  end

  def from_history(history) when is_list(history) do
    history
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      if value(entry, "tool") in ["draft_imessage", "draft_message"] do
        value(value(entry, "result"), "draft_card")
      end
    end)
  end

  def from_history(_), do: nil

  defp known_recipient(user_id, recipient, guid) do
    case Crm.find_person_by_contact(user_id, recipient) do
      %{display_name: name} -> {:ok, name}
      _ -> known_message_recipient(user_id, recipient, guid)
    end
  end

  defp known_message_recipient(user_id, recipient, guid) when is_binary(guid) do
    case LocalMessages.get_by_guid(user_id, guid) do
      %{sender_handle: handle, is_from_me: false} when is_binary(handle) ->
        if normalize(handle) == normalize(recipient), do: {:ok, recipient}, else: :error

      _ ->
        :error
    end
  end

  defp known_message_recipient(_, _, _), do: :error

  defp valid_handle?(handle) when is_binary(handle) do
    Regex.match?(~r/^\+?[0-9]{7,15}$/, handle) or
      Regex.match?(~r/^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/, handle)
  end

  defp valid_handle?(_), do: false
  defp normalize(handle), do: handle |> String.downcase() |> String.replace(~r/[\s()\-]/, "")

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text(_), do: nil

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  defp value(_, _), do: nil
end
