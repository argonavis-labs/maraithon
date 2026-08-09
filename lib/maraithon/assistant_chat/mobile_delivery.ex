defmodule Maraithon.AssistantChat.MobileDelivery do
  @moduledoc """
  Assistant delivery for native mobile chat: persist the turn (the app
  renders it from the thread), then nudge the phone with a push so replies
  land even when the app is backgrounded instead of depending on foreground
  polling. The push is best-effort — a persisted turn is already delivered
  from the product's point of view.
  """

  alias Maraithon.Push.Notifier, as: MobilePush
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramConversations.Conversation

  require Logger

  def deliver_turn(%Conversation{} = conversation, chat_id, text, opts \\ [])
      when is_binary(chat_id) and is_binary(text) do
    opts =
      opts
      |> Keyword.put(:send_mode, :persist)
      |> Keyword.put_new(:delivery_state, "delivered")

    result = TelegramAssistant.send_turn(conversation, chat_id, text, opts)

    with {:ok, _conversation, _turn, delivery} <- result,
         true <- local_turn_inserted?(delivery) do
      notify_device(conversation, text)
    end

    result
  end

  defp local_turn_inserted?(delivery) when is_map(delivery),
    do: Map.get(delivery, "_maraithon_local_turn_inserted", true)

  defp local_turn_inserted?(_delivery), do: true

  defp notify_device(%Conversation{user_id: user_id} = conversation, text)
       when is_binary(user_id) do
    if MobilePush.enabled_for_user?(user_id) do
      # Collapse per conversation: a multi-turn reply shows one banner with
      # the latest text, not a stack.
      _ =
        MobilePush.notify(user_id, %{
          title: "Maraithon",
          body: text,
          deeplink: "maraithon://chat/#{conversation.id}",
          thread_id: "chat:#{conversation.id}",
          collapse_id: "chat:#{conversation.id}"
        })
    end

    :ok
  rescue
    error ->
      Logger.warning("Mobile chat push failed",
        conversation_id: conversation.id,
        reason: Exception.message(error)
      )

      :ok
  end

  defp notify_device(_conversation, _text), do: :ok
end
