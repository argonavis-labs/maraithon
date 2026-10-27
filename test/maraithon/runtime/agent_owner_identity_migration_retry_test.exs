unless Code.ensure_loaded?(Maraithon.Repo.Migrations.AddAgentsOwnerIdentityIndexForRuntime) do
  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20260809100000_add_agents_owner_identity_index.exs",
      __DIR__
    )
  )
end

defmodule Maraithon.Runtime.AgentOwnerIdentityMigrationRetryTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Maraithon.Repo
  alias Maraithon.Repo.Migrations.AddAgentsOwnerIdentityIndexForRuntime

  test "owner identity index repairs same-name catalog damage before the downstream FK" do
    assert Repo.config()[:migration_lock] == :pg_advisory_lock
    refute AddAgentsOwnerIdentityIndexForRuntime.__migration__()[:disable_migration_lock]

    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    parent = "agent_owner_retry_#{suffix}"
    child = "agent_owner_retry_#{suffix}_child"
    index = "agent_owner_retry_#{suffix}_unique_index"
    specification = {index, parent, ["id", "user_id"]}

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("CREATE TABLE public.#{parent} (id bigint NOT NULL, user_id text NOT NULL)")

      try do
        Repo.query!(
          "INSERT INTO public.#{parent} (id, user_id) VALUES (1, 'owner'), (1, 'owner')"
        )

        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            "CREATE UNIQUE INDEX CONCURRENTLY #{index} " <>
              "ON public.#{parent} USING btree (id, user_id)"
          )
        end

        assert [[false, _ready]] = index_readiness(index)

        Repo.query!(
          "DELETE FROM public.#{parent} WHERE ctid IN " <>
            "(SELECT ctid FROM public.#{parent} LIMIT 1)"
        )

        ensure_index_and_retry!(specification, index, parent)
        create_downstream_fk!(parent, child)
        Repo.query!("DROP TABLE public.#{child}")

        Repo.query!("DROP INDEX CONCURRENTLY public.#{index}")

        Repo.query!(
          "CREATE INDEX CONCURRENTLY #{index} " <>
            "ON public.#{parent} USING btree (user_id, id)"
        )

        assert [[true, true, false, _wrong_definition]] = index_catalog(index)

        ensure_index_and_retry!(specification, index, parent)
        create_downstream_fk!(parent, child)
      after
        Repo.query!("DROP TABLE IF EXISTS public.#{child}")
        Repo.query!("DROP TABLE IF EXISTS public.#{parent} CASCADE")
      end
    end)
  end

  defp ensure_index_and_retry!(specification, index, parent) do
    AddAgentsOwnerIdentityIndexForRuntime.ensure_exact_unique_index!(specification, Repo)
    AddAgentsOwnerIdentityIndexForRuntime.ensure_exact_unique_index!(specification, Repo)
    assert_exact_valid_index(index, parent)
  end

  defp create_downstream_fk!(parent, child) do
    constraint = "#{child}_owner_fkey"

    Repo.query!("""
    CREATE TABLE public.#{child} (
      agent_id bigint NOT NULL,
      user_id text NOT NULL,
      CONSTRAINT #{constraint}
        FOREIGN KEY (agent_id, user_id)
        REFERENCES public.#{parent}(id, user_id)
        ON DELETE CASCADE
    )
    """)

    Repo.query!("INSERT INTO public.#{child} (agent_id, user_id) VALUES (1, 'owner')")

    assert [["f", true]] =
             Repo.query!(
               """
               SELECT catalog_constraint.contype::text, catalog_constraint.convalidated
               FROM pg_catalog.pg_constraint AS catalog_constraint
               WHERE catalog_constraint.conname = $1
               """,
               [constraint]
             ).rows
  end

  defp index_readiness(index) do
    Repo.query!(
      """
      SELECT catalog.indisvalid, catalog.indisready
      FROM pg_catalog.pg_index AS catalog
      JOIN pg_catalog.pg_class AS index
        ON index.oid = catalog.indexrelid
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = index.relnamespace
      WHERE namespace.nspname = 'public'
        AND index.relname = $1
      """,
      [index]
    ).rows
  end

  defp assert_exact_valid_index(index, parent) do
    expected =
      "CREATE UNIQUE INDEX #{index} ON public.#{parent} USING btree (id, user_id)"

    assert [[true, true, true, ^expected]] = index_catalog(index)
  end

  defp index_catalog(index) do
    Repo.query!(
      """
      SELECT catalog.indisvalid,
             catalog.indisready,
             catalog.indisunique,
             pg_catalog.pg_get_indexdef(catalog.indexrelid)
      FROM pg_catalog.pg_index AS catalog
      JOIN pg_catalog.pg_class AS index
        ON index.oid = catalog.indexrelid
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = index.relnamespace
      WHERE namespace.nspname = 'public'
        AND index.relname = $1
      """,
      [index]
    ).rows
  end
end
