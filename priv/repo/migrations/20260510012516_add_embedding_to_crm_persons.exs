defmodule Maraithon.Repo.Migrations.AddEmbeddingToCrmPersons do
  use Ecto.Migration

  @embedding_dim 1536

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector")

    alter table(:crm_people) do
      add :embedding, :"vector(#{@embedding_dim})"
      add :embedding_source_hash, :string
      add :embedding_refreshed_at, :utc_datetime_usec
    end

    # HNSW index gives good recall + speed for ANN search.
    # IF NOT EXISTS in case a partial deploy happened.
    execute("""
    CREATE INDEX IF NOT EXISTS crm_people_embedding_hnsw_index
    ON crm_people
    USING hnsw (embedding vector_cosine_ops)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS crm_people_embedding_hnsw_index")

    alter table(:crm_people) do
      remove :embedding
      remove :embedding_source_hash
      remove :embedding_refreshed_at
    end

    # Leave the vector extension installed; other tables may depend on it.
  end
end
