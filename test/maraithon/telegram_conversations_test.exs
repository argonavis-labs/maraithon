defmodule Maraithon.TelegramConversationsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.OperatorEvents
  alias Maraithon.TelegramConversations

  test "append_turn emits a canonical operator event for the persisted turn" do
    user_id = "telegram-conversations@example.com"
    chat_id = "chat-123"

    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, conversation} =
      TelegramConversations.start_or_continue(user_id, chat_id, %{"root_message_id" => "root-1"})

    {:ok, {_conversation, turn}} =
      TelegramConversations.append_turn(conversation, %{
        "role" => "user",
        "telegram_message_id" => "message-1",
        "text" => "What matters today?"
      })

    assert [%{source_item_id: source_item_id} = event] =
             OperatorEvents.list_recent_for_user(user_id, 1)

    assert source_item_id == turn.id
    assert event.source == "telegram"
    assert event.event_type == "conversation_turn.recorded"
    assert event.payload["text"] == "What matters today?"
  end
end
