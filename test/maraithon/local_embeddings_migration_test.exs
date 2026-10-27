defmodule Maraithon.LocalEmbeddingsMigrationTest do
  @moduledoc """
  Smoke test for the v5 migrations that add the pgvector `embedding`
  column + ivfflat index to each local content table.

  We don't re-drive the migrator inside the sandbox; instead we verify
  the outcome — the `embedding`, `embedding_source_hash`, and
  `embedding_refreshed_at` columns plus the per-table ivfflat index are
  present in the shared test schema after migrations have run.
  """

  use Maraithon.DataCase, async: true

  @migrations [
    {20_260_512_100_001, "20260512100001_add_embedding_to_local_messages.exs",
     Maraithon.Repo.Migrations.AddEmbeddingToLocalMessages, "local_messages",
     "local_messages_embedding_ivfflat_index"},
    {20_260_512_100_002, "20260512100002_add_embedding_to_local_notes.exs",
     Maraithon.Repo.Migrations.AddEmbeddingToLocalNotes, "local_notes",
     "local_notes_embedding_ivfflat_index"},
    {20_260_512_100_003, "20260512100003_add_embedding_to_local_voice_memos.exs",
     Maraithon.Repo.Migrations.AddEmbeddingToLocalVoiceMemos, "local_voice_memos",
     "local_voice_memos_embedding_ivfflat_index"},
    {20_260_512_100_004, "20260512100004_add_embedding_to_local_calendar_events.exs",
     Maraithon.Repo.Migrations.AddEmbeddingToLocalCalendarEvents, "local_calendar_events",
     "local_calendar_events_embedding_ivfflat_index"},
    {20_260_512_100_005, "20260512100005_add_embedding_to_local_reminders.exs",
     Maraithon.Repo.Migrations.AddEmbeddingToLocalReminders, "local_reminders",
     "local_reminders_embedding_ivfflat_index"},
    {20_260_512_100_006, "20260512100006_add_embedding_to_local_files.exs",
     Maraithon.Repo.Migrations.AddEmbeddingToLocalFiles, "local_files",
     "local_files_embedding_ivfflat_index"}
  ]

  describe "migration files" do
    test "every embedding migration file exists, defines up/0 and down/0, and loads" do
      for {version, file, module, _table, _index} <- @migrations do
        migration_path =
          :maraithon
          |> Application.app_dir("priv/repo/migrations")
          |> Path.join(file)

        assert File.exists?(migration_path),
               "expected migration file at #{migration_path}"

        if not Code.ensure_loaded?(module) do
          Code.compile_file(migration_path)
        end

        assert function_exported?(module, :up, 0),
               "#{inspect(module)} missing up/0"

        assert function_exported?(module, :down, 0),
               "#{inspect(module)} missing down/0"

        assert Path.basename(migration_path) =~ Integer.to_string(version)
      end
    end
  end

  describe "shared test schema" do
    test "every local content table grew embedding + bookkeeping columns" do
      for {_version, _file, _module, table, _index} <- @migrations do
        columns = table_columns(table)

        assert "embedding" in columns,
               "expected embedding column on #{table}, got: #{inspect(columns)}"

        assert "embedding_source_hash" in columns,
               "expected embedding_source_hash on #{table}"

        assert "embedding_refreshed_at" in columns,
               "expected embedding_refreshed_at on #{table}"
      end
    end

    test "every local content table has its ivfflat embedding index" do
      for {_version, _file, _module, _table, index} <- @migrations do
        assert index_present?(index),
               "expected ivfflat index #{index} to exist in test schema"
      end
    end
  end

  defp table_columns(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
        [name]
      )

    Enum.map(rows, fn [c] -> c end)
  end

  defp index_present?(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM pg_indexes WHERE indexname = $1",
        [name]
      )

    rows != []
  end
end
