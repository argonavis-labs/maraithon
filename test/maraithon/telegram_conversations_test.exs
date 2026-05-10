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

  describe "compact_old_turns/2" do
    setup do
      user_id = "telegram-compact-#{System.unique_integer([:positive])}@example.com"
      chat_id = "chat-#{System.unique_integer([:positive])}"

      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, conversation} =
        TelegramConversations.start_or_continue(user_id, chat_id, %{
          "root_message_id" => "root-#{System.unique_integer([:positive])}"
        })

      %{user_id: user_id, conversation: conversation}
    end

    test "is a no-op when the conversation has fewer than threshold turns",
         %{conversation: conversation} do
      Enum.each(1..5, fn index ->
        {:ok, _} =
          TelegramConversations.append_turn(conversation, %{
            "role" => if(rem(index, 2) == 0, do: "assistant", else: "user"),
            "telegram_message_id" => "m-#{System.unique_integer([:positive])}",
            "text" => "turn #{index}"
          })
      end)

      conversation = TelegramConversations.preload(conversation)

      llm = fn _params -> {:error, :should_not_be_called} end

      assert {:ok, _conversation} =
               TelegramConversations.compact_old_turns(conversation,
                 keep_recent: 2,
                 threshold_extra: 100,
                 llm_complete: llm
               )
    end

    test "writes a historical_summary into metadata when there are enough turns",
         %{conversation: conversation} do
      Enum.each(1..30, fn index ->
        {:ok, _} =
          TelegramConversations.append_turn(conversation, %{
            "role" => if(rem(index, 2) == 0, do: "assistant", else: "user"),
            "telegram_message_id" => "m-#{System.unique_integer([:positive])}",
            "text" => "turn #{index}"
          })
      end)

      conversation = TelegramConversations.preload(conversation)

      llm = fn _params ->
        {:ok, %{content: "Summary of older turns: discussed scheduling and follow-ups."}}
      end

      assert {:ok, updated} =
               TelegramConversations.compact_old_turns(conversation,
                 keep_recent: 8,
                 threshold_extra: 4,
                 llm_complete: llm
               )

      summary = updated.metadata["historical_summary"]
      assert is_binary(summary)
      assert summary =~ "Summary of older turns"
      assert is_binary(updated.metadata["historical_summary_through"])
    end

    test "returns the conversation unchanged when the LLM fails",
         %{conversation: conversation} do
      Enum.each(1..30, fn index ->
        {:ok, _} =
          TelegramConversations.append_turn(conversation, %{
            "role" => "user",
            "telegram_message_id" => "m-#{System.unique_integer([:positive])}",
            "text" => "turn #{index}"
          })
      end)

      conversation = TelegramConversations.preload(conversation)

      llm = fn _params -> {:error, :boom} end

      assert {:ok, updated} =
               TelegramConversations.compact_old_turns(conversation,
                 keep_recent: 8,
                 threshold_extra: 4,
                 llm_complete: llm
               )

      refute Map.has_key?(updated.metadata || %{}, "historical_summary")
    end
  end
end
