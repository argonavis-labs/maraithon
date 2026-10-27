defmodule Maraithon.Repo.Migrations.AddMobileAssistantChatSurface do
  use Ecto.Migration

  def change do
    alter table(:telegram_conversations) do
      add :surface, :string, null: false, default: "telegram"
    end

    alter table(:telegram_conversation_turns) do
      add :client_message_id, :string
      add :delivery_state, :string, null: false, default: "delivered"
    end

    alter table(:telegram_assistant_runs) do
      add :surface, :string, null: false, default: "telegram"
    end

    alter table(:telegram_prepared_actions) do
      add :surface, :string, null: false, default: "telegram"
    end

    create index(:telegram_conversations, [:user_id, :surface, :last_turn_at])

    create unique_index(:telegram_conversation_turns, [:conversation_id, :client_message_id],
             where: "client_message_id IS NOT NULL"
           )

    create index(:telegram_assistant_runs, [:user_id, :surface, :started_at])
    create index(:telegram_prepared_actions, [:user_id, :surface, :status])
  end
end
