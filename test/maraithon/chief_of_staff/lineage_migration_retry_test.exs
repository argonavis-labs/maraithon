unless Code.ensure_loaded?(Maraithon.Repo.Migrations.AddChiefLineageOwnerIndexes) do
  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20260809170000_add_chief_lineage_owner_indexes.exs",
      __DIR__
    )
  )
end

defmodule Maraithon.ChiefOfStaff.LineageMigrationRetryTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Maraithon.Repo
  alias Maraithon.Repo.Migrations.AddChiefLineageOwnerIndexes

  test "owner indexes use advisory locking and recover invalid, wrong, or missing catalog rows" do
    assert Repo.config()[:migration_lock] == :pg_advisory_lock
    refute AddChiefLineageOwnerIndexes.__migration__()[:disable_migration_lock]

    suffix = System.unique_integer([:positive])
    table = "chief_lineage_index_retry_#{suffix}"
    index = "chief_lineage_index_retry_#{suffix}_unique_index"
    specification = {index, table, ["owner_id", "owner_key"]}

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("CREATE TABLE public.#{table} (owner_id bigint, owner_key text)")

      try do
        Repo.query!(
          "INSERT INTO public.#{table} (owner_id, owner_key) VALUES (1, 'same'), (1, 'same')"
        )

        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            "CREATE UNIQUE INDEX CONCURRENTLY #{index} " <>
              "ON public.#{table} USING btree (owner_id, owner_key)"
          )
        end

        assert [[false, _ready]] =
                 Repo.query!(
                   """
                   SELECT catalog.indisvalid, catalog.indisready
                   FROM pg_catalog.pg_index AS catalog
                   JOIN pg_catalog.pg_class AS index
                     ON index.oid = catalog.indexrelid
                   WHERE index.relname = $1
                   """,
                   [index]
                 ).rows

        Repo.query!(
          "DELETE FROM public.#{table} WHERE ctid IN " <>
            "(SELECT ctid FROM public.#{table} LIMIT 1)"
        )

        AddChiefLineageOwnerIndexes.ensure_exact_unique_index!(specification, Repo)
        assert_exact_valid_index(index, table)

        Repo.query!("DROP INDEX CONCURRENTLY public.#{index}")

        Repo.query!(
          "CREATE INDEX CONCURRENTLY #{index} " <>
            "ON public.#{table} USING btree (owner_key, owner_id)"
        )

        AddChiefLineageOwnerIndexes.ensure_exact_unique_index!(specification, Repo)
        assert_exact_valid_index(index, table)

        Repo.query!("DROP INDEX CONCURRENTLY public.#{index}")
        AddChiefLineageOwnerIndexes.ensure_exact_unique_index!(specification, Repo)
        assert_exact_valid_index(index, table)
      after
        Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
      end
    end)
  end

  defp assert_exact_valid_index(index, table) do
    expected =
      "CREATE UNIQUE INDEX #{index} ON public.#{table} USING btree (owner_id, owner_key)"

    assert [[true, true, true, ^expected]] =
             Repo.query!(
               """
               SELECT catalog.indisvalid,
                      catalog.indisready,
                      catalog.indisunique,
                      pg_catalog.pg_get_indexdef(catalog.indexrelid)
               FROM pg_catalog.pg_index AS catalog
               JOIN pg_catalog.pg_class AS index
                 ON index.oid = catalog.indexrelid
               WHERE index.relname = $1
               """,
               [index]
             ).rows
  end
end
