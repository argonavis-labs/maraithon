defmodule Maraithon.Repo.Migrations.HardenChiefLineageTransitions do
  use Ecto.Migration

  def change do
    create constraint(:chief_acquisition_runs, :chief_acquisition_runs_failure_code_check,
             check: """
             failure_code IS NULL OR failure_code IN (
               'page_limit','budget_exhausted','provider_retryable','consent_revoked',
               'claim_lost','invalid_page','provider_failed'
             )
             """
           )

    execute(
      """
      CREATE FUNCTION public.reject_immutable_chief_lineage_update()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      BEGIN
        RAISE EXCEPTION 'immutable production lineage row: %', TG_TABLE_NAME
          USING ERRCODE = '23514';
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.reject_immutable_chief_lineage_update() CASCADE"
    )

    for table <- [
          :runtime_ingress_receipts,
          :chief_acquisition_pages,
          :chief_source_envelopes,
          :chief_acquisition_envelopes,
          :chief_semantic_effects,
          :chief_semantic_effect_sources,
          :chief_decisions,
          :agent_work_result_acquisitions,
          :source_cursor_advancements,
          :chief_projection_receipts
        ] do
      execute(
        """
        CREATE TRIGGER #{table}_immutable_update
        BEFORE UPDATE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION public.reject_immutable_chief_lineage_update()
        """,
        "DROP TRIGGER IF EXISTS #{table}_immutable_update ON #{table}"
      )
    end

    execute(
      """
      CREATE FUNCTION public.guard_chief_acquisition_page_insert()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      DECLARE
        acquisition public.chief_acquisition_runs%ROWTYPE;
        previous_page public.chief_acquisition_pages%ROWTYPE;
      BEGIN
        SELECT * INTO acquisition
        FROM public.chief_acquisition_runs
        WHERE id = NEW.acquisition_run_id
        FOR UPDATE;

        IF NOT FOUND THEN
          RETURN NEW;
        END IF;

        IF acquisition.status <> 'fetching' THEN
          RAISE EXCEPTION 'sealed chief acquisition cannot accept pages' USING ERRCODE = '23514';
        END IF;

        IF acquisition.pagination_exhausted OR EXISTS (
          SELECT 1
          FROM public.chief_acquisition_pages page
          WHERE page.acquisition_run_id = acquisition.id
            AND page.terminal
        ) THEN
          RAISE EXCEPTION 'terminal chief acquisition page permanently exhausts pagination'
            USING ERRCODE = '23514';
        END IF;

        IF NEW.ordinal <> acquisition.page_count THEN
          RAISE EXCEPTION 'chief acquisition page ordinal is not contiguous'
            USING ERRCODE = '23514';
        END IF;

        IF NEW.ordinal = 0 THEN
          IF NEW.request_cursor IS DISTINCT FROM acquisition.start_cursor THEN
            RAISE EXCEPTION 'first chief acquisition page cursor does not match start cursor'
              USING ERRCODE = '23514';
          END IF;
        ELSE
          SELECT * INTO previous_page
          FROM public.chief_acquisition_pages
          WHERE acquisition_run_id = acquisition.id
            AND ordinal = NEW.ordinal - 1;

          IF NOT FOUND OR previous_page.terminal OR
             NEW.request_cursor IS DISTINCT FROM previous_page.next_cursor THEN
            RAISE EXCEPTION 'chief acquisition page cursor chain is broken'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.guard_chief_acquisition_page_insert() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER chief_acquisition_pages_insert_guard
      BEFORE INSERT ON chief_acquisition_pages
      FOR EACH ROW EXECUTE FUNCTION public.guard_chief_acquisition_page_insert()
      """,
      "DROP TRIGGER IF EXISTS chief_acquisition_pages_insert_guard ON chief_acquisition_pages"
    )

    execute(
      """
      CREATE FUNCTION public.guard_chief_acquisition_envelope_insert()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      DECLARE
        acquisition public.chief_acquisition_runs%ROWTYPE;
        page_ordinal integer;
      BEGIN
        SELECT * INTO acquisition
        FROM public.chief_acquisition_runs
        WHERE id = NEW.acquisition_run_id
        FOR UPDATE;

        IF NOT FOUND THEN
          RETURN NEW;
        END IF;

        SELECT ordinal INTO page_ordinal
        FROM public.chief_acquisition_pages page
        WHERE page.id = NEW.acquisition_page_id
          AND page.acquisition_run_id = NEW.acquisition_run_id;

        IF acquisition.status <> 'fetching' OR
           page_ordinal IS DISTINCT FROM acquisition.page_count THEN
          RAISE EXCEPTION 'chief acquisition envelope proof set is closed'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.guard_chief_acquisition_envelope_insert() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER chief_acquisition_envelopes_insert_guard
      BEFORE INSERT ON chief_acquisition_envelopes
      FOR EACH ROW EXECUTE FUNCTION public.guard_chief_acquisition_envelope_insert()
      """,
      "DROP TRIGGER IF EXISTS chief_acquisition_envelopes_insert_guard ON chief_acquisition_envelopes"
    )

    execute(
      """
      CREATE FUNCTION public.guard_chief_acquisition_run_transition()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      DECLARE
        persisted_page_count bigint;
        persisted_terminal_count bigint;
        persisted_item_count bigint;
        persisted_link_count bigint;
        minimum_ordinal integer;
        maximum_ordinal integer;
      BEGIN
        IF ROW(
          NEW.id, NEW.acquisition_key, NEW.user_id, NEW.agent_id,
          NEW.agent_directive_id, NEW.runtime_ingress_receipt_id,
          NEW.connected_account_id, NEW.source_cursor_id, NEW.cursor_kind,
          NEW.provider, NEW.provider_account_key, NEW.source, NEW.scope_key, NEW.request_key,
          NEW.request_fingerprint, NEW.contract_version, NEW.start_cursor,
          NEW.started_at, NEW.inserted_at
        ) IS DISTINCT FROM ROW(
          OLD.id, OLD.acquisition_key, OLD.user_id, OLD.agent_id,
          OLD.agent_directive_id, OLD.runtime_ingress_receipt_id,
          OLD.connected_account_id, OLD.source_cursor_id, OLD.cursor_kind,
          OLD.provider, OLD.provider_account_key, OLD.source, OLD.scope_key, OLD.request_key,
          OLD.request_fingerprint, OLD.contract_version, OLD.start_cursor,
          OLD.started_at, OLD.inserted_at
        ) THEN
          RAISE EXCEPTION 'chief acquisition identity is immutable' USING ERRCODE = '23514';
        END IF;

        IF OLD.status <> 'fetching' THEN
          RAISE EXCEPTION 'sealed chief acquisition is immutable' USING ERRCODE = '23514';
        END IF;

        IF NEW.page_count < OLD.page_count OR NEW.item_count < OLD.item_count THEN
          RAISE EXCEPTION 'chief acquisition counts cannot rewind' USING ERRCODE = '23514';
        END IF;

        IF OLD.pagination_exhausted AND (
          NOT NEW.pagination_exhausted OR
          NEW.page_count <> OLD.page_count OR
          NEW.item_count <> OLD.item_count
        ) THEN
          RAISE EXCEPTION 'terminal chief acquisition page permanently exhausts the run'
            USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
          SELECT 1
          FROM public.chief_acquisition_pages page
          WHERE page.acquisition_run_id = NEW.id
            AND page.terminal
        ) AND NOT NEW.pagination_exhausted THEN
          RAISE EXCEPTION 'terminal chief acquisition page cannot be reopened'
            USING ERRCODE = '23514';
        END IF;

        IF NEW.status = 'complete' THEN
          SELECT
            count(*),
            count(*) FILTER (WHERE page.terminal),
            coalesce(sum(page.item_count), 0),
            min(page.ordinal),
            max(page.ordinal)
          INTO
            persisted_page_count,
            persisted_terminal_count,
            persisted_item_count,
            minimum_ordinal,
            maximum_ordinal
          FROM public.chief_acquisition_pages page
          WHERE page.acquisition_run_id = NEW.id;

          SELECT count(*) INTO persisted_link_count
          FROM public.chief_acquisition_envelopes link
          WHERE link.acquisition_run_id = NEW.id;

          IF persisted_page_count = 0 OR
             persisted_page_count <> NEW.page_count OR
             persisted_item_count <> NEW.item_count OR
             persisted_link_count <> NEW.item_count OR
             minimum_ordinal <> 0 OR
             maximum_ordinal <> NEW.page_count - 1 OR
             persisted_terminal_count <> 1 THEN
            RAISE EXCEPTION 'complete chief acquisition has incomplete page or item proof'
              USING ERRCODE = '23514';
          END IF;

          IF EXISTS (
            SELECT 1
            FROM public.chief_acquisition_pages page
            WHERE page.acquisition_run_id = NEW.id
              AND page.terminal
              AND page.ordinal <> NEW.page_count - 1
          ) THEN
            RAISE EXCEPTION 'only the last chief acquisition page may be terminal'
              USING ERRCODE = '23514';
          END IF;

          IF EXISTS (
            SELECT 1
            FROM public.chief_acquisition_pages page
            LEFT JOIN public.chief_acquisition_pages previous
              ON previous.acquisition_run_id = page.acquisition_run_id
             AND previous.ordinal = page.ordinal - 1
            WHERE page.acquisition_run_id = NEW.id
              AND (
                (page.ordinal = 0 AND page.request_cursor IS DISTINCT FROM NEW.start_cursor) OR
                (page.ordinal > 0 AND (
                  previous.id IS NULL OR
                  previous.terminal OR
                  page.request_cursor IS DISTINCT FROM previous.next_cursor
                ))
              )
          ) THEN
            RAISE EXCEPTION 'complete chief acquisition has a broken cursor chain'
              USING ERRCODE = '23514';
          END IF;

          IF EXISTS (
            SELECT 1
            FROM public.chief_acquisition_pages page
            LEFT JOIN LATERAL (
              SELECT
                count(*) AS count,
                min(link.item_ordinal) AS minimum_ordinal,
                max(link.item_ordinal) AS maximum_ordinal
              FROM public.chief_acquisition_envelopes link
              WHERE link.acquisition_page_id = page.id
                AND link.acquisition_run_id = NEW.id
            ) links ON TRUE
            WHERE page.acquisition_run_id = NEW.id
              AND (
                links.count <> page.item_count OR
                (page.item_count > 0 AND (
                  links.minimum_ordinal <> 0 OR
                  links.maximum_ordinal <> page.item_count - 1
                ))
              )
          ) THEN
            RAISE EXCEPTION 'complete chief acquisition has incomplete item ordinals'
              USING ERRCODE = '23514';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.guard_chief_acquisition_run_transition() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER chief_acquisition_runs_transition_guard
      BEFORE UPDATE ON chief_acquisition_runs
      FOR EACH ROW EXECUTE FUNCTION public.guard_chief_acquisition_run_transition()
      """,
      "DROP TRIGGER IF EXISTS chief_acquisition_runs_transition_guard ON chief_acquisition_runs"
    )

    execute(
      """
      CREATE FUNCTION public.guard_agent_work_result_transition()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      BEGIN
        IF OLD.status <> 'provisional' OR NEW.status <> 'committed' THEN
          RAISE EXCEPTION 'agent work result permits only provisional to committed'
            USING ERRCODE = '23514';
        END IF;

        IF ROW(
          NEW.id, NEW.result_key, NEW.agent_directive_id, NEW.agent_id,
          NEW.user_id, NEW.agent_run_id, NEW.claim_generation, NEW.claim_token,
          NEW.outcome, NEW.terminal_event, NEW.result, NEW.result_digest,
          NEW.provisional_at, NEW.inserted_at
        ) IS DISTINCT FROM ROW(
          OLD.id, OLD.result_key, OLD.agent_directive_id, OLD.agent_id,
          OLD.user_id, OLD.agent_run_id, OLD.claim_generation, OLD.claim_token,
          OLD.outcome, OLD.terminal_event, OLD.result, OLD.result_digest,
          OLD.provisional_at, OLD.inserted_at
        ) THEN
          RAISE EXCEPTION 'agent work result proof is immutable' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.guard_agent_work_result_transition() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER agent_work_results_transition_guard
      BEFORE UPDATE ON agent_work_results
      FOR EACH ROW EXECUTE FUNCTION public.guard_agent_work_result_transition()
      """,
      "DROP TRIGGER IF EXISTS agent_work_results_transition_guard ON agent_work_results"
    )

    execute(
      """
      CREATE FUNCTION public.guard_chief_semantic_effect_insert()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      BEGIN
        PERFORM 1
        FROM public.chief_acquisition_runs acquisition
        WHERE acquisition.id = NEW.acquisition_run_id
        FOR UPDATE;

        IF FOUND AND EXISTS (
          SELECT 1
          FROM public.agent_work_result_acquisitions link
          WHERE link.acquisition_run_id = NEW.acquisition_run_id
        ) THEN
          RAISE EXCEPTION 'chief acquisition semantic set is closed by work-result linkage'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.guard_chief_semantic_effect_insert() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER chief_semantic_effects_insert_guard
      BEFORE INSERT ON chief_semantic_effects
      FOR EACH ROW EXECUTE FUNCTION public.guard_chief_semantic_effect_insert()
      """,
      "DROP TRIGGER IF EXISTS chief_semantic_effects_insert_guard ON chief_semantic_effects"
    )

    execute(
      """
      CREATE FUNCTION public.guard_chief_semantic_effect_source_insert()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      BEGIN
        PERFORM 1
        FROM public.chief_acquisition_runs acquisition
        WHERE acquisition.id = NEW.acquisition_run_id
        FOR UPDATE;

        IF FOUND AND EXISTS (
          SELECT 1
          FROM public.agent_work_result_acquisitions link
          WHERE link.acquisition_run_id = NEW.acquisition_run_id
        ) THEN
          RAISE EXCEPTION 'chief semantic source proof set is closed by work-result linkage'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.guard_chief_semantic_effect_source_insert() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER chief_semantic_effect_sources_insert_guard
      BEFORE INSERT ON chief_semantic_effect_sources
      FOR EACH ROW EXECUTE FUNCTION public.guard_chief_semantic_effect_source_insert()
      """,
      "DROP TRIGGER IF EXISTS chief_semantic_effect_sources_insert_guard ON chief_semantic_effect_sources"
    )

    execute(
      """
      CREATE FUNCTION public.guard_agent_work_result_acquisition_insert()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      DECLARE
        result_status text;
      BEGIN
        PERFORM 1
        FROM public.chief_acquisition_runs acquisition
        WHERE acquisition.id = NEW.acquisition_run_id
        FOR UPDATE;

        SELECT status INTO result_status
        FROM public.agent_work_results result
        WHERE result.id = NEW.agent_work_result_id
        FOR UPDATE;

        IF result_status IS NOT NULL AND result_status <> 'provisional' THEN
          RAISE EXCEPTION 'committed agent work result cannot acquire new acquisition proof'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.guard_agent_work_result_acquisition_insert() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER agent_work_result_acquisitions_insert_guard
      BEFORE INSERT ON agent_work_result_acquisitions
      FOR EACH ROW EXECUTE FUNCTION public.guard_agent_work_result_acquisition_insert()
      """,
      "DROP TRIGGER IF EXISTS agent_work_result_acquisitions_insert_guard ON agent_work_result_acquisitions"
    )

    execute(
      """
      CREATE FUNCTION public.require_complete_semantic_effect_sources()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      DECLARE
        persisted public.chief_semantic_effects%ROWTYPE;
      BEGIN
        SELECT * INTO persisted
        FROM public.chief_semantic_effects
        WHERE id = NEW.id;

        IF NOT FOUND THEN
          RETURN NULL;
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM public.chief_acquisition_runs acquisition
          WHERE acquisition.id = persisted.acquisition_run_id
            AND acquisition.status = 'complete'
            AND acquisition.pagination_exhausted = TRUE
            AND acquisition.sealed_at IS NOT NULL
            AND acquisition.manifest_digest IS NOT NULL
        ) THEN
          RAISE EXCEPTION 'semantic effect requires a sealed complete acquisition'
            USING ERRCODE = '23514';
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM public.chief_semantic_effect_sources source
          WHERE source.semantic_effect_id = persisted.id
        ) THEN
          RAISE EXCEPTION 'semantic effect requires immutable source evidence'
            USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
          SELECT 1
          FROM public.agent_work_result_acquisitions link
          WHERE link.acquisition_run_id = persisted.acquisition_run_id
        ) THEN
          RAISE EXCEPTION 'semantic effect cannot commit after acquisition semantics close'
            USING ERRCODE = '23514';
        END IF;

        RETURN NULL;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.require_complete_semantic_effect_sources() CASCADE"
    )

    execute(
      """
      CREATE CONSTRAINT TRIGGER chief_semantic_effects_complete_source_guard
      AFTER INSERT ON chief_semantic_effects
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION public.require_complete_semantic_effect_sources()
      """,
      "DROP TRIGGER IF EXISTS chief_semantic_effects_complete_source_guard ON chief_semantic_effects"
    )

    execute(
      """
      CREATE FUNCTION public.guard_chief_projection_receipt()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      DECLARE
        effect_kind text;
        result_status text;
      BEGIN
        PERFORM 1
        FROM public.chief_acquisition_runs acquisition
        JOIN public.chief_semantic_effects effect
          ON effect.acquisition_run_id = acquisition.id
        WHERE effect.id = NEW.semantic_effect_id
        FOR UPDATE OF acquisition;

        SELECT status INTO result_status
        FROM public.agent_work_results result
        WHERE result.id = NEW.agent_work_result_id
        FOR UPDATE;

        IF result_status IS DISTINCT FROM 'provisional' THEN
          RAISE EXCEPTION 'committed agent work result cannot accept projection receipts'
            USING ERRCODE = '23514';
        END IF;

        SELECT effect.kind INTO effect_kind
        FROM public.chief_semantic_effects effect
        JOIN public.agent_work_result_acquisitions acquisition
          ON acquisition.agent_work_result_id = NEW.agent_work_result_id
         AND acquisition.acquisition_run_id = effect.acquisition_run_id
        WHERE effect.id = NEW.semantic_effect_id
          AND effect.agent_id = NEW.agent_id
          AND effect.user_id = NEW.user_id;

        IF effect_kind IS NULL OR effect_kind <> NEW.projection_kind THEN
          RAISE EXCEPTION 'projection is not backed by a linked semantic acquisition'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.guard_chief_projection_receipt() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER chief_projection_receipts_lineage_guard
      BEFORE INSERT ON chief_projection_receipts
      FOR EACH ROW EXECUTE FUNCTION public.guard_chief_projection_receipt()
      """,
      "DROP TRIGGER IF EXISTS chief_projection_receipts_lineage_guard ON chief_projection_receipts"
    )

    execute(
      """
      CREATE FUNCTION public.guard_source_cursor_advancement()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      DECLARE
        result_status text;
      BEGIN
        PERFORM 1
        FROM public.chief_acquisition_runs acquisition
        WHERE acquisition.id = NEW.acquisition_run_id
        FOR UPDATE;

        SELECT status INTO result_status
        FROM public.agent_work_results result
        WHERE result.id = NEW.agent_work_result_id
        FOR UPDATE;

        IF result_status IS DISTINCT FROM 'provisional' THEN
          RAISE EXCEPTION 'committed agent work result cannot accept cursor receipts'
            USING ERRCODE = '23514';
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM public.agent_work_result_acquisitions result_acquisition
          JOIN public.chief_acquisition_runs acquisition
            ON acquisition.id = result_acquisition.acquisition_run_id
          JOIN public.source_cursors cursor
            ON cursor.id = NEW.source_cursor_id
          WHERE result_acquisition.agent_work_result_id = NEW.agent_work_result_id
            AND result_acquisition.acquisition_run_id = NEW.acquisition_run_id
            AND acquisition.status = 'complete'
            AND acquisition.sealed_at IS NOT NULL
            AND acquisition.pagination_exhausted = TRUE
            AND result_acquisition.agent_directive_id = acquisition.agent_directive_id
            AND acquisition.source_cursor_id = NEW.source_cursor_id
            AND acquisition.provider_account_key = NEW.provider_account_key
            AND acquisition.start_cursor IS NOT DISTINCT FROM NEW.expected_value
            AND acquisition.proposed_cursor IS NOT DISTINCT FROM NEW.advanced_value
            AND cursor.value IS NOT DISTINCT FROM NEW.advanced_value
            AND cursor.user_id = NEW.user_id
            AND cursor.connected_account_id = NEW.connected_account_id
            AND cursor.provider = NEW.provider
            AND cursor.kind = NEW.cursor_kind
        ) THEN
          RAISE EXCEPTION 'cursor advancement lacks exact complete acquisition and CAS proof'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.guard_source_cursor_advancement() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER source_cursor_advancements_lineage_guard
      BEFORE INSERT ON source_cursor_advancements
      FOR EACH ROW EXECUTE FUNCTION public.guard_source_cursor_advancement()
      """,
      "DROP TRIGGER IF EXISTS source_cursor_advancements_lineage_guard ON source_cursor_advancements"
    )

    execute(
      """
      CREATE FUNCTION public.require_committed_agent_work_result()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $$
      DECLARE
        persisted public.agent_work_results%ROWTYPE;
        acquisition_count integer;
        directive_status text;
        run_status text;
      BEGIN
        SELECT * INTO persisted
        FROM public.agent_work_results
        WHERE id = NEW.id;

        IF NOT FOUND THEN
          RETURN NULL;
        END IF;

        IF persisted.status <> 'committed' OR persisted.committed_at IS NULL THEN
          RAISE EXCEPTION 'provisional agent work result cannot survive transaction commit'
            USING ERRCODE = '23514';
        END IF;

        SELECT count(*) INTO acquisition_count
        FROM public.agent_work_result_acquisitions link
        JOIN public.chief_acquisition_runs acquisition
          ON acquisition.id = link.acquisition_run_id
        WHERE link.agent_work_result_id = persisted.id
          AND link.agent_directive_id = persisted.agent_directive_id
          AND acquisition.agent_directive_id = persisted.agent_directive_id
          AND acquisition.status = 'complete'
          AND acquisition.pagination_exhausted = TRUE
          AND acquisition.sealed_at IS NOT NULL
          AND acquisition.manifest_digest IS NOT NULL;

        IF acquisition_count = 0 OR acquisition_count <> (
          SELECT count(*)
          FROM public.agent_work_result_acquisitions
          WHERE agent_work_result_id = persisted.id
        ) THEN
          RAISE EXCEPTION 'agent work result requires only sealed complete acquisitions'
            USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
          SELECT 1
          FROM public.chief_semantic_effects effect
          JOIN public.agent_work_result_acquisitions link
            ON link.acquisition_run_id = effect.acquisition_run_id
           AND link.agent_work_result_id = persisted.id
          WHERE NOT EXISTS (
            SELECT 1
            FROM public.chief_projection_receipts receipt
            WHERE receipt.agent_work_result_id = persisted.id
              AND receipt.semantic_effect_id = effect.id
          )
        ) THEN
          RAISE EXCEPTION 'agent work result has an unprojected semantic effect'
            USING ERRCODE = '23514';
        END IF;

        IF EXISTS (
          SELECT 1
          FROM public.chief_acquisition_runs acquisition
          JOIN public.agent_work_result_acquisitions link
            ON link.acquisition_run_id = acquisition.id
           AND link.agent_work_result_id = persisted.id
          WHERE acquisition.source_cursor_id IS NOT NULL
            AND NOT EXISTS (
              SELECT 1
              FROM public.source_cursor_advancements advancement
              WHERE advancement.agent_work_result_id = persisted.id
                AND advancement.acquisition_run_id = acquisition.id
                AND advancement.source_cursor_id = acquisition.source_cursor_id
            )
        ) THEN
          RAISE EXCEPTION 'agent work result is missing a required cursor advancement'
            USING ERRCODE = '23514';
        END IF;

        SELECT status INTO directive_status
        FROM public.agent_directives
        WHERE id = persisted.agent_directive_id
          AND agent_id = persisted.agent_id
          AND user_id = persisted.user_id
          AND terminal_by_generation = persisted.claim_generation
          AND terminal_claim_token = persisted.claim_token;

        IF NOT (
          (persisted.outcome = 'completed' AND directive_status = 'completed') OR
          (persisted.outcome IN ('failed','dead_letter') AND directive_status = 'dead_letter') OR
          (persisted.outcome = 'cancelled' AND directive_status = 'cancelled')
        ) THEN
          RAISE EXCEPTION 'agent work result outcome does not match exact directive terminal proof'
            USING ERRCODE = '23514';
        END IF;

        SELECT status INTO run_status
        FROM public.agent_runs
        WHERE id = persisted.agent_run_id
          AND agent_id = persisted.agent_id
          AND user_id = persisted.user_id;

        IF NOT (
          (persisted.outcome = 'completed' AND run_status = 'completed') OR
          (persisted.outcome IN ('failed','dead_letter') AND run_status = 'failed') OR
          (persisted.outcome = 'cancelled' AND run_status = 'cancelled')
        ) THEN
          RAISE EXCEPTION 'agent work result outcome does not match exact AgentRun proof'
            USING ERRCODE = '23514';
        END IF;

        RETURN NULL;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS public.require_committed_agent_work_result() CASCADE"
    )

    execute(
      """
      CREATE CONSTRAINT TRIGGER agent_work_results_commit_guard
      AFTER INSERT OR UPDATE ON agent_work_results
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION public.require_committed_agent_work_result()
      """,
      "DROP TRIGGER IF EXISTS agent_work_results_commit_guard ON agent_work_results"
    )
  end
end
