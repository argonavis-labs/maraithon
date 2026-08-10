defmodule Maraithon.Runtime.Coordination.Authority do
  @moduledoc """
  PostgreSQL-clock node, leader and partition authority.

  All mutating functions carry the activation epoch plus an exact node/leader
  incarnation token into the same transaction as the action. Expired epochs
  are never renewed. Readiness is a separate, final write.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Maraithon.Repo
  alias Maraithon.Runtime.Coordination.{NodeIncarnation, Partition, Protocol}

  @max_ttl_ms 300_000

  def register_node(opts \\ []) when is_list(opts) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    node_name = Keyword.get(opts, :node_name, Atom.to_string(node()))
    revision = Keyword.get(opts, :revision, System.get_env("GIT_SHA", "development"))
    ttl_ms = Keyword.get(opts, :ttl_ms, 30_000)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, id} <- cast_uuid(id),
         :ok <- valid_text(node_name),
         :ok <- valid_text(revision),
         :ok <- valid_ttl(ttl_ms),
         true <- is_map(metadata) do
      Repo.transaction(fn ->
        activation_epoch = Protocol.locked_active!()
        set_local!("maraithon.runtime_node_action", id)

        result =
          SQL.query!(
            Repo,
            """
            INSERT INTO public.runtime_node_incarnations
              (id, activation_epoch, node_name, revision, state, lease_expires_at, metadata,
               inserted_at, updated_at)
            VALUES ($1::uuid, $2::uuid, $3, $4, 'joining',
                    timezone('UTC', clock_timestamp()) + ($5::bigint * interval '1 millisecond'),
                    $6::jsonb, timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
            RETURNING id, activation_epoch, node_name, revision, state, lease_expires_at,
                      ready_at, draining_at, revoked_at, metadata, inserted_at, updated_at
            """,
            [
              Ecto.UUID.dump!(id),
              Ecto.UUID.dump!(activation_epoch),
              node_name,
              revision,
              ttl_ms,
              Jason.encode!(metadata)
            ]
          )

        load(NodeIncarnation, result)
      end)
    else
      false -> {:error, :invalid_node_metadata}
      {:error, _} = error -> error
    end
  end

  def mark_node_ready(%NodeIncarnation{} = session) do
    Repo.transaction(fn ->
      _ = Protocol.locked_active!()
      set_local!("maraithon.runtime_node_action", session.id)

      update_node!(
        session,
        """
        state = 'ready', ready_at = timezone('UTC', clock_timestamp()),
        draining_at = NULL, updated_at = timezone('UTC', clock_timestamp())
        """,
        "state = 'joining' AND lease_expires_at > timezone('UTC', clock_timestamp())"
      )
    end)
  end

  def renew_node(%NodeIncarnation{} = session, ttl_ms) do
    with :ok <- valid_ttl(ttl_ms) do
      Repo.transaction(fn ->
        _ = Protocol.locked_active!()
        set_local!("maraithon.runtime_node_action", session.id)

        update_node!(
          session,
          """
          lease_expires_at = timezone('UTC', clock_timestamp()) +
            (#{ttl_ms}::bigint * interval '1 millisecond'),
          updated_at = timezone('UTC', clock_timestamp())
          """,
          "state IN ('joining', 'ready', 'draining') AND lease_expires_at > timezone('UTC', clock_timestamp())"
        )
      end)
    end
  end

  def begin_node_drain(%NodeIncarnation{} = session) do
    Repo.transaction(fn ->
      _ = Protocol.locked_active!()
      locked = lock_node!(session)
      set_local!("maraithon.runtime_node_action", session.id)

      revoke_owned_leader!(locked)

      now_sql = "timezone('UTC', clock_timestamp())"

      update_node!(
        locked,
        "state = 'draining', ready_at = NULL, draining_at = COALESCE(draining_at, #{now_sql}), updated_at = #{now_sql}",
        "state IN ('joining', 'ready', 'draining')"
      )

      rows =
        SQL.query!(
          Repo,
          """
          SELECT partition_id, ownership_epoch FROM public.runtime_partitions
          WHERE owner_node_incarnation_id = $1::uuid AND state IN ('preparing', 'ready')
          ORDER BY partition_id FOR UPDATE
          """,
          [Ecto.UUID.dump!(session.id)]
        ).rows

      Enum.each(rows, fn [partition_id, _ownership_epoch] ->
        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_partitions
          SET state = 'draining', ready_at = NULL,
              draining_at = COALESCE(draining_at, timezone('UTC', clock_timestamp())),
              updated_at = timezone('UTC', clock_timestamp())
          WHERE partition_id = $1 AND owner_node_incarnation_id = $2::uuid
            AND state IN ('preparing', 'ready')
          """,
          [partition_id, Ecto.UUID.dump!(session.id)]
        )

        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_partition_transitions
          SET state = 'draining', updated_at = timezone('UTC', clock_timestamp())
          WHERE id = (SELECT transition_id FROM public.runtime_partitions WHERE partition_id = $1)
            AND state IN ('preparing', 'ready')
          """,
          [partition_id]
        )
      end)

      # Canonical Effects are locked before their assignments. Partition
      # state is already draining, so no new provider entry can race this fence.
      Enum.each(rows, fn [partition_id, ownership_epoch] ->
        _ =
          Maraithon.Effects.Cancellation.request_coordination_drain_in_transaction!(
            session.id,
            partition_id,
            ownership_epoch,
            "coordination_node_draining"
          )
      end)

      # Ready authority is revoked in PostgreSQL before any local process is
      # asked to stop. Existing generations may only close already-admitted work.
      SQL.query!(
        Repo,
        """
        UPDATE public.agent_runtime_leases
        SET ready_at = NULL, draining_at = COALESCE(draining_at, timezone('UTC', clock_timestamp())),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE coordination_node_incarnation_id = $1::uuid
          AND lease_until > timezone('UTC', clock_timestamp())
        """,
        [Ecto.UUID.dump!(session.id)]
      )

      request_task_termination_for_node!(session.id)
      :draining
    end)
  end

  def revoke_node(%NodeIncarnation{} = session) do
    Repo.transaction(fn ->
      _ = Protocol.locked_active!()
      set_local!("maraithon.runtime_node_action", session.id)

      update_node!(
        session,
        "state = 'revoked', ready_at = NULL, revoked_at = timezone('UTC', clock_timestamp()), updated_at = timezone('UTC', clock_timestamp())",
        "state = 'draining'"
      )
    end)
  end

  def acquire_leader(%NodeIncarnation{} = session, ttl_ms \\ 15_000) do
    with :ok <- valid_ttl(ttl_ms) do
      Repo.transaction(fn ->
        activation_epoch = Protocol.locked_active!()
        _ = lock_node!(session)
        token = Ecto.UUID.generate()
        set_local!("maraithon.runtime_leader_action", token)

        leader =
          SQL.query!(
            Repo,
            "SELECT state, leader_epoch, lease_expires_at FROM public.runtime_leader_authorities WHERE role = 'partition_planner' FOR UPDATE",
            []
          ).rows

        case leader do
          [[state, _epoch, expires_at]]
          when state in ["preparing", "ready"] and not is_nil(expires_at) ->
            if db_future?(expires_at),
              do: Repo.rollback(:leader_held),
              else: take_leader!(session, activation_epoch, token, ttl_ms)

          [[_state, _epoch, _expires_at]] ->
            take_leader!(session, activation_epoch, token, ttl_ms)
        end
      end)
    end
  end

  def mark_leader_ready(leader) when is_map(leader) do
    Repo.transaction(fn ->
      _ = Protocol.locked_active!()
      set_local!("maraithon.runtime_leader_action", leader.action_token)

      result =
        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_leader_authorities
          SET state = 'ready', ready_at = timezone('UTC', clock_timestamp()),
              draining_at = NULL, updated_at = timezone('UTC', clock_timestamp())
          WHERE role = 'partition_planner' AND state = 'preparing'
            AND activation_epoch = $1::uuid AND leader_epoch = $2
            AND node_incarnation_id = $3::uuid AND action_token = $4::uuid
            AND lease_expires_at > timezone('UTC', clock_timestamp())
          RETURNING activation_epoch, leader_epoch, node_incarnation_id, action_token,
                    state, lease_expires_at, ready_at
          """,
          leader_params(leader)
        )

      load_leader!(result)
    end)
  end

  def renew_leader(leader, ttl_ms) when is_map(leader) do
    with :ok <- valid_ttl(ttl_ms) do
      Repo.transaction(fn ->
        _ = Protocol.locked_active!()
        set_local!("maraithon.runtime_leader_action", leader.action_token)

        result =
          SQL.query!(
            Repo,
            """
            UPDATE public.runtime_leader_authorities
            SET lease_expires_at = timezone('UTC', clock_timestamp()) +
                  ($5::bigint * interval '1 millisecond'),
                updated_at = timezone('UTC', clock_timestamp())
            WHERE role = 'partition_planner' AND state = 'ready'
              AND activation_epoch = $1::uuid AND leader_epoch = $2
              AND node_incarnation_id = $3::uuid AND action_token = $4::uuid
              AND lease_expires_at > timezone('UTC', clock_timestamp())
            RETURNING activation_epoch, leader_epoch, node_incarnation_id, action_token,
                      state, lease_expires_at, ready_at
            """,
            leader_params(leader) ++ [ttl_ms]
          )

        load_leader!(result)
      end)
    end
  end

  def assign_partition(leader, %NodeIncarnation{} = target, partition_id, opts \\ [])
      when is_map(leader) and is_integer(partition_id) and is_list(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, 30_000)
    kind = Keyword.get(opts, :kind, "assign")

    with :ok <- valid_ttl(ttl_ms), true <- kind in ~w(assign rebalance steal lease_expired) do
      Repo.transaction(fn ->
        activation_epoch = fence_leader!(leader)
        _ = lock_node!(target)
        transition_id = Ecto.UUID.generate()
        set_local!("maraithon.runtime_leader_action", leader.action_token)

        result =
          SQL.query!(
            Repo,
            """
            UPDATE public.runtime_partitions
            SET activation_epoch = $2::uuid, ownership_epoch = ownership_epoch + 1,
                owner_node_incarnation_id = $3::uuid, transition_id = $4::uuid,
                state = 'preparing', lease_expires_at = timezone('UTC', clock_timestamp()) +
                  ($5::bigint * interval '1 millisecond'),
                ready_at = NULL, draining_at = NULL,
                last_moved_at = timezone('UTC', clock_timestamp()),
                updated_at = timezone('UTC', clock_timestamp())
            WHERE partition_id = $1 AND state = 'unassigned'
            RETURNING partition_id, activation_epoch, ownership_epoch,
                      owner_node_incarnation_id, transition_id, state, lease_expires_at,
                      ready_at, draining_at, last_moved_at, fair_sequence, inserted_at, updated_at
            """,
            [
              partition_id,
              Ecto.UUID.dump!(activation_epoch),
              Ecto.UUID.dump!(target.id),
              Ecto.UUID.dump!(transition_id),
              ttl_ms
            ]
          )

        partition = load!(Partition, result, :partition_not_assignable)

        SQL.query!(
          Repo,
          """
          INSERT INTO public.runtime_partition_transitions
            (id, activation_epoch, partition_id, partition_epoch,
             from_node_incarnation_id, to_node_incarnation_id, kind, state,
             leader_node_incarnation_id, leader_epoch, leader_action_token,
             requested_at, inserted_at, updated_at)
          VALUES ($1::uuid, $2::uuid, $3, $4, NULL, $5::uuid, $6, 'preparing',
                  $7::uuid, $8, $9::uuid, timezone('UTC', clock_timestamp()),
                  timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
          """,
          [
            Ecto.UUID.dump!(transition_id),
            Ecto.UUID.dump!(activation_epoch),
            partition_id,
            partition.ownership_epoch,
            Ecto.UUID.dump!(target.id),
            kind,
            Ecto.UUID.dump!(leader.node_incarnation_id),
            leader.leader_epoch,
            Ecto.UUID.dump!(leader.action_token)
          ]
        )

        partition
      end)
    else
      false -> {:error, :invalid_partition_transition_kind}
      {:error, _} = error -> error
    end
  end

  def mark_partition_ready(%NodeIncarnation{} = session, partition_id)
      when is_integer(partition_id) do
    Repo.transaction(fn ->
      _ = Protocol.locked_active!()
      _ = lock_node!(session)
      set_local!("maraithon.runtime_node_action", session.id)

      result =
        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_partitions
          SET state = 'ready', ready_at = timezone('UTC', clock_timestamp()),
              draining_at = NULL, updated_at = timezone('UTC', clock_timestamp())
          WHERE partition_id = $1 AND state = 'preparing'
            AND owner_node_incarnation_id = $2::uuid
            AND lease_expires_at > timezone('UTC', clock_timestamp())
          RETURNING partition_id, activation_epoch, ownership_epoch,
                    owner_node_incarnation_id, transition_id, state, lease_expires_at,
                    ready_at, draining_at, last_moved_at, fair_sequence, inserted_at, updated_at
          """,
          [partition_id, Ecto.UUID.dump!(session.id)]
        )

      partition = load!(Partition, result, :partition_authority_lost)

      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_partition_transitions
        SET state = 'ready', ready_at = timezone('UTC', clock_timestamp()),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND state = 'preparing'
        """,
        [Ecto.UUID.dump!(partition.transition_id)]
      )

      partition
    end)
  end

  def renew_partitions(%NodeIncarnation{} = session, ttl_ms) do
    with :ok <- valid_ttl(ttl_ms) do
      Repo.transaction(fn ->
        _ = Protocol.locked_active!()
        _ = lock_node!(session)
        set_local!("maraithon.runtime_node_action", session.id)

        result =
          SQL.query!(
            Repo,
            """
            UPDATE public.runtime_partitions
            SET lease_expires_at = timezone('UTC', clock_timestamp()) +
                  ($2::bigint * interval '1 millisecond'),
                updated_at = timezone('UTC', clock_timestamp())
            WHERE owner_node_incarnation_id = $1::uuid
              AND state IN ('preparing', 'ready', 'draining')
              AND lease_expires_at > timezone('UTC', clock_timestamp())
            RETURNING partition_id, activation_epoch, ownership_epoch,
                      owner_node_incarnation_id, transition_id, state, lease_expires_at,
                      ready_at, draining_at, last_moved_at, fair_sequence, inserted_at, updated_at
            """,
            [Ecto.UUID.dump!(session.id), ttl_ms]
          )

        load_many(Partition, result)
      end)
    end
  end

  def begin_partition_drain(leader, partition_id, opts \\ []) when is_map(leader) do
    kind = Keyword.get(opts, :kind, "rebalance")
    target_id = Keyword.get(opts, :target_node_incarnation_id)
    blocked? = Keyword.get(opts, :blocked?, false)

    with true <- kind in ~w(rebalance steal shutdown lease_expired),
         {:ok, target_dump} <- optional_uuid_dump(target_id) do
      Repo.transaction(fn ->
        activation_epoch = fence_leader!(leader)
        set_local!("maraithon.runtime_leader_action", leader.action_token)

        [[from_node, epoch]] =
          SQL.query!(
            Repo,
            """
            SELECT owner_node_incarnation_id, ownership_epoch
            FROM public.runtime_partitions
            WHERE partition_id = $1 AND state IN ('preparing', 'ready', 'draining', 'blocked')
            FOR UPDATE
            """,
            [partition_id]
          ).rows

        transition_id = Ecto.UUID.generate()
        state = if blocked?, do: "blocked", else: "draining"
        reason = if blocked?, do: "physical_task_termination_proof_required", else: nil

        SQL.query!(
          Repo,
          """
          INSERT INTO public.runtime_partition_transitions
            (id, activation_epoch, partition_id, partition_epoch,
             from_node_incarnation_id, to_node_incarnation_id, kind, state,
             leader_node_incarnation_id, leader_epoch, leader_action_token,
             requested_at, blocked_reason, inserted_at, updated_at)
          VALUES ($1::uuid, $2::uuid, $3, $4, $5::uuid, $6::uuid, $7, $8,
                  $9::uuid, $10, $11::uuid, timezone('UTC', clock_timestamp()), $12,
                  timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
          """,
          [
            Ecto.UUID.dump!(transition_id),
            Ecto.UUID.dump!(activation_epoch),
            partition_id,
            epoch,
            from_node,
            target_dump,
            kind,
            state,
            Ecto.UUID.dump!(leader.node_incarnation_id),
            leader.leader_epoch,
            Ecto.UUID.dump!(leader.action_token),
            reason
          ]
        )

        result =
          SQL.query!(
            Repo,
            """
            UPDATE public.runtime_partitions
            SET transition_id = $2::uuid, state = $3, ready_at = NULL,
                draining_at = COALESCE(draining_at, timezone('UTC', clock_timestamp())),
                updated_at = timezone('UTC', clock_timestamp())
            WHERE partition_id = $1 AND ownership_epoch = $4
            RETURNING partition_id, activation_epoch, ownership_epoch,
                      owner_node_incarnation_id, transition_id, state, lease_expires_at,
                      ready_at, draining_at, last_moved_at, fair_sequence, inserted_at, updated_at
            """,
            [partition_id, Ecto.UUID.dump!(transition_id), state, epoch]
          )

        load!(Partition, result, :partition_authority_lost)
      end)
    else
      false -> {:error, :invalid_partition_transition_kind}
      {:error, _} = error -> error
    end
  end

  def revoke_partition_workload(%NodeIncarnation{} = session, partition_id) do
    Repo.transaction(fn ->
      _ = Protocol.locked_active!()
      _ = lock_node!(session)
      set_local!("maraithon.runtime_node_action", session.id)

      case SQL.query!(
             Repo,
             """
             SELECT ownership_epoch FROM public.runtime_partitions
             WHERE partition_id = $1 AND owner_node_incarnation_id = $2::uuid
               AND state IN ('draining', 'blocked') FOR SHARE
             """,
             [partition_id, Ecto.UUID.dump!(session.id)]
           ).rows do
        [[epoch]] ->
          _ =
            Maraithon.Effects.Cancellation.request_coordination_drain_in_transaction!(
              session.id,
              partition_id,
              epoch,
              "coordination_partition_draining"
            )

          SQL.query!(
            Repo,
            """
            UPDATE public.agent_runtime_leases
            SET ready_at = NULL,
                draining_at = COALESCE(draining_at, timezone('UTC', clock_timestamp())),
                updated_at = timezone('UTC', clock_timestamp())
            WHERE coordination_partition_id = $1 AND coordination_partition_epoch = $2
              AND coordination_node_incarnation_id = $3::uuid
              AND lease_until > timezone('UTC', clock_timestamp())
            """,
            [partition_id, epoch, Ecto.UUID.dump!(session.id)]
          )

          request_task_termination_for_partition!(session.id, partition_id, epoch)
          :revoked

        [] ->
          Repo.rollback(:partition_authority_lost)
      end
    end)
  end

  def release_drained_partition(leader, partition_id) when is_map(leader) do
    Repo.transaction(fn ->
      _ = fence_leader!(leader)
      set_local!("maraithon.runtime_leader_action", leader.action_token)

      [[transition]] =
        SQL.query!(
          Repo,
          "SELECT transition_id FROM public.runtime_partitions WHERE partition_id = $1 FOR UPDATE",
          [partition_id]
        ).rows

      result =
        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_partitions
          SET activation_epoch = NULL, owner_node_incarnation_id = NULL,
              transition_id = NULL, state = 'unassigned', lease_expires_at = NULL,
              ready_at = NULL, draining_at = NULL,
              updated_at = timezone('UTC', clock_timestamp())
          WHERE partition_id = $1 AND state IN ('draining', 'blocked')
          RETURNING partition_id
          """,
          [partition_id]
        )

      if result.num_rows != 1, do: Repo.rollback(:partition_not_drained)

      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_partition_transitions
        SET state = 'completed', completed_at = timezone('UTC', clock_timestamp()),
            updated_at = timezone('UTC', clock_timestamp())
        WHERE id = $1::uuid AND state IN ('draining', 'blocked')
        """,
        [transition]
      )

      :released
    end)
  end

  def owned_partitions(%NodeIncarnation{} = session, states \\ ["ready"]) do
    Repo.all(
      from p in Partition,
        where: p.owner_node_incarnation_id == ^session.id,
        where: p.activation_epoch == ^session.activation_epoch,
        where: p.state in ^states,
        where: p.lease_expires_at > fragment("timezone('UTC', clock_timestamp())"),
        order_by: p.partition_id
    )
  end

  def active_nodes do
    Repo.all(
      from n in NodeIncarnation,
        where: n.state == "ready" and not is_nil(n.ready_at),
        where: n.lease_expires_at > fragment("timezone('UTC', clock_timestamp())"),
        order_by: n.id
    )
  end

  def fence_partition!(%NodeIncarnation{} = session, partition_id, epoch, mode \\ :ready)
      when mode in [:ready, :owner] do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "partition fence requires transaction")

    _ = Protocol.locked_active!()
    states = if mode == :ready, do: ["ready"], else: ["ready", "draining"]

    case SQL.query!(
           Repo,
           """
           SELECT partition_id FROM public.runtime_partitions
           WHERE partition_id = $1 AND activation_epoch = $2::uuid AND ownership_epoch = $3
             AND owner_node_incarnation_id = $4::uuid AND state = ANY($5::text[])
             AND lease_expires_at > timezone('UTC', clock_timestamp())
           FOR SHARE
           """,
           [
             partition_id,
             Ecto.UUID.dump!(session.activation_epoch),
             epoch,
             Ecto.UUID.dump!(session.id),
             states
           ]
         ).rows do
      [[^partition_id]] -> :ok
      [] -> Repo.rollback(:partition_authority_lost)
    end
  end

  defp take_leader!(session, activation_epoch, token, ttl_ms) do
    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_leader_authorities
        SET activation_epoch = $1::uuid, leader_epoch = leader_epoch + 1,
            node_incarnation_id = $2::uuid, action_token = $3::uuid,
            state = 'preparing', lease_expires_at = timezone('UTC', clock_timestamp()) +
              ($4::bigint * interval '1 millisecond'),
            ready_at = NULL, draining_at = NULL, updated_at = timezone('UTC', clock_timestamp())
        WHERE role = 'partition_planner'
        RETURNING activation_epoch, leader_epoch, node_incarnation_id, action_token,
                  state, lease_expires_at, ready_at
        """,
        [
          Ecto.UUID.dump!(activation_epoch),
          Ecto.UUID.dump!(session.id),
          Ecto.UUID.dump!(token),
          ttl_ms
        ]
      )

    load_leader!(result)
  end

  defp fence_leader!(leader) do
    set_local!("maraithon.runtime_leader_action", leader.action_token)

    case SQL.query!(
           Repo,
           """
           SELECT activation_epoch FROM public.runtime_leader_authorities
           WHERE role = 'partition_planner' AND state = 'ready'
             AND activation_epoch = $1::uuid AND leader_epoch = $2
             AND node_incarnation_id = $3::uuid AND action_token = $4::uuid
             AND lease_expires_at > timezone('UTC', clock_timestamp())
           FOR SHARE
           """,
           leader_params(leader)
         ).rows do
      [[epoch]] -> Ecto.UUID.load!(epoch)
      [] -> Repo.rollback(:leader_authority_lost)
    end
  end

  defp revoke_owned_leader!(session) do
    case SQL.query!(
           Repo,
           """
           SELECT action_token FROM public.runtime_leader_authorities
           WHERE role = 'partition_planner' AND node_incarnation_id = $1::uuid
             AND state IN ('preparing', 'ready') FOR UPDATE
           """,
           [Ecto.UUID.dump!(session.id)]
         ).rows do
      [[token]] ->
        token = Ecto.UUID.load!(token)
        set_local!("maraithon.runtime_leader_action", token)

        SQL.query!(
          Repo,
          """
          UPDATE public.runtime_leader_authorities
          SET state = 'draining', ready_at = NULL,
              draining_at = timezone('UTC', clock_timestamp()),
              updated_at = timezone('UTC', clock_timestamp())
          WHERE role = 'partition_planner' AND node_incarnation_id = $1::uuid
            AND action_token = $2::uuid AND state IN ('preparing', 'ready')
          """,
          [Ecto.UUID.dump!(session.id), Ecto.UUID.dump!(token)]
        )

      [] ->
        :ok
    end
  end

  defp request_task_termination_for_partition!(node_id, partition_id, epoch) do
    rows =
      SQL.query!(
        Repo,
        """
        SELECT id FROM public.runtime_task_assignments
        WHERE node_incarnation_id = $1::uuid AND partition_id = $2 AND partition_epoch = $3
          AND state IN ('reserved', 'running') AND work_kind <> 'effect'
        ORDER BY inserted_at, id FOR UPDATE
        """,
        [Ecto.UUID.dump!(node_id), partition_id, epoch]
      ).rows

    request_task_rows!(rows)
  end

  defp request_task_termination_for_node!(node_id) do
    rows =
      SQL.query!(
        Repo,
        """
        SELECT id FROM public.runtime_task_assignments
        WHERE node_incarnation_id = $1::uuid AND state IN ('reserved', 'running')
          AND work_kind <> 'effect'
        ORDER BY inserted_at, id FOR UPDATE
        """,
        [Ecto.UUID.dump!(node_id)]
      ).rows

    request_task_rows!(rows)
  end

  defp request_task_rows!(rows) do
    Enum.each(rows, fn [id] ->
      assignment_id = Ecto.UUID.load!(id)
      set_local!("maraithon.runtime_task_action", assignment_id)

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
        """,
        [id]
      )
    end)
  end

  defp update_node!(session, set_sql, extra_where) do
    result =
      SQL.query!(
        Repo,
        """
        UPDATE public.runtime_node_incarnations SET #{set_sql}
        WHERE id = $1::uuid AND activation_epoch = $2::uuid AND #{extra_where}
        RETURNING id, activation_epoch, node_name, revision, state, lease_expires_at,
                  ready_at, draining_at, revoked_at, metadata, inserted_at, updated_at
        """,
        [Ecto.UUID.dump!(session.id), Ecto.UUID.dump!(session.activation_epoch)]
      )

    load!(NodeIncarnation, result, :node_incarnation_lost)
  end

  defp lock_node!(session) do
    case SQL.query!(
           Repo,
           """
           SELECT id, activation_epoch, node_name, revision, state, lease_expires_at,
                  ready_at, draining_at, revoked_at, metadata, inserted_at, updated_at
           FROM public.runtime_node_incarnations
           WHERE id = $1::uuid AND activation_epoch = $2::uuid
             AND lease_expires_at > timezone('UTC', clock_timestamp())
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(session.id), Ecto.UUID.dump!(session.activation_epoch)]
         ) do
      %{rows: [_]} = result -> load(NodeIncarnation, result)
      _ -> Repo.rollback(:node_incarnation_lost)
    end
  end

  defp load(schema, %{columns: columns, rows: [row]}) do
    row = decode_json(columns, row)
    Repo.load(schema, {columns, row})
  end

  defp load!(schema, %{rows: []}, reason), do: Repo.rollback(reason)
  defp load!(schema, result, _reason), do: load(schema, result)

  defp load_many(schema, %{columns: columns, rows: rows}),
    do: Enum.map(rows, &Repo.load(schema, {columns, decode_json(columns, &1)}))

  defp load_leader!(%{rows: []}), do: Repo.rollback(:leader_authority_lost)

  defp load_leader!(%{columns: columns, rows: [row]}) do
    data = Map.new(Enum.zip(columns, row))

    %{
      activation_epoch: Ecto.UUID.load!(data["activation_epoch"]),
      leader_epoch: data["leader_epoch"],
      node_incarnation_id: Ecto.UUID.load!(data["node_incarnation_id"]),
      action_token: Ecto.UUID.load!(data["action_token"]),
      state: data["state"],
      lease_expires_at: data["lease_expires_at"],
      ready_at: data["ready_at"]
    }
  end

  defp leader_params(leader),
    do: [
      Ecto.UUID.dump!(leader.activation_epoch),
      leader.leader_epoch,
      Ecto.UUID.dump!(leader.node_incarnation_id),
      Ecto.UUID.dump!(leader.action_token)
    ]

  defp decode_json(columns, row) do
    case Enum.find_index(columns, &(&1 == "metadata")) do
      nil ->
        row

      index ->
        case Enum.at(row, index) do
          value when is_binary(value) -> List.replace_at(row, index, Jason.decode!(value))
          _ -> row
        end
    end
  end

  defp set_local!(key, value) do
    SQL.query!(Repo, "SELECT set_config($1, $2, true)", [key, to_string(value)])
    :ok
  end

  defp db_future?(%NaiveDateTime{} = expires_at),
    do: NaiveDateTime.compare(expires_at, db_now!()) == :gt

  defp db_future?(%DateTime{} = expires_at),
    do: DateTime.compare(expires_at, DateTime.from_naive!(db_now!(), "Etc/UTC")) == :gt

  defp db_now!,
    do: SQL.query!(Repo, "SELECT timezone('UTC', clock_timestamp())", []).rows |> hd() |> hd()

  defp optional_uuid_dump(nil), do: {:ok, nil}

  defp optional_uuid_dump(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, Ecto.UUID.dump!(uuid)}
      :error -> {:error, :invalid_target_incarnation}
    end
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_incarnation_id}
    end
  end

  defp valid_text(value) when is_binary(value) and byte_size(value) in 1..255, do: :ok
  defp valid_text(_), do: {:error, :invalid_incarnation_text}
  defp valid_ttl(value) when is_integer(value) and value in 1_000..@max_ttl_ms, do: :ok
  defp valid_ttl(_), do: {:error, :invalid_coordination_ttl}
end
