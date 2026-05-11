defmodule Maraithon.Repo.Migrations.AddEmbeddingToLocalReminders do
  use Ecto.Migration

  require Logger

  @disable_ddl_transaction true
  @disable_migration_lock true

  @embedding_dim 1536
  @table "local_reminders"
  @index "local_reminders_embedding_ivfflat_index"

  def up do
    cond do
      vector_extension_present?() ->
        ensure_columns()

      can_create_extension?() ->
        execute("CREATE EXTENSION IF NOT EXISTS vector")
        ensure_columns()

      true ->
        Logger.warning(
          "pgvector extension is not installed and the migration user lacks " <>
            "superuser privilege. Skipping embedding column on #{@table}."
        )
    end
  end

  def down do
    if vector_extension_present?() and embedding_column_present?() do
      execute("DROP INDEX IF EXISTS #{@index}")

      alter table(:local_reminders) do
        remove :embedding
        remove :embedding_source_hash
        remove :embedding_refreshed_at
      end
    end
  end

  defp ensure_columns do
    unless embedding_column_present?() do
      alter table(:local_reminders) do
        add :embedding, :"vector(#{@embedding_dim})"
        add :embedding_source_hash, :string
        add :embedding_refreshed_at, :utc_datetime_usec
      end
    end

    execute("""
    CREATE INDEX IF NOT EXISTS #{@index}
    ON #{@table}
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100)
    """)
  end

  defp vector_extension_present? do
    %{rows: rows} = repo().query!("SELECT 1 FROM pg_extension WHERE extname = 'vector'")
    rows != []
  end

  defp embedding_column_present? do
    %{rows: rows} =
      repo().query!(
        "SELECT 1 FROM information_schema.columns " <>
          "WHERE table_name = '#{@table}' AND column_name = 'embedding'"
      )

    rows != []
  end

  defp can_create_extension? do
    repo().query!("CREATE EXTENSION IF NOT EXISTS vector")
    true
  rescue
    _error -> false
  end
end
