defmodule Maraithon.AssistantChat.MobileDelivery do
  @moduledoc """
  Persist-only assistant delivery for native mobile chat.
  """

  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramConversations.Conversation

  def deliver_turn(%Conversation{} = conversation, chat_id, text, opts \\ [])
      when is_binary(chat_id) and is_binary(text) do
    opts =
      opts
      |> Keyword.put(:send_mode, :persist)
      |> Keyword.put_new(:delivery_state, "delivered")

    TelegramAssistant.send_turn(conversation, chat_id, text, opts)
  end
end
