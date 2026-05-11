defmodule Maraithon.Companion.DeviceKeysMigrationTest do
  @moduledoc """
  Smoke test for the migration that introduces
  `companion_device_keys` plus the additive
  `encrypted_with_device_key` + `key_id` columns on every local_* mirror
  table.

  Like `releases_migration_test`, we verify the *outcome* (tables +
  columns + indexes are present in the shared test schema) rather than
  re-driving the migrator inside the sandbox.
  """

  use Maraithon.DataCase, async: true

  @migration_version 20_260_512_000_000
  @migration_file "20260512000000_add_device_keys_and_encryption_flags.exs"

  @encrypted_tables ~w(
    local_messages
    local_notes
    local_voice_memos
    local_calendar_events
    local_reminders
    local_files
  )

  test "migration file exists, defines change/0, and is loadable" do
    migration_path =
      :maraithon
      |> Application.app_dir("priv/repo/migrations")
      |> Path.join(@migration_file)

    assert File.exists?(migration_path),
           "expected migration file at #{migration_path}"

    if not Code.ensure_loaded?(Maraithon.Repo.Migrations.AddDeviceKeysAndEncryptionFlags) do
      Code.compile_file(migration_path)
    end

    assert function_exported?(
             Maraithon.Repo.Migrations.AddDeviceKeysAndEncryptionFlags,
             :change,
             0
           )

    assert Path.basename(migration_path) =~ Integer.to_string(@migration_version)
  end

  test "companion_device_keys table is present after migrations run" do
    assert table_exists?("companion_device_keys")

    columns = table_columns("companion_device_keys")
    expected = ~w(id user_id device_id key_id public_key revoked_at inserted_at updated_at)

    for column <- expected do
      assert column in columns, "expected column #{column} on companion_device_keys"
    end
  end

  test "every local_* mirror table grew the encryption flag columns" do
    for table <- @encrypted_tables do
      assert table_exists?(table)
      columns = table_columns(table)
      assert "encrypted_with_device_key" in columns, "missing column on #{table}"
      assert "key_id" in columns, "missing key_id on #{table}"
    end
  end

  defp table_exists?(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.tables WHERE table_name = $1",
        [name]
      )

    rows != []
  end

  defp table_columns(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
        [name]
      )

    Enum.map(rows, fn [c] -> c end)
  end
end
