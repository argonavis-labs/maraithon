defmodule Maraithon.Delegations.Retention do
  @moduledoc "Bounded removal of completed conversation copies; live and uncertain work is retained."
  alias Maraithon.{Repo, Effects.ProtocolCutover}

  @families ~w(delegation_events delegation_turns delegation_grants delegations)
  @doc false
  def unpinned_run_sql("run") do
    """
    AND NOT EXISTS (
      SELECT 1 FROM delegation_turns t
      WHERE t.run_id = run.id AND t.user_id = run.user_id
    )
    """
  end

  @doc false
  def unpinned_action_sql("action") do
    """
    AND NOT EXISTS (
      SELECT 1 FROM delegations d
      WHERE d.id = action.delegation_id AND d.user_id = action.user_id
    )
    """
  end

  @eligible """
  d.state IN ('completed','stopped','expired') AND d.updated_at <= $1
  AND NOT EXISTS (
    SELECT 1 FROM delegation_turns t WHERE t.delegation_id = d.id
      AND t.status IN ('deciding','validated','dispatched')
  )
  AND NOT EXISTS (
    SELECT 1 FROM delegation_turns t
    JOIN telegram_prepared_actions a ON a.id = t.prepared_action_id
    WHERE t.delegation_id = d.id AND a.status NOT IN ('executed','rejected','expired','failed')
  )
  AND NOT EXISTS (
    SELECT 1 FROM telegram_prepared_actions a WHERE a.id = d.last_action_id
    AND a.status NOT IN ('executed','rejected','expired','failed')
  )
  """

  def retention_backlog(%DateTime{} = cutoff, _cursor, opts) do
    now = Keyword.fetch!(opts, :now)

    case Repo.query(
           "SELECT count(*), min(d.updated_at) FROM delegations d WHERE #{@eligible}",
           [DateTime.to_naive(cutoff)],
           log: false
         ) do
      {:ok, %{rows: [[count, oldest]]}} ->
        age =
          if oldest,
            do: max(DateTime.diff(now, DateTime.from_naive!(oldest, "Etc/UTC")), 0),
            else: 0

        {:ok, %{count: count, oldest_age_seconds: age}}

      {:error, _} ->
        {:error, :delegation_retention_unavailable}
    end
  end

  def purge_retention_batch(%DateTime{} = cutoff, cursor, opts) do
    limit = Keyword.fetch!(opts, :limit)
    per_tenant = Keyword.fetch!(opts, :per_tenant)

    if limit in 1..500 and per_tenant in 1..50 do
      Repo.transaction(fn ->
        ProtocolCutover.require_exact_write!()

        Enum.reduce(@families, %{purged: 0, tenant_cursor: cursor}, fn table, result ->
          remaining = limit - result.purged

          if remaining == 0 do
            result
          else
            query = """
            WITH candidates AS (
              SELECT s.id, s.user_id, row_number() OVER (PARTITION BY s.user_id ORDER BY s.id) AS tenant_rank
              FROM #{table} s #{join(table)} WHERE #{@eligible} AND #{ready(table)}
            ), selected AS (
              SELECT s.id, s.user_id FROM #{table} s JOIN candidates c ON c.id = s.id
              WHERE c.tenant_rank <= $3
              ORDER BY CASE WHEN s.user_id > COALESCE($4, '') THEN 0 ELSE 1 END, s.user_id, s.id
              LIMIT $2 FOR UPDATE OF s SKIP LOCKED
            ), deleted AS (
              DELETE FROM #{table} s USING selected x WHERE s.id = x.id RETURNING s.user_id
            ) SELECT count(*), max(user_id) FROM deleted
            """

            %{rows: [[count, last_user]]} =
              Repo.query!(
                query,
                [DateTime.to_naive(cutoff), remaining, per_tenant, result.tenant_cursor],
                log: false
              )

            %{purged: result.purged + count, tenant_cursor: last_user || result.tenant_cursor}
          end
        end)
      end)
    else
      {:error, :invalid_retention_adapter_options}
    end
  end

  defp join("delegations"), do: "JOIN delegations d ON d.id = s.id"
  defp join(_), do: "JOIN delegations d ON d.id = s.delegation_id"
  defp ready("delegation_events"), do: "true"

  defp ready("delegation_turns"),
    do: "NOT EXISTS (SELECT 1 FROM delegation_events e WHERE e.consumed_by_turn_id = s.id)"

  defp ready("delegation_grants"), do: "s.id IS DISTINCT FROM d.current_grant_id"

  defp ready("delegations") do
    """
    NOT EXISTS (SELECT 1 FROM delegation_events e WHERE e.delegation_id = d.id)
    AND NOT EXISTS (SELECT 1 FROM delegation_turns t WHERE t.delegation_id = d.id)
    AND NOT EXISTS (SELECT 1 FROM delegation_grants g WHERE g.delegation_id = d.id AND g.id IS DISTINCT FROM d.current_grant_id)
    """
  end
end
