defmodule Maraithon.TelegramConversationPrivacyTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.OperatorEvents
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.{Conversation, Privacy, Turn}
  alias Maraithon.Todos.Todo

  test "new turns and derived summaries persist only ciphertext plus promoted query metadata" do
    %{user_id: user_id, conversation: conversation} = conversation_fixture("ciphertext")
    run_id = Ecto.UUID.generate()
    action_id = Ecto.UUID.generate()
    todo_id = Ecto.UUID.generate()

    structured_data = %{
      "run_id" => run_id,
      "message_class" => "todo_item",
      "prepared_action_id" => action_id,
      "linked_todo" => %{"id" => todo_id, "title" => "Sensitive work"},
      "terminal_response" => false
    }

    assert {:ok, {updated_conversation, turn}} =
             TelegramConversations.append_turn(conversation, %{
               "role" => "assistant",
               "telegram_message_id" => "cipher-message",
               "text" => "private reply text",
               "structured_data" => structured_data
             })

    assert turn.text == "private reply text"
    assert turn.structured_data == structured_data
    assert turn.text_bytes == byte_size("private reply text")
    assert turn.assistant_run_id == run_id
    assert turn.message_class == "todo_item"
    assert turn.prepared_action_id == action_id
    assert turn.linked_todo_id == todo_id
    assert turn.terminal_response == false

    assert [[legacy_text, text_ciphertext, legacy_structured, structured_ciphertext]] =
             raw_turn_payload(turn.id)

    assert legacy_text == Turn.legacy_text_tombstone()
    assert legacy_structured == %{}
    assert is_binary(text_ciphertext)
    assert is_binary(structured_ciphertext)
    refute text_ciphertext =~ "private reply text"

    assert [[legacy_summary, summary_ciphertext]] = raw_conversation_summary(conversation.id)
    assert is_nil(legacy_summary)
    assert is_binary(summary_ciphertext)
    assert updated_conversation.summary =~ "private reply text"

    assert [event] = OperatorEvents.list_recent_for_user(user_id, 1)
    refute Map.has_key?(event.payload, "text")
    assert event.payload["text_bytes"] == byte_size("private reply text")
    assert event.payload["assistant_run_id"] == run_id
    assert event.payload["linked_todo_id"] == todo_id
  end

  test "historical summaries leave conversation metadata before persistence and hydrate transparently" do
    %{conversation: conversation} = conversation_fixture("historical")

    assert {:ok, encrypted} =
             conversation
             |> Conversation.changeset(%{
               "metadata" => %{
                 "historical_summary" => "A private historical digest.",
                 "historical_summary_through" => "2026-08-01T00:00:00Z"
               }
             })
             |> Repo.update()

    assert encrypted.historical_summary == "A private historical digest."
    refute Map.has_key?(encrypted.metadata, "historical_summary")

    assert [[metadata, ciphertext]] =
             Repo.query!(
               "SELECT metadata, historical_summary_ciphertext FROM telegram_conversations WHERE id = $1",
               [Ecto.UUID.dump!(conversation.id)]
             ).rows

    refute Map.has_key?(metadata, "historical_summary")
    assert is_binary(ciphertext)

    hydrated = TelegramConversations.latest_for_chat(conversation.chat_id)
    assert hydrated.metadata["historical_summary"] == "A private historical digest."
    assert hydrated.historical_summary == "A private historical digest."
  end

  test "turn and summary changesets reject oversized or non-JSON payloads" do
    oversized_text = String.duplicate("x", Turn.max_text_bytes() + 1)

    turn_changeset =
      Turn.changeset(%Turn{}, %{
        conversation_id: Ecto.UUID.generate(),
        role: "user",
        text: oversized_text,
        structured_data: %{}
      })

    refute turn_changeset.valid?
    assert "must be at most #{Turn.max_text_bytes()} bytes" in errors_on(turn_changeset).text

    oversized_json = %{"value" => String.duplicate("x", 64_001)}

    structured_changeset =
      Turn.changeset(%Turn{}, %{
        conversation_id: Ecto.UUID.generate(),
        role: "user",
        text: "bounded",
        structured_data: oversized_json
      })

    refute structured_changeset.valid?
    assert "must be a bounded JSON object" in errors_on(structured_changeset).structured_data

    summary_changeset =
      Conversation.changeset(%Conversation{}, %{
        user_id: "bounds@example.com",
        chat_id: "bounds-chat",
        status: "closed",
        summary: String.duplicate("s", Conversation.max_summary_bytes() + 1),
        metadata: %{}
      })

    refute summary_changeset.valid?

    assert "must be at most #{Conversation.max_summary_bytes()} bytes" in errors_on(
             summary_changeset
           ).summary
  end

  test "bounded backfill encrypts legacy rows and is idempotent" do
    %{conversation: conversation} = conversation_fixture("backfill")
    now = DateTime.utc_now()
    turn_id = Ecto.UUID.generate()

    assert {1, _} =
             Repo.insert_all(Turn, [
               %{
                 id: turn_id,
                 conversation_id: conversation.id,
                 role: "user",
                 legacy_text: "legacy private text",
                 legacy_structured_data: %{
                   "message_class" => "assistant_reply",
                   "terminal_response" => true
                 },
                 inserted_at: now,
                 updated_at: now
               }
             ])

    assert {1, _} =
             Conversation
             |> where([row], row.id == ^conversation.id)
             |> Repo.update_all(
               set: [
                 legacy_summary: "legacy summary",
                 metadata: %{"historical_summary" => "legacy historical summary"}
               ]
             )

    original_turn_updated_at = Repo.get!(Turn, turn_id).updated_at
    original_conversation_updated_at = Repo.get!(Conversation, conversation.id).updated_at

    assert %{legacy_turns: 1, legacy_conversations: 1} = Privacy.preflight()

    assert {:ok,
            %{
              migrated_turns: 1,
              migrated_conversations: 1,
              blocked_turns: [],
              blocked_conversations: []
            }} = Privacy.backfill_batch(batch_size: 10)

    assert %{legacy_turns: 0, legacy_conversations: 0} = Privacy.preflight()

    hydrated_turn = turn_id |> then(&Repo.get(Turn, &1)) |> Turn.hydrate()
    assert hydrated_turn.text == "legacy private text"
    assert hydrated_turn.message_class == "assistant_reply"
    assert hydrated_turn.updated_at == original_turn_updated_at

    assert [[legacy_text, text_ciphertext, legacy_structured, structured_ciphertext]] =
             raw_turn_payload(turn_id)

    assert legacy_text == Turn.legacy_text_tombstone()
    assert legacy_structured == %{}
    assert is_binary(text_ciphertext)
    assert is_binary(structured_ciphertext)

    hydrated_conversation =
      conversation.id |> then(&Repo.get(Conversation, &1)) |> Conversation.hydrate()

    assert hydrated_conversation.summary == "legacy summary"
    assert hydrated_conversation.metadata["historical_summary"] == "legacy historical summary"
    assert hydrated_conversation.updated_at == original_conversation_updated_at

    assert {:ok, %{migrated_turns: 0, migrated_conversations: 0}} =
             Privacy.backfill_batch(batch_size: 10)
  end

  test "multi-batch backfill reports oversized rows without starving later rows" do
    %{conversation: conversation} = conversation_fixture("blocked-backfill")
    now = DateTime.utc_now()
    blocked_id = Ecto.UUID.generate()
    valid_id = Ecto.UUID.generate()

    assert {2, _} =
             Repo.insert_all(Turn, [
               %{
                 id: blocked_id,
                 conversation_id: conversation.id,
                 role: "user",
                 legacy_text: String.duplicate("x", Turn.max_text_bytes() + 1),
                 legacy_structured_data: %{},
                 inserted_at: DateTime.add(now, -1, :second),
                 updated_at: now
               },
               %{
                 id: valid_id,
                 conversation_id: conversation.id,
                 role: "user",
                 legacy_text: "valid legacy text",
                 legacy_structured_data: %{},
                 inserted_at: now,
                 updated_at: now
               }
             ])

    assert {:ok,
            %{
              migrated_turns: 1,
              blocked_turns: [%{id: ^blocked_id}],
              remaining: %{legacy_turns: 1}
            }} = Privacy.backfill(batch_size: 1, max_batches: 5)

    assert valid_id |> then(&Repo.get!(Turn, &1)) |> Turn.hydrate() |> Map.fetch!(:text) ==
             "valid legacy text"
  end

  test "retention scrubs content but preserves IDs and refuses active work" do
    %{user_id: user_id, conversation: conversation} = conversation_fixture("retention")

    assert {:ok, {conversation, turn}} =
             TelegramConversations.append_turn(conversation, %{
               "role" => "user",
               "telegram_message_id" => "retention-message",
               "client_message_id" => "retention-client-message",
               "text" => "old private content",
               "structured_data" => %{"message_class" => "assistant_reply"}
             })

    todo =
      %Todo{}
      |> Todo.changeset(%{
        user_id: user_id,
        owner_user_id: user_id,
        source: "manual",
        title: "Active retention todo",
        summary: "Keep this conversation while the todo is active.",
        next_action: "Finish the active retention todo.",
        dedupe_key: "privacy-retention-todo-#{conversation.id}"
      })
      |> Repo.insert!()

    assert {:ok, conversation} =
             TelegramConversations.update_metadata(conversation, %{"linked_todo_id" => todo.id})

    assert {:ok, conversation} = TelegramConversations.close(conversation)
    now = DateTime.utc_now()
    old = DateTime.add(now, -3 * 86_400, :second)

    assert {1, _} =
             Turn
             |> where([row], row.id == ^turn.id)
             |> Repo.update_all(set: [inserted_at: old, updated_at: old])

    assert {1, _} =
             Conversation
             |> where([row], row.id == ^conversation.id)
             |> Repo.update_all(set: [last_turn_at: old, updated_at: old])

    run =
      %Run{}
      |> Run.changeset(%{
        user_id: user_id,
        conversation_id: conversation.id,
        chat_id: conversation.chat_id,
        surface: "telegram",
        trigger_type: "inbound_message",
        status: "running",
        model_provider: "test",
        model_name: "test",
        prompt_snapshot: %{},
        started_at: now
      })
      |> Repo.insert!()

    assert {:ok, %{scrubbed_turns: 0, scrubbed_conversations: 0}} =
             Privacy.scrub_expired(retention_days: 1, batch_size: 10, now: now)

    assert Repo.get(Turn, turn.id) |> Turn.hydrate() |> Map.fetch!(:text) ==
             "old private content"

    run
    |> Run.changeset(%{status: "completed", finished_at: now})
    |> Repo.update!()

    assert {:ok, %{scrubbed_turns: 0, scrubbed_conversations: 0}} =
             Privacy.scrub_expired(retention_days: 1, batch_size: 10, now: now)

    todo
    |> Todo.changeset(%{status: "done", closed_at: now})
    |> Repo.update!()

    assert {:ok, %{scrubbed_turns: 1, scrubbed_conversations: 1, retained_ids: true}} =
             Privacy.scrub_expired(retention_days: 1, batch_size: 10, now: now)

    retained = Repo.get!(Turn, turn.id) |> Turn.hydrate()
    assert is_nil(retained.text)
    assert retained.telegram_message_id == "retention-message"
    assert retained.client_message_id == "retention-client-message"
    assert retained.message_class == "assistant_reply"
    assert retained.text_bytes == byte_size("old private content")
    assert retained.content_scrubbed_at == now

    assert [%{source_item_id: source_item_id, dedupe_key: dedupe_key}] =
             OperatorEvents.list_recent_for_user(user_id, 1)

    assert source_item_id == turn.id
    assert dedupe_key == "telegram:conversation_turn.recorded:#{turn.id}"
  end

  defp conversation_fixture(label) do
    unique = System.unique_integer([:positive])
    user_id = "privacy-#{label}-#{unique}@example.com"
    chat_id = "privacy-#{label}-#{unique}"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, conversation} =
      TelegramConversations.start_or_continue(user_id, chat_id, %{
        "root_message_id" => "root-#{unique}"
      })

    %{user_id: user_id, conversation: conversation}
  end

  defp raw_turn_payload(turn_id) do
    Repo.query!(
      """
      SELECT text, text_ciphertext, structured_data, structured_data_ciphertext
      FROM telegram_conversation_turns
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(turn_id)]
    ).rows
  end

  defp raw_conversation_summary(conversation_id) do
    Repo.query!(
      "SELECT summary, summary_ciphertext FROM telegram_conversations WHERE id = $1",
      [Ecto.UUID.dump!(conversation_id)]
    ).rows
  end
end
