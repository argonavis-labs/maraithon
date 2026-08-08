defmodule Maraithon.Repo.Migrations.IncludeHeldInProactiveLiveDedupe do
  use Ecto.Migration

  def up do
    alter table(:telegram_push_receipts) do
      add :metadata, :map, null: false, default: %{}
    end

    execute("""
    CREATE INDEX telegram_push_receipts_digest_membership_index
    ON telegram_push_receipts USING GIN (metadata jsonb_path_ops)
    WHERE origin_type = 'assistant_digest'
      AND decision IN ('reserved', 'sending', 'delivery_unknown', 'sent_now')
    """)

    execute("LOCK TABLE proactive_candidates IN SHARE ROW EXCLUSIVE MODE")
    execute("LOCK TABLE briefs, insight_deliveries IN SHARE ROW EXCLUSIVE MODE")
    execute("DROP INDEX IF EXISTS proactive_candidates_live_dedupe_index")

    # Release 1418 could requeue an ambiguous push and then interpret its
    # durable delivery_unknown receipt as a confirmed duplicate. Preserve
    # at-most-once delivery by quarantining those candidates and correcting
    # source rows that were advanced without an APNs acceptance proof.
    execute("""
    CREATE TEMP TABLE proactive_unknown_reconciliations
    ON COMMIT DROP AS
    SELECT potential.id,
           potential.user_id,
           potential.dedupe_key,
           potential.source,
           potential.source_id,
           MIN(potential.ambiguous_at) AS ambiguous_at
    FROM (
      SELECT candidate.id,
             candidate.user_id,
             candidate.dedupe_key,
             candidate.source,
             candidate.source_id,
             receipt.inserted_at AS ambiguous_at
      FROM proactive_candidates AS candidate
      INNER JOIN telegram_push_receipts AS receipt
        ON receipt.user_id = candidate.user_id
       AND receipt.dedupe_key = candidate.dedupe_key
      WHERE candidate.status IN ('pending', 'planned', 'delivered', 'held', 'expired')
        AND receipt.decision = 'delivery_unknown'

      UNION ALL

      SELECT candidate.id,
             candidate.user_id,
             candidate.dedupe_key,
             candidate.source,
             candidate.source_id,
             receipt.inserted_at AS ambiguous_at
      FROM proactive_candidates AS candidate
      INNER JOIN telegram_push_receipts AS receipt
        ON receipt.user_id = candidate.user_id
       AND receipt.origin_type = 'assistant_digest'
       AND left(receipt.dedupe_key, 16) = 'delivery_digest:'
      WHERE candidate.status IN ('pending', 'planned', 'delivered', 'held', 'expired')
        AND candidate.inserted_at <= receipt.inserted_at
        AND receipt.decision = 'delivery_unknown'
        AND NOT EXISTS (
          SELECT 1
          FROM telegram_push_receipts AS child_receipt
          WHERE child_receipt.user_id = candidate.user_id
            AND child_receipt.dedupe_key = candidate.dedupe_key
            AND child_receipt.decision IN ('sent_now', 'merged', 'queued_digest')
        )
    ) AS potential
    GROUP BY potential.id,
             potential.user_id,
             potential.dedupe_key,
             potential.source,
             potential.source_id
    """)

    # Legacy digest receipts lack exact bundle membership. Conservatively
    # quarantine every child that could have been in the attempt, including an
    # expired predecessor whose stable dedupe key may already be re-enqueued,
    # and create a child-key blocking proof so expiry/re-enqueue under a new
    # candidate UUID cannot later bypass that ambiguity.
    execute("""
    INSERT INTO telegram_push_receipts (
      id,
      user_id,
      dedupe_key,
      origin_type,
      origin_id,
      decision,
      metadata,
      inserted_at
    )
    SELECT gen_random_uuid(),
           repair.user_id,
           repair.dedupe_key,
           CASE repair.source
             WHEN 'insight' THEN 'insight'
             WHEN 'brief' THEN 'brief'
             WHEN 'nudge' THEN 'nudge'
             ELSE 'assistant_digest'
           END,
           repair.source_id,
           'delivery_unknown',
           '{}'::jsonb,
           repair.ambiguous_at
    FROM proactive_unknown_reconciliations AS repair
    ON CONFLICT (user_id, dedupe_key)
    DO UPDATE SET
      origin_type = EXCLUDED.origin_type,
      origin_id = EXCLUDED.origin_id,
      decision = 'delivery_unknown',
      metadata = EXCLUDED.metadata
    WHERE telegram_push_receipts.decision NOT IN ('sent_now', 'merged', 'queued_digest')
    """)

    execute("""
    UPDATE proactive_candidates AS candidate
    SET status = 'held',
        plan_reason = 'delivery_unknown',
        planned_at = NULL,
        delivered_at = NULL,
        updated_at = NOW()
    FROM proactive_unknown_reconciliations AS repair
    WHERE candidate.id = repair.id
    """)

    execute("""
    UPDATE briefs AS brief
    SET status = 'failed',
        error_message = 'delivery_unknown',
        provider_message_id = NULL,
        sent_at = NULL,
        updated_at = NOW()
    FROM proactive_unknown_reconciliations AS repair
    WHERE repair.source = 'brief'
      AND repair.source_id = brief.id::text
      AND brief.status IN ('pending', 'sent', 'failed')
    """)

    execute("""
    UPDATE insight_deliveries AS delivery
    SET status = 'failed',
        error_message = 'delivery_unknown',
        provider_message_id = NULL,
        sent_at = NULL,
        updated_at = NOW()
    FROM proactive_unknown_reconciliations AS repair
    WHERE repair.source = 'insight'
      AND repair.source_id = delivery.id::text
      AND delivery.status IN ('pending', 'sent', 'failed')
    """)

    # Held rows are active suppression/quarantine records. Collapse historical
    # duplicates deterministically before extending the unique invariant.
    execute("""
    WITH ranked AS (
      SELECT id,
             row_number() OVER (
               PARTITION BY user_id, dedupe_key
               ORDER BY
                 CASE WHEN plan_reason = 'delivery_unknown' THEN 0 ELSE 1 END,
                 CASE status
                   WHEN 'planned' THEN 0
                   WHEN 'pending' THEN 1
                   WHEN 'held' THEN 2
                   ELSE 3
                 END,
                 updated_at DESC,
                 id
             ) AS position
      FROM proactive_candidates
      WHERE status IN ('pending', 'planned', 'held')
    )
    UPDATE proactive_candidates AS candidate
    SET status = 'expired',
        plan_reason = 'dedupe_collapsed',
        planned_at = NULL,
        delivered_at = NULL,
        updated_at = NOW()
    FROM ranked
    WHERE candidate.id = ranked.id
      AND ranked.position > 1
    """)

    create unique_index(:proactive_candidates, [:user_id, :dedupe_key],
             name: :proactive_candidates_live_dedupe_index,
             where: "status IN ('pending', 'planned', 'held')"
           )
  end

  def down do
    raise "irreversible: delivery ambiguity quarantine and dedupe repair cannot be safely undone"
  end
end
