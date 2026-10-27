defmodule Maraithon.Repo.Migrations.BuildGenerationFencedEffectIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    repo().checkout(
      fn ->
        repo().query!("SELECT pg_advisory_lock(20260810, 132103)", [], timeout: :infinity)

        try do
          ensure_index("effects_claim_token_unique_index", """
          CREATE UNIQUE INDEX CONCURRENTLY effects_claim_token_unique_index
            ON public.effects (claim_token)
            WHERE claim_token IS NOT NULL
          """)

          ensure_index("effects_physical_task_identity_unique_index", """
          CREATE UNIQUE INDEX CONCURRENTLY effects_physical_task_identity_unique_index
            ON public.effects (claim_owner_node, claim_supervisor_id, claim_task_id)
            WHERE claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL
          """)

          ensure_index("effects_cancellation_reconciliation_index", """
          CREATE INDEX CONCURRENTLY effects_cancellation_reconciliation_index
            ON public.effects (
              cancellation_last_attempt_at NULLS FIRST,
              cancellation_requested_at,
              id
            )
            WHERE status = 'cancelling' AND cancellation_state = 'requested'
          """)

          ensure_index("effects_exact_pending_claim_index", """
          CREATE INDEX CONCURRENTLY effects_exact_pending_claim_index
            ON public.effects (retry_after NULLS FIRST, inserted_at, id)
            WHERE status = 'pending' AND runtime_owner_generation IS NOT NULL
          """)

          ensure_index("effects_exact_claim_expiry_index", """
          CREATE INDEX CONCURRENTLY effects_exact_claim_expiry_index
            ON public.effects (claim_expires_at, id)
            WHERE status IN ('claimed', 'executing') AND runtime_owner_generation IS NOT NULL AND
                  claim_token IS NOT NULL
          """)

          ensure_index("effects_exact_pending_llm_lane_index", """
          CREATE INDEX CONCURRENTLY effects_exact_pending_llm_lane_index
            ON public.effects (execution_lane, retry_after NULLS FIRST, inserted_at, id)
            WHERE status = 'pending' AND runtime_owner_generation IS NOT NULL AND
                  effect_type = 'llm_call'
          """)
        after
          repo().query!("SELECT pg_advisory_unlock(20260810, 132103)", [], timeout: :infinity)
        end
      end,
      timeout: :infinity
    )
  end

  def down do
    raise "generation-fenced Effect indexes are part of an irreversible protocol"
  end

  # A nontransactional concurrent build may commit every index and crash before
  # Ecto records this migration. A retry preserves an already-valid exact
  # index. A session advisory lock serializes concurrent migrators;
  # destructive repair is also serialized with activation by a protocol-row
  # SHARE lock and is permitted only while mode remains legacy. Concurrent DDL
  # uses an unlimited migration query timeout and remains retry-safe on crash.
  defp ensure_index(name, create_sql) do
    case prepare_index_build(name) do
      :skip -> :ok
      :create -> repo().query!(create_sql, [], timeout: :infinity)
    end
  end

  defp prepare_index_build(name) do
    case repo().transaction(
           fn ->
             mode =
               case repo().query!(
                      "SELECT mode FROM public.effect_execution_protocols WHERE name = 'effects' FOR SHARE",
                      [],
                      timeout: :infinity
                    ).rows do
                 [[mode]] -> mode
                 _unknown -> repo().rollback(:effect_protocol_unavailable)
               end

             case index_state(name) do
               :expected ->
                 :skip

               :missing when mode == "legacy" ->
                 # Never drop a missing index: another concurrent migrator may
                 # build it before this process reaches CREATE.
                 :create

               :invalid_or_mismatched when mode == "legacy" ->
                 # A regular DROP is transactional and remains protected by the
                 # protocol-row lock. CREATE itself must run concurrently after
                 # this short transaction commits.
                 repo().query!("DROP INDEX public.#{name}", [], timeout: :infinity)
                 :create

               state when mode == "generation_fenced_v1" ->
                 raise "refusing to repair #{name} (#{state}) after exact Effect activation"

               _unknown ->
                 repo().rollback(:effect_protocol_unavailable)
             end
           end,
           timeout: :infinity
         ) do
      {:ok, action} -> action
      {:error, reason} -> raise "cannot prepare exact Effect index build: #{inspect(reason)}"
    end
  end

  defp index_state(name) do
    case repo().query!(
           """
           SELECT
             pg_catalog.to_regclass('public.' || $1) IS NOT NULL,
             public.generation_fenced_effect_index_matches($1)
           """,
           [name],
           timeout: :infinity
         ).rows do
      [[true, true]] -> :expected
      [[false, false]] -> :missing
      _invalid_or_mismatched -> :invalid_or_mismatched
    end
  end
end
