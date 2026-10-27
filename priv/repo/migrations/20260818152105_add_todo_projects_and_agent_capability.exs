defmodule Maraithon.Repo.Migrations.AddTodoProjectsAndAgentCapability do
  use Ecto.Migration

  def change do
    alter table(:todos) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :agent_actionability, :string, null: false, default: "needs_you"
      add :agent_action_label, :string
      add :agent_action_requires_approval, :boolean, null: false, default: true
    end

    create index(:todos, [:user_id, :project_id, :status])
    create index(:todos, [:user_id, :agent_actionability, :status])

    create constraint(:todos, :todos_agent_actionability,
             check: "agent_actionability IN ('needs_you', 'can_prepare', 'can_execute')"
           )
  end
end
