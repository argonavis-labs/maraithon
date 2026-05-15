defmodule Maraithon.Repo.Migrations.TruncateAndDecryptUserContent do
  @moduledoc """
  Strips `Maraithon.Encrypted.Binary` (Cloak) from the body / title / text
  fields of the four user-content sources so the server stores plaintext.
  This unblocks inference / semantic search / `LIKE` lookups that the
  random-IV ciphertext blocked.

  Strategy: TRUNCATE the four tables (no in-place decode of existing
  Cloak rows — companion devices will repopulate from their local Mac
  databases on the next sync) and DROP/ADD each previously-encrypted
  column with the `:text` type.

  Scope is deliberately the four user-content schemas listed in the
  rollback decision. OAuth tokens and other Cloak fields stay
  encrypted.

  Reversible: `down` drops and re-adds the columns as `:binary`. Old
  Cloak data is not recoverable in either direction.
  """

  use Ecto.Migration

  @tables ~w(local_notes local_reminders local_voice_memos local_messages)

  @columns %{
    "local_notes" => ~w(title snippet body)a,
    "local_reminders" => ~w(title notes)a,
    "local_voice_memos" => ~w(title snippet transcript)a,
    "local_messages" => ~w(sender_handle text)a
  }

  def up do
    execute "TRUNCATE #{Enum.join(@tables, ", ")} RESTART IDENTITY"

    for {table, columns} <- @columns do
      alter table(String.to_atom(table)) do
        for column <- columns, do: remove(column)
      end

      alter table(String.to_atom(table)) do
        for column <- columns, do: add(column, :text)
      end
    end
  end

  def down do
    execute "TRUNCATE #{Enum.join(@tables, ", ")} RESTART IDENTITY"

    for {table, columns} <- @columns do
      alter table(String.to_atom(table)) do
        for column <- columns, do: remove(column)
      end

      alter table(String.to_atom(table)) do
        for column <- columns, do: add(column, :binary)
      end
    end
  end
end
