defmodule Maraithon.Repo.Migrations.AddBodyToLocalNotes do
  use Ecto.Migration

  def change do
    alter table(:local_notes) do
      # Cloak-encrypted plaintext body. Nullable because legacy rows and
      # rows where the companion failed to decode the typedstream blob
      # should still store the title/snippet pair.
      add :body, :binary
      # Marker for the encoding the companion shipped. Today the only
      # value is "plain"; reserved to disambiguate future RTF / Markdown
      # payloads without another migration.
      add :body_format, :string, null: false, default: "plain"
    end
  end
end
