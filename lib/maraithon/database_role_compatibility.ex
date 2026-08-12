defmodule Maraithon.DatabaseRoleCompatibility do
  @moduledoc """
  Keeps additive durable-runtime migrations deployable on Fly Managed Postgres.

  Fly MPG authenticates named users but exposes the fixed `schema_admin` role to
  PostgreSQL and does not permit customers to create the six canonical roles.
  The durable runtime remains feature-dark on this provider: migration DDL is
  mapped to `schema_admin`, while the canonical role-readiness proof is forced
  false so neither exact protocol can be activated without real role separation.
  """

  @canonical_roles ~w(
    maraithon_object_owner
    maraithon_migrator
    maraithon_runtime
    maraithon_payload_verifier
    maraithon_incident_operator
    maraithon_activation_operator
  )

  @spec rewrite_migration_sql(binary()) :: binary()
  def rewrite_migration_sql(statement) when is_binary(statement) do
    if fly_managed_postgres?() do
      rewrite_fly_mpg(statement)
    else
      statement
    end
  end

  @spec fly_managed_postgres?() :: boolean()
  def fly_managed_postgres? do
    database_url = System.get_env("DATABASE_URL", "")

    case URI.parse(database_url) do
      %URI{host: host} when is_binary(host) ->
        host == "flympg.net" or String.ends_with?(host, ".flympg.net")

      _other ->
        false
    end
  rescue
    _error -> false
  end

  defp rewrite_fly_mpg(statement) do
    cond do
      String.contains?(
        statement,
        "CREATE OR REPLACE FUNCTION public.runtime_coordination_roles_ready()"
      ) ->
        """
        CREATE OR REPLACE FUNCTION public.runtime_coordination_roles_ready()
        RETURNS boolean
        LANGUAGE sql
        STABLE
        SET search_path = pg_catalog, public
        AS $function$
          SELECT false
        $function$;
        """

      String.contains?(statement, "DO $role_topology$") ->
        "SELECT 1"

      String.contains?(
        statement,
        "CREATE OR REPLACE FUNCTION public.guard_durable_payload_operator_source_mutation()"
      ) ->
        """
        CREATE OR REPLACE FUNCTION public.guard_durable_payload_operator_source_mutation()
        RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog, public
        AS $function$
        BEGIN
          -- Fly MPG collapses runtime and operator identities into schema_admin.
          -- Exact protocols remain permanently feature-dark on this provider,
          -- so ordinary legacy writes must not be mistaken for operator writes.
          RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
        END;
        $function$;
        """

      String.trim(statement) == "SELECT 'maraithon_fly_mpg_restore_migration_authority'" ->
        """
        DO $fly_mpg_restore_migration_authority$
        DECLARE
          owned_function regprocedure;
        BEGIN
          GRANT ALL ON SCHEMA public TO schema_admin;
          GRANT ALL ON ALL TABLES IN SCHEMA public TO schema_admin;
          GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO schema_admin;

          FOR owned_function IN
            SELECT function_row.oid::regprocedure
            FROM pg_catalog.pg_proc AS function_row
            JOIN pg_catalog.pg_namespace AS namespace
              ON namespace.oid = function_row.pronamespace
            JOIN pg_catalog.pg_roles AS owner_role
              ON owner_role.oid = function_row.proowner
            WHERE namespace.nspname = 'public'
              AND owner_role.rolname = current_user
          LOOP
            EXECUTE pg_catalog.format(
              'GRANT EXECUTE ON FUNCTION %s TO schema_admin', owned_function
            );
          END LOOP;
        END
        $fly_mpg_restore_migration_authority$;
        """

      String.trim(statement) == "CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public" ->
        """
        DO $fly_mpg_authority$
        DECLARE
          owned_function regprocedure;
        BEGIN
          GRANT ALL ON SCHEMA public TO schema_admin;
          GRANT ALL ON ALL TABLES IN SCHEMA public TO schema_admin;
          GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO schema_admin;

          FOR owned_function IN
            SELECT function_row.oid::regprocedure
            FROM pg_catalog.pg_proc AS function_row
            JOIN pg_catalog.pg_namespace AS namespace
              ON namespace.oid = function_row.pronamespace
            JOIN pg_catalog.pg_roles AS owner_role
              ON owner_role.oid = function_row.proowner
            WHERE namespace.nspname = 'public'
              AND owner_role.rolname = current_user
          LOOP
            EXECUTE pg_catalog.format(
              'GRANT EXECUTE ON FUNCTION %s TO schema_admin', owned_function
            );
          END LOOP;
        END
        $fly_mpg_authority$;
        """

      String.trim(statement) == "SELECT public.refresh_durable_payload_protocol_manifest()" ->
        """
        DO $fly_mpg_manifest$
        BEGIN
          GRANT EXECUTE ON FUNCTION public.refresh_durable_payload_protocol_manifest()
            TO schema_admin;
          PERFORM public.refresh_durable_payload_protocol_manifest();
        END
        $fly_mpg_manifest$;
        """

      true ->
        Enum.reduce(@canonical_roles, statement, fn role, sql ->
          String.replace(sql, role, "schema_admin")
        end)
    end
  end
end
