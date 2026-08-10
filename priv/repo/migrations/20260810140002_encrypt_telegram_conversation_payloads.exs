defmodule Maraithon.Repo.Migrations.EncryptTelegramConversationPayloads do
  use Ecto.Migration

  @moduledoc """
  Adds the encrypted conversation payload rollout columns without rewriting or
  backfilling existing rows.

  The application dual-writes the nullable Cloak ciphertext columns and legacy
  plaintext columns during expansion. A bounded, stopped-fleet operator
  contraction later clears plaintext only after each row is encrypted.
  """

  def up do
    alter table(:telegram_conversation_turns) do
      add :text_ciphertext, :binary
      add :structured_data_ciphertext, :binary
      add :text_bytes, :integer
      add :assistant_run_id, :binary_id
      add :message_class, :string
      add :prepared_action_id, :binary_id
      add :linked_todo_id, :binary_id
      add :terminal_response, :boolean
      add :content_scrubbed_at, :utc_datetime_usec
    end

    alter table(:telegram_conversations) do
      add :summary_ciphertext, :binary
      add :historical_summary_ciphertext, :binary
      add :content_scrubbed_at, :utc_datetime_usec
    end

    execute """
    ALTER TABLE telegram_conversation_turns
    ADD CONSTRAINT telegram_conversation_turns_text_bytes_bound
    CHECK (text_bytes IS NULL OR text_bytes BETWEEN 0 AND 64000) NOT VALID
    """

    execute """
    ALTER TABLE telegram_conversation_turns
    ADD CONSTRAINT telegram_conversation_turns_message_class_bound
    CHECK (message_class IS NULL OR octet_length(message_class) BETWEEN 1 AND 100) NOT VALID
    """

    create index(
             :telegram_conversation_turns,
             [:conversation_id, :assistant_run_id, :message_class],
             where: "assistant_run_id IS NOT NULL",
             name: :telegram_conversation_turns_run_message_class_index
           )

    create index(:telegram_conversation_turns, [:prepared_action_id],
             where: "prepared_action_id IS NOT NULL",
             name: :telegram_conversation_turns_prepared_action_id_index
           )

    create index(:telegram_conversation_turns, [:linked_todo_id],
             where: "linked_todo_id IS NOT NULL",
             name: :telegram_conversation_turns_linked_todo_id_index
           )

    create index(:telegram_conversation_turns, [:inserted_at, :id],
             where: "content_scrubbed_at IS NULL",
             name: :telegram_conversation_turns_unscrubbed_retention_index
           )

    create index(:telegram_conversations, [:last_turn_at, :id],
             where: "status = 'closed' AND content_scrubbed_at IS NULL",
             name: :telegram_conversations_unscrubbed_retention_index
           )
  end

  def down do
    raise """
    irreversible migration: conversation plaintext may have been cleared after
    ciphertext promotion; dropping these columns could destroy retained data
    """
  end
end
