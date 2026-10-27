defmodule Maraithon.Repo.Migrations.AddEmbeddingToTodos do
  use Ecto.Migration

  require Logger

  @disable_ddl_transaction true
  @disable_migration_lock true

  @embedding_dim 1536
  @table "todos"
  @index "todos_embedding_hnsw_index"

  # Mirrors 20260510012516_add_embedding_to_crm_persons.exs and the
  # 20260512100001_add_embedding_to_local_messages.exs family: writes go
  # through Maraithon.LocalEmbeddings (raw SQL), so the Todo schema
  # intentionally does not declare `embedding` as an Ecto field. All
  # LocalEmbeddings write/read helpers no-op when this column is absent,
  # so semantic todo dedupe degrades gracefully on environments without
  # pgvector installed.
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
            "superuser privilege. Skipping embedding column on #{@table}. Install " <>
            "pgvector as a superuser, then re-run this migration."
        )
    end
  end

  def down do
    if vector_extension_present?() and embedding_column_present?() do
      execute("DROP INDEX IF EXISTS #{@index}")

      alter table(:todos) do
        remove :embedding
        remove :embedding_source_hash
        remove :embedding_refreshed_at
      end
    end
  end

  defp ensure_columns do
    unless embedding_column_present?() do
      alter table(:todos) do
        add :embedding, :"vector(#{@embedding_dim})"
        add :embedding_source_hash, :string
        add :embedding_refreshed_at, :utc_datetime_usec
      end
    end

    execute("""
    CREATE INDEX IF NOT EXISTS #{@index}
    ON #{@table}
    USING hnsw (embedding vector_cosine_ops)
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
