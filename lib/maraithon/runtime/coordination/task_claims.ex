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
  alias Maraithon.Runtime.Coordination.{Authority, NodeIncarnation, TaskAssignment}

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

  def activate(%TaskAssignment{work_kind: "effect"}),
    do: {:error, :effect_requires_canonical_effect_transaction}

  def activate(%TaskAssignment{} = assignment) do
    transition(
      assignment,
      """
      state = 'running', ready_at = timezone('UTC', clock_timestamp()),
      updated_at = timezone('UTC', clock_timestamp())
      """,
      "state = 'reserved'"
    )
  end

  def mark_provider_entered(%TaskAssignment{work_kind: "effect"}),
    do: {:error, :effect_requires_canonical_effect_transaction}

  def mark_provider_entered(%TaskAssignment{} = assignment) do
    transition(
      assignment,
      """
      provider_boundary = 'entered', updated_at = timezone('UTC', clock_timestamp())
      """,
      "state = 'running' AND provider_boundary = 'not_entered'"
    )
  end

  def renew(%TaskAssignment{work_kind: "effect"}, _ttl_ms),
    do: {:error, :effect_requires_canonical_effect_transaction}

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

  def request_termination(%TaskAssignment{work_kind: "effect"}),
    do: {:error, :effect_requires_canonical_effect_transaction}

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

  def abort_reserved(%TaskAssignment{work_kind: "effect"}),
    do: {:error, :effect_requires_canonical_effect_transaction}

  def abort_reserved(%TaskAssignment{} = assignment) do
    transition(
      assignment,
      """
      state = 'settled', settled_at = timezone('UTC', clock_timestamp()),
      outcome = 'cancelled_before_provider', updated_at = timezone('UTC', clock_timestamp())
      """,
      "state = 'reserved' AND provider_boundary = 'not_entered'"
    )
  end

  @doc false
  def activate_effect_in_transaction!(
        %TaskAssignment{work_kind: "effect"} = assignment,
        agent_id,
        owner_generation
      ) do
    locked = lock_effect_assignment_in_transaction!(assignment)

    unless locked.state == "reserved" and locked.provider_boundary == "not_entered",
      do: Repo.rollback(:coordination_task_authority_lost)

    _lease_cap =
      fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :ready)

    set_action!(locked.id)

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_task_assignments
        SET state = 'running', ready_at = timezone('UTC', clock_timestamp()),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND activation_epoch = $2::uuid
          AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
          AND supervisor_id = $5::uuid AND local_task_id = $6::uuid
          AND state = 'reserved' AND provider_boundary = 'not_entered'
          AND lease_expires_at > timezone('UTC', clock_timestamp())
        RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                  partition_id, partition_epoch, node_incarnation_id,
                  supervisor_id, local_task_id, state, provider_boundary,
                  lease_expires_at, ready_at, termination_requested_at,
                  termination_proven_at, settled_at, outcome, inserted_at, updated_at
        """,
        identity_params(locked)
      )

    load!(result, :coordination_task_authority_lost)
  end

  @doc false
  def enter_effect_provider_in_transaction!(
        %TaskAssignment{work_kind: "effect"} = assignment,
        agent_id,
        owner_generation
      ) do
    locked = lock_effect_assignment_in_transaction!(assignment)

    unless locked.state == "running" and locked.provider_boundary == "not_entered",
      do: Repo.rollback(:coordination_task_authority_lost)

    _lease_cap =
      fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :ready)

    set_action!(locked.id)

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_task_assignments
        SET provider_boundary = 'entered', updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND activation_epoch = $2::uuid
          AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
          AND supervisor_id = $5::uuid AND local_task_id = $6::uuid
          AND state = 'running' AND provider_boundary = 'not_entered'
          AND lease_expires_at > timezone('UTC', clock_timestamp())
        RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                  partition_id, partition_epoch, node_incarnation_id,
                  supervisor_id, local_task_id, state, provider_boundary,
                  lease_expires_at, ready_at, termination_requested_at,
                  termination_proven_at, settled_at, outcome, inserted_at, updated_at
        """,
        identity_params(locked)
      )

    load!(result, :coordination_task_authority_lost)
  end

  @doc false
  def renew_effect_in_transaction!(
        %TaskAssignment{work_kind: "effect"} = assignment,
        agent_id,
        owner_generation,
        ttl_ms
      )
      when is_integer(ttl_ms) and ttl_ms in 1_000..300_000 do
    locked = lock_effect_assignment_in_transaction!(assignment)

    unless locked.state == "running",
      do: Repo.rollback(:coordination_task_authority_lost)

    lease_cap =
      fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :ready)

    set_action!(locked.id)

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_task_assignments
        SET lease_expires_at = LEAST(
              timezone('UTC', clock_timestamp()) + ($7::bigint * interval '1 millisecond'),
              $8::timestamp
            ),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND activation_epoch = $2::uuid
          AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
          AND supervisor_id = $5::uuid AND local_task_id = $6::uuid
          AND state = 'running'
          AND lease_expires_at > timezone('UTC', clock_timestamp())
        RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                  partition_id, partition_epoch, node_incarnation_id,
                  supervisor_id, local_task_id, state, provider_boundary,
                  lease_expires_at, ready_at, termination_requested_at,
                  termination_proven_at, settled_at, outcome, inserted_at, updated_at
        """,
        identity_params(locked) ++ [ttl_ms, lease_cap]
      )

    renewed = load!(result, :coordination_task_authority_lost)

    unless DateTime.compare(renewed.lease_expires_at, locked.lease_expires_at) == :gt,
      do: Repo.rollback(:coordination_task_authority_lost)

    renewed
  end

  @doc false
  def settle_effect_before_provider_in_transaction!(
        %TaskAssignment{work_kind: "effect"} = assignment,
        agent_id,
        owner_generation
      ) do
    locked = lock_effect_assignment_in_transaction!(assignment)

    case locked do
      %TaskAssignment{state: "running", provider_boundary: "not_entered"} ->
        _lease_cap =
          fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :owner)

        settle_with_boundary!(locked, "not_entered", "cancelled_before_provider")

      %TaskAssignment{
        state: "settled",
        provider_boundary: "not_entered",
        outcome: "cancelled_before_provider"
      } ->
        locked

      _noncanonical ->
        Repo.rollback(:coordination_task_settlement_lost)
    end
  end

  @doc false
  def settle_effect_in_transaction(
        %TaskAssignment{work_kind: "effect"} = assignment,
        agent_id,
        owner_generation,
        outcome
      )
      when is_binary(outcome) and byte_size(outcome) in 1..255 do
    locked = lock_effect_assignment_in_transaction!(assignment)

    case locked do
      %TaskAssignment{state: "running", provider_boundary: "entered"} ->
        _lease_cap =
          fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :owner)

        record_outcome_and_settle!(locked, outcome)

      %TaskAssignment{state: "settled", provider_boundary: boundary, outcome: ^outcome}
      when boundary == "outcome_known" or
             (boundary == "not_entered" and outcome == "cancelled_before_provider") ->
        locked

      %TaskAssignment{state: "outcome_ambiguous"} ->
        # A later canonical Effect observation must never rewrite durable
        # ambiguity or manufacture provider evidence.
        locked

      _noncanonical ->
        Repo.rollback(:coordination_task_settlement_lost)
    end
  end

  @doc false
  def request_effect_termination_in_transaction!(
        %TaskAssignment{work_kind: "effect"} = assignment
      ) do
    locked = lock_effect_assignment_in_transaction!(assignment)

    case locked do
      %TaskAssignment{state: state} when state in ["reserved", "running"] ->
        request_termination_locked!(locked)

      %TaskAssignment{state: "termination_requested"} ->
        locked

      %TaskAssignment{state: state} when state in ["settled", "outcome_ambiguous"] ->
        locked

      _mismatched ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  @doc false
  def abort_effect_reserved_in_transaction!(
        %TaskAssignment{work_kind: "effect"} = assignment,
        agent_id,
        owner_generation
      ) do
    locked = lock_effect_assignment_in_transaction!(assignment)

    case locked do
      %TaskAssignment{state: "reserved", provider_boundary: "not_entered"} ->
        _lease_cap =
          fence_effect_authority_in_transaction!(locked, agent_id, owner_generation, :owner)

        requested = request_termination_locked!(locked)
        evidence_id = "effect-task-supervisor:never_activated:#{locked.local_task_id}"

        proven =
          case record_local_termination(requested, "supervisor_down", evidence_id) do
            {:ok, %TaskAssignment{state: "termination_proven"} = value} -> value
            _lost -> Repo.rollback(:coordination_task_termination_proof_lost)
          end

        reconcile_effect_proven_in_transaction(proven, agent_id, owner_generation)

      %TaskAssignment{
        state: "settled",
        provider_boundary: "not_entered",
        outcome: "cancelled_before_provider"
      } ->
        locked

      _activated_or_mismatched ->
        Repo.rollback(:coordination_task_authority_lost)
    end
  end

  @doc false
  def lock_effect_assignment_in_transaction!(%TaskAssignment{work_kind: "effect"} = assignment) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "effect task lock requires transaction")

    case Repo.one(
           from a in TaskAssignment,
             where: a.id == ^assignment.id,
             where: a.activation_epoch == ^assignment.activation_epoch,
             where: a.work_kind == "effect",
             where: a.work_id == ^assignment.work_id,
             where: a.claim_token == ^assignment.claim_token,
             where: a.partition_id == ^assignment.partition_id,
             where: a.partition_epoch == ^assignment.partition_epoch,
             where: a.node_incarnation_id == ^assignment.node_incarnation_id,
             where: a.supervisor_id == ^assignment.supervisor_id,
             where: a.local_task_id == ^assignment.local_task_id,
             lock: "FOR UPDATE"
         ) do
      %TaskAssignment{} = locked -> locked
      nil -> Repo.rollback(:coordination_task_authority_lost)
    end
  end

  def fence_running!(%TaskAssignment{} = assignment) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "task fence requires transaction")

    case SQL.query!(
           Repo,
           """
           SELECT id, provider_boundary FROM public.runtime_task_assignments
           WHERE id = $1::uuid AND activation_epoch = $2::uuid
             AND claim_token = $3::uuid AND node_incarnation_id = $4::uuid
             AND supervisor_id = $5::uuid AND local_task_id = $6::uuid
             AND work_kind = $7 AND work_id = $8::uuid
             AND partition_id = $9 AND partition_epoch = $10
             AND state = 'running' AND lease_expires_at > timezone('UTC', clock_timestamp())
             AND public.runtime_task_authority_valid(id, activation_epoch, partition_id,
                   partition_epoch, node_incarnation_id, claim_token)
           FOR SHARE
           """,
           identity_params(assignment) ++
             [
               assignment.work_kind,
               Ecto.UUID.dump!(assignment.work_id),
               assignment.partition_id,
               assignment.partition_epoch
             ]
         ).rows do
      [[_id, provider_boundary]] ->
        set_action!(assignment.id)
        provider_boundary

      [] ->
        Repo.rollback(:task_authority_lost)
    end
  end

  def settle_in_transaction(%TaskAssignment{work_kind: "effect"}, _outcome),
    do: Repo.rollback(:effect_requires_canonical_effect_transaction)

  def settle_in_transaction(%TaskAssignment{} = assignment, outcome)
      when is_binary(outcome) and byte_size(outcome) in 1..255 do
    case fence_running!(assignment) do
      "entered" -> record_outcome_and_settle!(assignment, outcome)
      _not_entered_or_unknown -> Repo.rollback(:task_provider_not_entered)
    end
  end

  def cancel_before_provider_in_transaction(%TaskAssignment{work_kind: "effect"}),
    do: Repo.rollback(:effect_requires_canonical_effect_transaction)

  def cancel_before_provider_in_transaction(%TaskAssignment{} = assignment) do
    case fence_running!(assignment) do
      "not_entered" ->
        settle_with_boundary!(assignment, "not_entered", "cancelled_before_provider")

      _entered_or_unknown ->
        Repo.rollback(:task_provider_already_entered)
    end
  end

  defp record_outcome_and_settle!(assignment, outcome) do
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
    Repo.transaction(fn ->
      assignments =
        Repo.all(
          from a in TaskAssignment,
            where: a.state == "termination_proven",
            where: a.work_kind != "effect",
            order_by: [asc: a.termination_proven_at, asc: a.id],
            limit: ^limit,
            lock: "FOR UPDATE SKIP LOCKED"
        )

      Enum.map(assignments, &reconcile_one!/1)
    end)
  end

  @doc false
  def reconcile_effect_proven_in_transaction(
        %TaskAssignment{} = assignment,
        agent_id,
        owner_generation
      ) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "effect task reconciliation requires transaction")

    locked =
      Repo.one(
        from a in TaskAssignment,
          where: a.id == ^assignment.id,
          where: a.activation_epoch == ^assignment.activation_epoch,
          where: a.work_kind == "effect",
          where: a.work_id == ^assignment.work_id,
          where: a.claim_token == ^assignment.claim_token,
          where: a.partition_id == ^assignment.partition_id,
          where: a.partition_epoch == ^assignment.partition_epoch,
          where: a.node_incarnation_id == ^assignment.node_incarnation_id,
          where: a.supervisor_id == ^assignment.supervisor_id,
          where: a.local_task_id == ^assignment.local_task_id,
          where: a.state == "termination_proven",
          lock: "FOR UPDATE"
      )

    case locked do
      %TaskAssignment{} = proven ->
        _lease_cap =
          fence_effect_authority_in_transaction!(proven, agent_id, owner_generation, :owner)

        outcome =
          if proven.provider_boundary in ["entered", "outcome_unknown"],
            do: "provider_outcome_ambiguous",
            else: "cancelled_before_provider"

        finish_proven!(proven, outcome)

      nil ->
        Repo.rollback(:task_termination_proof_lost)
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

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.background_jobs SET #{updates}
        WHERE id = $1::uuid AND status = 'running' AND claim_token = $2::uuid
          AND coordination_task_assignment_id = $3::uuid
        """,
        [
          Ecto.UUID.dump!(assignment.work_id),
          Ecto.UUID.dump!(assignment.claim_token),
          Ecto.UUID.dump!(assignment.id)
        ]
      )

    outcome =
      if provider_entered?, do: "provider_outcome_ambiguous", else: "cancelled_before_provider"

    finish_proven!(assignment, outcome)
    {assignment.id, result.num_rows, outcome}
  end

  defp finish_proven!(assignment, outcome) do
    set_action!(assignment.id)
    state = if outcome == "provider_outcome_ambiguous", do: "outcome_ambiguous", else: "settled"

    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_task_assignments
        SET state = $2, settled_at = timezone('UTC', clock_timestamp()), outcome = $3,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND state = 'termination_proven'
        RETURNING id, activation_epoch, work_kind, work_id, claim_token,
                  partition_id, partition_epoch, node_incarnation_id,
                  supervisor_id, local_task_id, state, provider_boundary,
                  lease_expires_at, ready_at, termination_requested_at,
                  termination_proven_at, settled_at, outcome, inserted_at, updated_at
        """,
        [Ecto.UUID.dump!(assignment.id), state, outcome]
      )

    load!(result, :task_termination_proof_lost)
  end

  defp record_proof(assignment, proof_kind, evidence_id, proved_by, confirmation)
       when is_binary(evidence_id) and byte_size(evidence_id) in 1..256 and
              is_binary(proved_by) and byte_size(proved_by) in 1..320 do
    Repo.transaction(fn ->
      locked = lock_exact_assignment_for_proof!(assignment)

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

  defp lock_exact_assignment_for_proof!(%TaskAssignment{} = assignment) do
    case Repo.one(
           from a in TaskAssignment,
             where: a.id == ^assignment.id,
             where: a.activation_epoch == ^assignment.activation_epoch,
             where: a.work_kind == ^assignment.work_kind,
             where: a.work_id == ^assignment.work_id,
             where: a.claim_token == ^assignment.claim_token,
             where: a.partition_id == ^assignment.partition_id,
             where: a.partition_epoch == ^assignment.partition_epoch,
             where: a.node_incarnation_id == ^assignment.node_incarnation_id,
             where: a.supervisor_id == ^assignment.supervisor_id,
             where: a.local_task_id == ^assignment.local_task_id,
             lock: "FOR UPDATE"
         ) do
      %TaskAssignment{} = locked -> locked
      nil -> Repo.rollback(:coordination_task_authority_lost)
    end
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

  defp transition(assignment, set_sql, where_sql) do
    Repo.transaction(fn ->
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

  defp fence_effect_authority_in_transaction!(
         %TaskAssignment{} = assignment,
         agent_id,
         owner_generation,
         mode
       )
       when mode in [:ready, :owner] do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "effect authority fence requires transaction")

    states = if mode == :ready, do: ["ready"], else: ["ready", "draining"]

    lease_shape =
      if mode == :ready,
        do: "lease.ready_at IS NOT NULL AND lease.draining_at IS NULL",
        else: "(lease.ready_at IS NOT NULL OR lease.draining_at IS NOT NULL)"

    ready_shape =
      if mode == :ready,
        do: "node.ready_at IS NOT NULL AND partition.ready_at IS NOT NULL",
        else: "TRUE"

    params = [
      Ecto.UUID.dump!(assignment.activation_epoch),
      assignment.partition_id,
      assignment.partition_epoch,
      Ecto.UUID.dump!(assignment.node_incarnation_id),
      Ecto.UUID.dump!(agent_id),
      Ecto.UUID.dump!(owner_generation)
    ]

    case SQL.query!(
           Repo,
           """
           SELECT LEAST(node.lease_expires_at, partition.lease_expires_at, lease.lease_until)
           FROM public.runtime_node_incarnations AS node
           JOIN public.runtime_partitions AS partition
             ON partition.partition_id = $2
            AND partition.activation_epoch = $1::uuid
            AND partition.ownership_epoch = $3
            AND partition.owner_node_incarnation_id = $4::uuid
            AND partition.state = ANY($7::text[])
            AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
           JOIN public.agent_runtime_leases AS lease
             ON lease.agent_id = $5::uuid AND lease.owner_token = $6::uuid
            AND lease.coordination_activation_epoch = $1::uuid
            AND lease.coordination_partition_id = $2
            AND lease.coordination_partition_epoch = $3
            AND lease.coordination_node_incarnation_id = $4::uuid
            AND lease.lease_until > timezone('UTC', clock_timestamp())
            AND #{lease_shape}
           WHERE node.id = $4::uuid AND node.activation_epoch = $1::uuid
             AND node.state = ANY($7::text[])
             AND node.lease_expires_at > timezone('UTC', clock_timestamp())
             AND #{ready_shape}
           FOR SHARE OF node, partition, lease
           """,
           params ++ [states]
         ).rows do
      [[lease_cap]] when not is_nil(lease_cap) -> lease_cap
      [] -> Repo.rollback(:coordination_task_authority_lost)
    end
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
