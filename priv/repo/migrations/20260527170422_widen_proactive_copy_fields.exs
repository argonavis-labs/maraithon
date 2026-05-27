defmodule Maraithon.Repo.Migrations.WidenProactiveCopyFields do
  use Ecto.Migration

  def change do
    alter table(:insights) do
      modify :summary, :text, null: false
      modify :recommended_action, :text, null: false
    end

    alter table(:todos) do
      modify :summary, :text, null: false
      modify :next_action, :text, null: false
    end
  end
end
