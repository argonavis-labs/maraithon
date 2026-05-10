defmodule Maraithon.Repo.Migrations.AddEmbeddingToCrmPersons do
  use Ecto.Migration

  require Logger

  @embedding_dim 1536

  def up do
    cond do
      vector_extension_present?() ->
        # Already installed (e.g. dev/test, or a superuser ran CREATE EXTENSION).
        ensure_columns()

      can_create_extension?() ->
        execute("CREATE EXTENSION IF NOT EXISTS vector")
        ensure_columns()

      true ->
        Logger.warning(
          "pgvector extension is not installed and the migration user lacks " <>
            "superuser privilege. Skipping embedding column. Install pgvector " <>
            "as a superuser, then re-run this migration."
        )
    end
  end

  def down do
    if vector_extension_present?() and embedding_column_present?() do
      execute("DROP INDEX IF EXISTS crm_people_embedding_hnsw_index")

      alter table(:crm_people) do
        remove :embedding
        remove :embedding_source_hash
        remove :embedding_refreshed_at
      end
    end

    # Leave the vector extension installed; other tables may depend on it.
  end

  defp ensure_columns do
    unless embedding_column_present?() do
      alter table(:crm_people) do
        add :embedding, :"vector(#{@embedding_dim})"
        add :embedding_source_hash, :string
        add :embedding_refreshed_at, :utc_datetime_usec
      end
    end

    execute("""
    CREATE INDEX IF NOT EXISTS crm_people_embedding_hnsw_index
    ON crm_people
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
          "WHERE table_name = 'crm_people' AND column_name = 'embedding'"
      )

    rows != []
  end

  defp can_create_extension? do
    repo().query!("CREATE EXTENSION IF NOT EXISTS vector")
    true
  rescue
    Postgrex.Error -> false
  end
end
