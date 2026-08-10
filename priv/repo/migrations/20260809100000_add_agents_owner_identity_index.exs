defmodule Maraithon.Repo.Migrations.AddAgentsOwnerIdentityIndexForRuntime do
  use Ecto.Migration

  # PostgreSQL's advisory migration lock is configured on Maraithon.Repo. It
  # serializes the migration/version write without wrapping this concurrent
  # index build in a transaction, and a crashed session releases it safely.
  @disable_ddl_transaction true

  @index {"agents_id_user_id_unique_index", "agents", ["id", "user_id"]}

  def up do
    ensure_exact_unique_index!(@index, repo())
  end

  def down do
    {name, _table, _columns} = @index
    repo().query!("DROP INDEX CONCURRENTLY IF EXISTS public.#{name}")
  end

  @doc false
  def ensure_exact_unique_index!({name, table, columns} = specification, query_repo) do
    validate_identifiers!([name, table | columns])

    unless exact_index?(specification, query_repo) do
      # CREATE INDEX CONCURRENTLY can leave an INVALID same-name catalog row
      # when its backend crashes. IF NOT EXISTS would silently preserve it, so
      # always remove any invalid or definition-mismatched object first.
      query_repo.query!("DROP INDEX CONCURRENTLY IF EXISTS public.#{name}")

      query_repo.query!(
        "CREATE UNIQUE INDEX CONCURRENTLY #{name} " <>
          "ON public.#{table} USING btree (#{Enum.join(columns, ", ")})"
      )

      unless exact_index?(specification, query_repo) do
        raise "concurrent owner index #{name} did not reach its exact valid definition"
      end
    end
  end

  defp exact_index?({name, table, columns}, query_repo) do
    expected_definition =
      "CREATE UNIQUE INDEX #{name} ON public.#{table} USING btree (#{Enum.join(columns, ", ")})"

    case query_repo.query!(
           """
           SELECT index.indisvalid,
                  index.indisready,
                  index.indisunique,
                  pg_catalog.pg_get_indexdef(index.indexrelid)
           FROM pg_catalog.pg_index AS index
           JOIN pg_catalog.pg_class AS catalog_index
             ON catalog_index.oid = index.indexrelid
           JOIN pg_catalog.pg_namespace AS namespace
             ON namespace.oid = catalog_index.relnamespace
           WHERE namespace.nspname = 'public'
             AND catalog_index.relname = $1
           """,
           [name]
         ).rows do
      [[true, true, true, ^expected_definition]] -> true
      _missing_invalid_or_wrong -> false
    end
  end

  defp validate_identifiers!(identifiers) do
    unless Enum.all?(identifiers, &Regex.match?(~r/^[a-z][a-z0-9_]*$/, &1)) do
      raise ArgumentError, "unsafe concurrent index identifier"
    end
  end
end
