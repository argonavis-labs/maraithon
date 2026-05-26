defmodule Maraithon.AssistantChat.TelegramDelivery do
  @moduledoc """
  Telegram delivery adapter for the shared assistant chat boundary.
  """

  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramConversations.Conversation

  def deliver_turn(%Conversation{} = conversation, chat_id, text, opts \\ [])
      when is_binary(chat_id) and is_binary(text) do
    TelegramAssistant.send_turn(conversation, chat_id, text, opts)
  end
end
