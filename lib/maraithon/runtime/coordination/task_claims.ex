defmodule Maraithon.Runtime.Coordination.TaskClaims do
  @moduledoc """
  Durable task-incarnation ledger.

  Assignment IDs, claim tokens and physical Task.Supervisor identities are
  immutable. Lease expiry requests termination; it never proves it. Only an
  exact monitored supervisor proof or a separately authorized external proof
  permits recovery, and provider outcome remains explicit.
  """

  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Maraithon.Repo

  alias Maraithon.Runtime.Coordination.{
    Authority,
    NodeIncarnation,
    Protocol,
    TaskAssignment,
    TaskSupervisor
  }

  def reserve(%NodeIncarnation{} = session, partition, identity, opts \\ [])
      when is_map(partition) and is_map(identity) and is_list(opts) do
    assignment_id = Map.get(identity, :assignment_id, Ecto.UUID.generate())
    ttl_ms = Keyword.get(opts, :ttl_ms, 30_000)
    work_kind = to_string(identity.work_kind)

    with {:ok, assignment_id} <- cast_uuid(assignment_id),
         {:ok, work_id} <- cast_uuid(identity.work_id),
         {:ok, claim_token} <- cast_uuid(identity.claim_token),
         {:ok, supervisor_id} <- cast_uuid(identity.supervisor_id),
         {:ok, local_task_id} <- cast_uuid(identity.local_task_id),
         true <- work_kind in ~w(background_job effect),
         true <- is_integer(ttl_ms) and ttl_ms in 1_000..300_000 do
      Repo.transaction(fn ->
        Authority.fence_partition!(
          session,
          partition.partition_id,
          partition.ownership_epoch,
          :ready
        )

        set_action!(assignment_id)

        result =
          SQL.query!(
            Repo,
            """
            INSERT INTO public.runtime_task_assignments
              (id, activation_epoch, work_kind, work_id, claim_token,
               partition_id, partition_epoch, node_incarnation_id,
               supervisor_id, local_task_id, state, provider_boundary,
               lease_expires_at, inserted_at, updated_at)
            VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5::uuid,
                    $6, $7, $8::uuid, $9::uuid, $10::uuid,
                    'reserved', 'not_entered',
                    LEAST(
                      timezone('UTC', clock_timestamp()) + ($11::bigint * interval '1 millisecond'),
                      (SELECT lease_expires_at FROM public.runtime_partitions
                       WHERE partition_id = $6)
                    ), timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
            RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                      partition_id, partition_epoch, node_incarnation_id,
                      supervisor_id, local_task_id, state, provider_boundary,
                      lease_expires_at, ready_at, termination_requested_at,
                      termination_proven_at, settled_at, outcome, inserted_at, updated_at
            """,
            [
              Ecto.UUID.dump!(assignment_id),
              Ecto.UUID.dump!(session.activation_epoch),
              work_kind,
              Ecto.UUID.dump!(work_id),
              Ecto.UUID.dump!(claim_token),
              partition.partition_id,
              partition.ownership_epoch,
              Ecto.UUID.dump!(session.id),
              Ecto.UUID.dump!(supervisor_id),
              Ecto.UUID.dump!(local_task_id),
              ttl_ms
            ]
          )

        load(result)
      end)
    else
      false -> {:error, :invalid_task_assignment}
      {:error, _} = error -> error
    end
  end

  def activate(%TaskAssignment{} = assignment) do
    with :ok <- TaskSupervisor.authorize_activation(task_identity(assignment)) do
      transition(
        assignment,
        """
        state = 'running', ready_at = timezone('UTC', clock_timestamp()),
        updated_at = timezone('UTC', clock_timestamp())
        """,
        "state = 'reserved'"
      )
    end
  end

  def mark_provider_entered(%TaskAssignment{} = assignment) do
    with :ok <- TaskSupervisor.authorize_activation(task_identity(assignment)) do
      transition(
        assignment,
        """
        provider_boundary = 'entered', updated_at = timezone('UTC', clock_timestamp())
        """,
        "state = 'running' AND provider_boundary = 'not_entered'"
      )
    end
  end

  def renew(%TaskAssignment{} = assignment, ttl_ms)
      when is_integer(ttl_ms) and ttl_ms in 1_000..300_000 do
    transition(
      assignment,
      """
      lease_expires_at = LEAST(
        timezone('UTC', clock_timestamp()) + (#{ttl_ms}::bigint * interval '1 millisecond'),
        (SELECT lease_expires_at FROM public.runtime_partitions
         WHERE partition_id = runtime_task_assignments.partition_id)
      ), updated_at = timezone('UTC', clock_timestamp())
      """,
      "state = 'running' AND lease_expires_at > timezone('UTC', clock_timestamp())"
    )
  end

  def request_termination(%TaskAssignment{} = assignment) do
    transition(
      assignment,
      """
      state = 'termination_requested',
      provider_boundary = CASE WHEN provider_boundary = 'entered'
                               THEN 'outcome_unknown' ELSE provider_boundary END,
      termination_requested_at = timezone('UTC', clock_timestamp()),
      updated_at = timezone('UTC', clock_timestamp())
      """,
      "state IN ('reserved', 'running')"
    )
  end

  def abort_reserved(%TaskAssignment{} = assignment) do
    Repo.transaction(fn ->
      current = lock_assignment!(assignment)

      settled =
        case current do
          %TaskAssignment{state: state, provider_boundary: "not_entered"}
          when state in ["reserved", "termination_requested"] ->
            case transition(
                   current,
                   """
                   state = 'settled', settled_at = timezone('UTC', clock_timestamp()),
                   outcome = 'cancelled_before_provider', updated_at = timezone('UTC', clock_timestamp())
                   """,
                   "state IN ('reserved', 'termination_requested') AND provider_boundary = 'not_entered'"
                 ) do
              {:ok, value} -> value
              {:error, reason} -> Repo.rollback(reason)
            end

          %TaskAssignment{
            state: "settled",
            provider_boundary: "not_entered",
            outcome: "cancelled_before_provider"
          } = value ->
            value

          _ ->
            Repo.rollback(:task_authority_lost)
        end

      clear_never_activated_work!(settled)
      settled
    end)
  end

  defp clear_never_activated_work!(%TaskAssignment{work_kind: "background_job"} = assignment) do
    set_action!(assignment.id)

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.background_jobs
        SET claimed_by = NULL, claimed_at = NULL, claim_token = NULL,
            coordination_activation_epoch = NULL, coordination_partition_epoch = NULL,
            coordination_node_incarnation_id = NULL,
            coordination_task_assignment_id = NULL,
            coordination_task_supervisor_id = NULL,
            coordination_local_task_id = NULL,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND status = 'pending' AND claim_token = $2::uuid
          AND coordination_task_assignment_id = $3::uuid
        """,
        [
          Ecto.UUID.dump!(assignment.work_id),
          Ecto.UUID.dump!(assignment.claim_token),
          Ecto.UUID.dump!(assignment.id)
        ]
      )

    if result.num_rows == 1 or never_activated_work_cleared?(assignment),
      do: :ok,
      else: Repo.rollback(:coordinated_work_not_converged)
  end

  defp clear_never_activated_work!(%TaskAssignment{}), do: :ok

  def fence_running!(%TaskAssignment{} = assignment) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "task fence requires transaction")

    assignment = lock_assignment!(assignment)

    case SQL.query!(
           Repo,
           """
           SELECT id FROM public.runtime_task_assignments
           WHERE id = $1::uuid AND activation_epoch = $2::uuid
             AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
             AND supervisor_id = $5::uuid AND local_task_id = $6::uuid
             AND state = 'running' AND lease_expires_at > timezone('UTC', clock_timestamp())
             AND public.runtime_task_authority_valid(id, activation_epoch, partition_id,
                   partition_epoch, node_incarnation_id, claim_token)
           """,
           identity_params(assignment)
         ).rows do
      [[_id]] -> set_action!(assignment.id)
      [] -> Repo.rollback(:task_authority_lost)
    end
  end

  def settle_in_transaction(%TaskAssignment{} = assignment, outcome)
      when is_binary(outcome) and byte_size(outcome) in 1..255 do
    fence_running!(assignment)
    evidence_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO public.runtime_task_outcome_evidence
        (id, assignment_id, activation_epoch, claim_token, node_incarnation_id,
         supervisor_id, local_task_id, outcome, recorded_at, inserted_at, updated_at)
      VALUES ($7::uuid, $1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid,
              $8, timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()),
              timezone('UTC', clock_timestamp()))
      """,
      identity_params(assignment) ++ [Ecto.UUID.dump!(evidence_id), outcome]
    )

    settle_with_boundary!(assignment, "outcome_known", outcome)
  end

  def cancel_before_provider_in_transaction(%TaskAssignment{} = assignment) do
    fence_running!(assignment)
    settle_with_boundary!(assignment, "not_entered", "cancelled_before_provider")
  end

  defp settle_with_boundary!(assignment, boundary, outcome) do
    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_task_assignments
        SET state = 'settled', settled_at = timezone('UTC', clock_timestamp()), outcome = $8,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND activation_epoch = $2::uuid AND claim_token = $3::uuid
          AND node_incarnation_id = $4::uuid AND supervisor_id = $5::uuid
          AND local_task_id = $6::uuid AND state = 'running' AND provider_boundary = $7
        RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                  partition_id, partition_epoch, node_incarnation_id,
                  supervisor_id, local_task_id, state, provider_boundary,
                  lease_expires_at, ready_at, termination_requested_at,
                  termination_proven_at, settled_at, outcome, inserted_at, updated_at
        """,
        identity_params(assignment) ++ [boundary, outcome]
      )

    load!(result, :task_authority_lost)
  end

  def record_local_termination(%TaskAssignment{} = assignment, proof_kind, evidence_id)
      when proof_kind == "supervisor_down" do
    record_proof(
      assignment,
      proof_kind,
      evidence_id,
      Atom.to_string(node()),
      "LOCAL_TASK_SUPERVISOR_PROOF"
    )
  end

  def record_external_termination(%TaskAssignment{} = assignment, evidence_id, proved_by) do
    record_proof(
      assignment,
      "external_destroyed",
      evidence_id,
      proved_by,
      "PHYSICAL_TASK_TERMINATED"
    )
  end

  def reconcile_proven(limit \\ 25) when is_integer(limit) and limit in 1..100 do
    # Discovery is deliberately unlocked and bounded. Each candidate takes the
    # canonical authority locks before attempting its assignment row, so a busy
    # assignment is skipped without reversing protocol -> node -> partition ->
    # assignment -> work ordering or blocking another reconciler.
    candidates =
      Repo.all(
        from a in TaskAssignment,
          where: a.state == "termination_proven",
          order_by: [asc: a.termination_proven_at, asc: a.id],
          limit: ^limit
      )

    candidates
    |> Enum.reduce_while({:ok, []}, fn assignment, {:ok, results} ->
      case Repo.transaction(fn ->
             case try_lock_assignment(assignment) do
               %TaskAssignment{state: "termination_proven"} = locked -> reconcile_one!(locked)
               %TaskAssignment{} -> :already_converged
               nil -> :busy
             end
           end) do
        {:ok, state} when state in [:already_converged, :busy] ->
          {:cont, {:ok, results}}

        {:ok, result} ->
          {:cont, {:ok, [result | results]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  def get(id) when is_binary(id), do: Repo.get(TaskAssignment, id)

  defp reconcile_one!(%TaskAssignment{work_kind: "background_job"} = assignment) do
    set_action!(assignment.id)
    provider_entered? = assignment.provider_boundary in ["entered", "outcome_unknown"]
    set_local!("maraithon.runtime_task_reconciliation", assignment.id)

    updates =
      if provider_entered? do
        """
        status = 'failed', failed_at = timezone('UTC', clock_timestamp()),
        last_error = 'provider_outcome_ambiguous', claimed_by = NULL, claimed_at = NULL,
        completed_at = NULL, updated_at = timezone('UTC', clock_timestamp())
        """
      else
        """
        status = 'pending', scheduled_at = timezone('UTC', clock_timestamp()),
        claimed_by = NULL, claimed_at = NULL, claim_token = NULL,
        coordination_activation_epoch = NULL, coordination_partition_epoch = NULL,
        coordination_node_incarnation_id = NULL, coordination_task_assignment_id = NULL,
        coordination_task_supervisor_id = NULL, coordination_local_task_id = NULL,
        updated_at = timezone('UTC', clock_timestamp())
        """
      end

    outcome =
      if provider_entered?, do: "provider_outcome_ambiguous", else: "cancelled_before_provider"

    finish_proven!(assignment, outcome)

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.background_jobs SET #{updates}
        WHERE id = $1::uuid AND claim_token = $2::uuid
          AND coordination_task_assignment_id = $3::uuid
          AND ((status = 'running' AND $4::boolean) OR
               (status IN ('pending', 'running') AND NOT $4::boolean))
        """,
        [
          Ecto.UUID.dump!(assignment.work_id),
          Ecto.UUID.dump!(assignment.claim_token),
          Ecto.UUID.dump!(assignment.id),
          provider_entered?
        ]
      )

    if result.num_rows != 1, do: Repo.rollback(:coordinated_work_not_converged)
    {assignment.id, result.num_rows, outcome}
  end

  defp reconcile_one!(%TaskAssignment{work_kind: "effect"} = assignment) do
    # Exact Effect cancellation remains owned by its coupled EffectTaskSupervisor
    # protocol. This ledger records only the physical proof and ambiguity; it
    # never invents provider failure or releases the Effect for replay.
    outcome =
      if assignment.provider_boundary in ["entered", "outcome_unknown"],
        do: "provider_outcome_ambiguous",
        else: "cancelled_before_provider"

    finish_proven!(assignment, outcome)
    {assignment.id, 0, outcome}
  end

  defp finish_proven!(assignment, outcome) do
    set_action!(assignment.id)
    state = if outcome == "provider_outcome_ambiguous", do: "outcome_ambiguous", else: "settled"

    SQL.query!(
      Repo,
      """
      UPDATE public.runtime_task_assignments
      SET state = $2, settled_at = timezone('UTC', clock_timestamp()), outcome = $3,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE id = $1::uuid AND state = 'termination_proven'
      """,
      [Ecto.UUID.dump!(assignment.id), state, outcome]
    )
  end

  defp record_proof(assignment, proof_kind, evidence_id, proved_by, confirmation)
       when is_binary(evidence_id) and byte_size(evidence_id) in 1..256 and
              is_binary(proved_by) and byte_size(proved_by) in 1..320 do
    Repo.transaction(fn ->
      locked = lock_assignment!(assignment)

      locked =
        if locked.state in ["reserved", "running"],
          do: request_termination_locked!(locked),
          else: locked

      if locked.state != "termination_requested",
        do: Repo.rollback(:task_not_awaiting_termination_proof)

      set_action!(locked.id)
      set_local!("maraithon.runtime_task_termination_proof", confirmation)
      digest = :crypto.hash(:sha256, evidence_id)
      proof_id = Ecto.UUID.generate()

      SQL.query!(
        Repo,
        """
        INSERT INTO public.runtime_task_termination_proofs
          (id, assignment_id, activation_epoch, claim_token, node_incarnation_id,
           supervisor_id, local_task_id, proof_kind, evidence_id, evidence_digest,
           proved_by, proved_at, inserted_at, updated_at)
        VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, $7::uuid,
                $8, $9, $10, $11, timezone('UTC', clock_timestamp()),
                timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
        ON CONFLICT (assignment_id) DO NOTHING
        """,
        [
          Ecto.UUID.dump!(proof_id),
          Ecto.UUID.dump!(locked.id),
          Ecto.UUID.dump!(locked.activation_epoch),
          Ecto.UUID.dump!(locked.claim_token),
          Ecto.UUID.dump!(locked.node_incarnation_id),
          Ecto.UUID.dump!(locked.supervisor_id),
          Ecto.UUID.dump!(locked.local_task_id),
          proof_kind,
          evidence_id,
          digest,
          proved_by
        ]
      )

      result =
        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_task_assignments
          SET state = 'termination_proven', termination_proven_at = timezone('UTC', clock_timestamp()),
              updated_at = timezone('UTC', clock_timestamp())
          WHERE id = $1::uuid AND state = 'termination_requested'
          RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                    partition_id, partition_epoch, node_incarnation_id,
                    supervisor_id, local_task_id, state, provider_boundary,
                    lease_expires_at, ready_at, termination_requested_at,
                    termination_proven_at, settled_at, outcome, inserted_at, updated_at
          """,
          [Ecto.UUID.dump!(locked.id)]
        )

      load!(result, :task_termination_proof_lost)
    end)
  end

  defp request_termination_locked!(assignment) do
    set_action!(assignment.id)

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_task_assignments
        SET state = 'termination_requested',
            provider_boundary = CASE WHEN provider_boundary = 'entered'
                                     THEN 'outcome_unknown' ELSE provider_boundary END,
            termination_requested_at = timezone('UTC', clock_timestamp()),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND state IN ('reserved', 'running')
        RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                  partition_id, partition_epoch, node_incarnation_id,
                  supervisor_id, local_task_id, state, provider_boundary,
                  lease_expires_at, ready_at, termination_requested_at,
                  termination_proven_at, settled_at, outcome, inserted_at, updated_at
        """,
        [Ecto.UUID.dump!(assignment.id)]
      )

    load!(result, :task_authority_lost)
  end

  # Canonical mutation order is coordination protocol -> node -> partition ->
  # assignment. Work-specific callers may lock canonical Effect authority first.
  defp lock_authority_rows!(assignment) do
    _ = Protocol.locked_active!()

    node_rows =
      SQL.query!(
        Repo,
        """
        SELECT id FROM public.runtime_node_incarnations
        WHERE id = $1::uuid AND activation_epoch = $2::uuid
        FOR SHARE
        """,
        [
          Ecto.UUID.dump!(assignment.node_incarnation_id),
          Ecto.UUID.dump!(assignment.activation_epoch)
        ]
      ).rows

    if node_rows == [], do: Repo.rollback(:task_authority_lost)

    partition_rows =
      SQL.query!(
        Repo,
        """
        SELECT partition_id FROM public.runtime_partitions
        WHERE partition_id = $1 AND activation_epoch = $2::uuid
          AND ownership_epoch = $3
          AND owner_node_incarnation_id = $4::uuid
        FOR SHARE
        """,
        [
          assignment.partition_id,
          Ecto.UUID.dump!(assignment.activation_epoch),
          assignment.partition_epoch,
          Ecto.UUID.dump!(assignment.node_incarnation_id)
        ]
      ).rows

    if partition_rows == [], do: Repo.rollback(:task_authority_lost)
    :ok
  end

  defp try_lock_assignment(assignment) do
    lock_authority_rows!(assignment)

    Repo.one(
      from(current in TaskAssignment,
        where: current.id == ^assignment.id,
        where: current.activation_epoch == ^assignment.activation_epoch,
        where: current.claim_token == ^assignment.claim_token,
        where: current.node_incarnation_id == ^assignment.node_incarnation_id,
        where: current.supervisor_id == ^assignment.supervisor_id,
        where: current.local_task_id == ^assignment.local_task_id,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  defp lock_assignment!(assignment) do
    lock_authority_rows!(assignment)

    case Repo.one(
           from(current in TaskAssignment,
             where: current.id == ^assignment.id,
             where: current.activation_epoch == ^assignment.activation_epoch,
             where: current.claim_token == ^assignment.claim_token,
             where: current.node_incarnation_id == ^assignment.node_incarnation_id,
             where: current.supervisor_id == ^assignment.supervisor_id,
             where: current.local_task_id == ^assignment.local_task_id,
             lock: "FOR UPDATE"
           )
         ) do
      %TaskAssignment{} = current -> current
      nil -> Repo.rollback(:task_authority_lost)
    end
  end

  defp never_activated_work_cleared?(assignment) do
    case SQL.query!(
           Repo,
           """
           SELECT 1 FROM public.background_jobs
           WHERE id = $1::uuid AND status = 'pending' AND claim_token IS NULL
             AND coordination_task_assignment_id IS NULL
             AND coordination_activation_epoch IS NULL
             AND coordination_partition_epoch IS NULL
             AND coordination_node_incarnation_id IS NULL
             AND coordination_task_supervisor_id IS NULL
             AND coordination_local_task_id IS NULL
           """,
           [Ecto.UUID.dump!(assignment.work_id)]
         ).rows do
      [[1]] -> true
      _ -> false
    end
  end

  defp transition(assignment, set_sql, where_sql) do
    Repo.transaction(fn ->
      assignment = lock_assignment!(assignment)
      set_action!(assignment.id)

      result =
        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_task_assignments SET #{set_sql}
          WHERE id = $1::uuid AND activation_epoch = $2::uuid
            AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
            AND supervisor_id = $5::uuid AND local_task_id = $6::uuid AND #{where_sql}
          RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                    partition_id, partition_epoch, node_incarnation_id,
                    supervisor_id, local_task_id, state, provider_boundary,
                    lease_expires_at, ready_at, termination_requested_at,
                    termination_proven_at, settled_at, outcome, inserted_at, updated_at
          """,
          identity_params(assignment)
        )

      load!(result, :task_authority_lost)
    end)
  end

  defp task_identity(assignment) do
    %{
      work_kind: assignment.work_kind,
      work_id: assignment.work_id,
      claim_token: assignment.claim_token,
      assignment_id: assignment.id,
      supervisor_id: assignment.supervisor_id,
      local_task_id: assignment.local_task_id
    }
  end

  defp identity_params(a),
    do: [
      Ecto.UUID.dump!(a.id),
      Ecto.UUID.dump!(a.activation_epoch),
      Ecto.UUID.dump!(a.claim_token),
      Ecto.UUID.dump!(a.node_incarnation_id),
      Ecto.UUID.dump!(a.supervisor_id),
      Ecto.UUID.dump!(a.local_task_id)
    ]

  defp load(%{columns: columns, rows: [row]}), do: Repo.load(TaskAssignment, {columns, row})
  defp load!(%{rows: []}, reason), do: Repo.rollback(reason)
  defp load!(result, _), do: load(result)

  defp set_action!(id), do: set_local!("maraithon.runtime_task_action", id)

  defp set_local!(key, value),
    do: SQL.query!(Repo, "SELECT set_config($1, $2, true)", [key, to_string(value)])

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_task_identity}
    end
  end
end
