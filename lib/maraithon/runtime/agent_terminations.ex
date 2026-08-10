defmodule Maraithon.Runtime.AgentTerminations do
  @moduledoc """
  Proof-gated convergence for exact physical Agent termination.

  Lease expiry and routing/supervision failures only create durable requested
  incidents.  They never delete a lease or create a restart guard.  The exact
  lease can disappear through this path only after either the original local
  monitor observes `:DOWN`, or an operator supplies a signed destruction
  attestation for the lease's complete coordination incarnation.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Maraithon.Agents.Agent
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.AgentTerminationIncident
  alias Maraithon.Runtime.AgentTerminationProof
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.IncidentLog

  @default_window_ms 600_000
  @default_max_crashes 3
  @default_backoffs_ms [5_000, 15_000, 30_000]
  @reconciliation_claim_ms 30_000
  @max_batch 500
  @attestation_domain "maraithon-agent-termination-v1"
  @operator_role "admin+external_agent_termination_attestor"

  @doc "Requests reconciliation after proving only that the exact lease is expired."
  def request_expired(agent_id, lease_token, opts \\ [])

  def request_expired(agent_id, lease_token, opts) when is_list(opts) do
    with {:ok, agent_id} <- uuid(agent_id),
         {:ok, lease_token} <- uuid(lease_token),
         {:ok, policy} <- policy(opts) do
      Repo.transaction(fn ->
        agent = lock_agent(agent_id)
        lease = lock_lease(agent_id)
        now = DatabaseClock.now!()

        case exact_lease(lease, lease_token) do
          {:ok, exact} ->
            if DateTime.compare(exact.lease_until, now) == :gt do
              {:ignored, :lease_renewed}
            else
              {incident, inserted?} =
                put_request!(agent, exact, "lease_expired", policy, now)

              {if(inserted?, do: :requested, else: :duplicate), incident, inserted?}
            end

          :stale ->
            {:ignored, :stale_owner}
        end
      end)
      |> unwrap_request()
    end
  end

  def request_expired(_agent_id, _lease_token, _opts),
    do: {:error, :invalid_agent_termination}

  @doc "Persists ambiguity without treating a start/route/supervisor result as a DOWN."
  def request_ambiguous(agent_id, lease_token, reason, opts \\ [])

  def request_ambiguous(agent_id, lease_token, reason, opts) when is_list(opts) do
    with {:ok, agent_id} <- uuid(agent_id),
         {:ok, lease_token} <- uuid(lease_token),
         {:ok, policy} <- policy(opts) do
      Repo.transaction(fn ->
        agent = lock_agent(agent_id)
        lease = lock_lease(agent_id)
        now = DatabaseClock.now!()

        case exact_lease(lease, lease_token) do
          {:ok, exact} ->
            {incident, inserted?} =
              put_request!(agent, exact, safe_label(reason, "termination_ambiguous"), policy, now)

            {if(inserted?, do: :requested, else: :duplicate), incident, inserted?}

          :stale ->
            case lock_incident_by_lease(lease_token) do
              %AgentTerminationIncident{agent_id: ^agent_id} = incident ->
                {:duplicate, incident, false}

              _ ->
                {:ignored, :stale_owner}
            end
        end
      end)
      |> unwrap_request()
    end
  end

  def request_ambiguous(_agent_id, _lease_token, _reason, _opts),
    do: {:error, :invalid_agent_termination}

  @doc """
  Records the one local proof accepted by the runtime: the original monitor's
  exact `{ref, pid, Agent id, lease token}` DOWN observation.
  """
  def record_local_down(agent_id, lease_token, pid, reason, monitor_started_at, opts \\ [])

  def record_local_down(
        agent_id,
        lease_token,
        pid,
        reason,
        %DateTime{} = monitor_started_at,
        opts
      )
      when is_pid(pid) and is_list(opts) do
    with {:ok, agent_id} <- uuid(agent_id),
         {:ok, lease_token} <- uuid(lease_token),
         {:ok, policy} <- policy(opts) do
      proof_result =
        Repo.transaction(fn ->
          agent = lock_agent(agent_id)
          lease = lock_lease(agent_id)
          incident = lock_incident_by_lease(lease_token)
          now = DatabaseClock.now!()

          with :ok <- exact_identity_present(lease, incident, agent_id, lease_token) do
            {incident, _inserted?} =
              ensure_incident!(
                incident,
                agent,
                lease,
                lease_token,
                safe_label(reason, "agent_down"),
                policy,
                now
              )

            proof =
              case lock_proof(incident.id) do
                nil ->
                  set_local!("maraithon.agent_local_down_proof", incident.id)

                  insert_proof!(incident, %{
                    proof_kind: "local_down",
                    local_pid: inspect(pid),
                    monitor_started_at: monitor_started_at,
                    down_reason: safe_label(reason, "agent_down"),
                    proved_by: Atom.to_string(node()),
                    proved_at: now
                  })

                %AgentTerminationProof{proof_kind: "local_down", local_pid: local_pid} = proof ->
                  if local_pid == inspect(pid),
                    do: proof,
                    else: Repo.rollback(:termination_proof_mismatch)

                _other ->
                  Repo.rollback(:termination_proof_mismatch)
              end

            incident = mark_proven!(incident, proof, now, policy)
            {incident, proof}
          end
        end)

      case proof_result do
        {:ok, {incident, _proof}} -> reconcile_incident(incident.id, opts)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def record_local_down(_agent_id, _lease_token, _pid, _reason, _started_at, _opts),
    do: {:error, :invalid_agent_termination}

  @doc """
  Accepts a detached Ed25519 operator signature over the complete stored
  coordination identity.  The runtime has only the public key and therefore
  cannot manufacture external destruction evidence.
  """
  def attest_external(incident_id, attrs) when is_map(attrs) do
    with {:ok, incident_id} <- uuid(incident_id),
         {:ok, evidence_id} <- bounded(Map.get(attrs, :evidence_id) || attrs["evidence_id"], 256),
         {:ok, digest} <- digest(Map.get(attrs, :evidence_digest) || attrs["evidence_digest"]),
         {:ok, signature} <- signature(Map.get(attrs, :signature) || attrs["signature"]),
         {:ok, proved_by} <- bounded(Map.get(attrs, :proved_by) || attrs["proved_by"], 320),
         %AgentTerminationIncident{} = incident <- Repo.get(AgentTerminationIncident, incident_id),
         :ok <- coordinated_external_identity(incident),
         {:ok, public_key} <- attestation_public_key(),
         payload <- attestation_payload(incident, evidence_id, digest, proved_by),
         true <- :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519]) do
      result =
        Repo.transaction(fn ->
          locked = lock_incident(incident_id)
          lease = lock_lease(locked.agent_id)
          now = DatabaseClock.now!()

          ensure_same_incident!(incident, locked)
          ensure_external_lease_expired!(lease, locked, now)

          proof =
            case lock_proof(locked.id) do
              nil ->
                set_local!(
                  "maraithon.agent_external_termination_attestation",
                  Base.encode16(digest, case: :lower)
                )

                insert_proof!(locked, %{
                  proof_kind: "external_node_destroyed",
                  evidence_id: evidence_id,
                  evidence_digest: digest,
                  attestation_signature: signature,
                  proved_by: proved_by,
                  proved_at: now
                })

              %AgentTerminationProof{
                proof_kind: "external_node_destroyed",
                evidence_id: ^evidence_id,
                evidence_digest: ^digest,
                proved_by: ^proved_by
              } = proof ->
                proof

              _other ->
                Repo.rollback(:termination_proof_mismatch)
            end

          proven = mark_proven!(locked, proof, now, policy_from_incident(locked))
          {proven, proof}
        end)

      case result do
        {:ok, {_proven, proof}} -> {:attested, proof}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :termination_incident_not_found}
      false -> {:error, :invalid_external_termination_attestation}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_external_termination_attestation}
    end
  rescue
    _ -> {:error, :invalid_external_termination_attestation}
  catch
    :exit, _ -> {:error, :invalid_external_termination_attestation}
  end

  def attest_external(_incident_id, _attrs),
    do: {:error, :invalid_external_termination_attestation}

  @doc "Canonical bytes an external attestor must sign."
  def attestation_payload(%AgentTerminationIncident{} = incident, evidence_id, digest, proved_by)
      when is_binary(evidence_id) and is_binary(digest) and is_binary(proved_by) do
    [
      @attestation_domain,
      identity_value(incident.activation_epoch),
      identity_value(incident.node_incarnation_id),
      identity_value(incident.partition_id),
      identity_value(incident.partition_epoch),
      incident.agent_id,
      incident.lease_token,
      evidence_id,
      Base.encode16(digest, case: :lower),
      proved_by
    ]
    |> Enum.join("\n")
  end

  @doc "Creates a bounded, PostgreSQL-clock-checked page of expiry incidents."
  def request_expired_batch(limit \\ 100, opts \\ [])

  def request_expired_batch(limit, opts)
      when is_integer(limit) and limit in 1..@max_batch and is_list(opts) do
    with {:ok, policy} <- policy(opts) do
      Repo.transaction(fn ->
        now = DatabaseClock.now!()

        rows =
          Repo.all(
            from(agent in Agent,
              join: lease in AgentRuntimeLease,
              on: lease.agent_id == agent.id,
              where: lease.lease_until <= ^now,
              order_by: [asc: lease.lease_until, asc: lease.agent_id],
              limit: ^limit,
              lock: "FOR UPDATE SKIP LOCKED",
              select: {agent, lease}
            )
          )

        Enum.map(rows, fn {agent, lease} ->
          {incident, inserted?} =
            put_request!(agent, lease, "lease_expired", policy, now)

          {if(inserted?, do: :requested, else: :duplicate), incident}
        end)
      end)
      |> case do
        {:ok, rows} ->
          Enum.each(rows, fn
            {:requested, incident} -> record_incident(incident)
            _ -> :ok
          end)

          rows

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def request_expired_batch(_limit, _opts),
    do: {:error, :invalid_agent_termination_limit}

  @doc "Claims and reconciles a bounded page of proven incidents with durable retry leases."
  def reconcile_due(limit \\ 100)

  def reconcile_due(limit) when is_integer(limit) and limit in 1..@max_batch do
    case claim_reconciliation_batch(limit) do
      {:ok, ids} ->
        Enum.map(ids, fn id ->
          result = reconcile_incident(id, [])

          case result do
            {:error, reason} -> mark_retry(id, reason)
            _ -> :ok
          end

          {id, result}
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def reconcile_due(_limit), do: {:error, :invalid_agent_termination_limit}

  def reconcile_incident(incident_id, opts \\ []) do
    with {:ok, incident_id} <- uuid(incident_id) do
      AgentRestartGuards.record_termination(incident_id, opts)
    end
  end

  def get(id) when is_binary(id), do: Repo.get(AgentTerminationIncident, id)
  def get(_id), do: nil

  def get_by_lease(lease_token) when is_binary(lease_token) do
    case uuid(lease_token) do
      {:ok, token} -> Repo.get_by(AgentTerminationIncident, lease_token: token)
      _ -> nil
    end
  end

  def get_by_lease(_lease_token), do: nil

  def proof_for(incident_id) when is_binary(incident_id) do
    case uuid(incident_id) do
      {:ok, id} -> Repo.get_by(AgentTerminationProof, incident_id: id)
      _ -> nil
    end
  end

  def proof_for(_incident_id), do: nil

  def open_for_agent(agent_id) when is_binary(agent_id) do
    case uuid(agent_id) do
      {:ok, id} ->
        Repo.one(
          from incident in AgentTerminationIncident,
            where: incident.agent_id == ^id,
            where: incident.status in ["requested", "proven"]
        )

      _ ->
        nil
    end
  end

  def open_for_agent(_agent_id), do: nil

  def operator_url(%AgentTerminationIncident{id: id}),
    do: "/admin/runtime/agent-termination-incidents/#{id}"

  def operator_role, do: @operator_role

  defp claim_reconciliation_batch(limit) do
    Repo.transaction(fn ->
      now = DatabaseClock.now!()
      claimed_until = DateTime.add(now, @reconciliation_claim_ms, :millisecond)

      incidents =
        Repo.all(
          from incident in AgentTerminationIncident,
            where: incident.status == "proven",
            where: incident.retry_at <= ^now,
            order_by: [asc: incident.retry_at, asc: incident.requested_at, asc: incident.id],
            limit: ^limit,
            lock: "FOR UPDATE SKIP LOCKED"
        )

      Enum.map(incidents, fn incident ->
        incident
        |> Ecto.Changeset.change(%{
          reconcile_attempts: incident.reconcile_attempts + 1,
          retry_at: claimed_until,
          last_error: nil,
          updated_at: now
        })
        |> Repo.update!()
        |> Map.fetch!(:id)
      end)
    end)
  end

  defp mark_retry(incident_id, reason) do
    Repo.transaction(fn ->
      case lock_incident(incident_id) do
        %AgentTerminationIncident{status: "proven"} = incident ->
          now = DatabaseClock.now!()

          delay_ms =
            min(300_000, trunc(:math.pow(2, min(incident.reconcile_attempts, 8))) * 1_000)

          incident
          |> Ecto.Changeset.change(%{
            retry_at: DateTime.add(now, delay_ms, :millisecond),
            last_error: safe_label(reason, "reconciliation_failed"),
            updated_at: now
          })
          |> Repo.update!()

        incident ->
          incident
      end
    end)
  end

  defp put_request!(agent, lease, reason, policy, now) do
    case lock_incident_by_lease(lease.owner_token) do
      nil ->
        incident =
          %AgentTerminationIncident{}
          |> AgentTerminationIncident.changeset(incident_attrs(agent, lease, reason, policy, now))
          |> Repo.insert!()

        {incident, true}

      %AgentTerminationIncident{status: "requested"} = incident ->
        updated =
          incident
          |> Ecto.Changeset.change(%{
            request_reason: reason,
            last_requested_at: now,
            request_count: incident.request_count + 1,
            reconciliation_policy: encode_policy(policy),
            updated_at: now
          })
          |> Repo.update!()

        {updated, false}

      incident ->
        {incident, false}
    end
  end

  defp ensure_incident!(nil, agent, %AgentRuntimeLease{} = lease, _token, reason, policy, now),
    do: put_request!(agent, lease, reason, policy, now)

  defp ensure_incident!(
         %AgentTerminationIncident{} = incident,
         _agent,
         _lease,
         _token,
         _reason,
         _policy,
         _now
       ),
       do: {incident, false}

  defp ensure_incident!(_nil, _agent, nil, _token, _reason, _policy, _now),
    do: Repo.rollback(:stale_agent_owner)

  defp incident_attrs(agent, lease, reason, policy, now) do
    %{
      id: Ecto.UUID.generate(),
      activation_epoch: lease.coordination_activation_epoch,
      node_incarnation_id: lease.coordination_node_incarnation_id,
      partition_id: lease.coordination_partition_id,
      partition_epoch: lease.coordination_partition_epoch,
      agent_id: agent.id,
      lease_token: lease.owner_token,
      owner_node: lease.owner_node,
      status: "requested",
      request_reason: reason,
      requested_at: now,
      last_requested_at: now,
      request_count: 1,
      reconcile_attempts: 0,
      retry_at: now,
      reconciliation_policy: encode_policy(policy),
      inserted_at: now,
      updated_at: now
    }
  end

  defp insert_proof!(incident, attrs) do
    identity = %{
      id: Ecto.UUID.generate(),
      incident_id: incident.id,
      activation_epoch: incident.activation_epoch,
      node_incarnation_id: incident.node_incarnation_id,
      partition_id: incident.partition_id,
      partition_epoch: incident.partition_epoch,
      agent_id: incident.agent_id,
      lease_token: incident.lease_token,
      inserted_at: attrs.proved_at,
      updated_at: attrs.proved_at
    }

    %AgentTerminationProof{}
    |> AgentTerminationProof.changeset(Map.merge(identity, attrs))
    |> Repo.insert!()
  end

  defp mark_proven!(%AgentTerminationIncident{status: "requested"} = incident, proof, now, policy) do
    incident
    |> Ecto.Changeset.change(%{
      status: "proven",
      proof_id: proof.id,
      proof_kind: proof.proof_kind,
      proved_at: proof.proved_at,
      retry_at: now,
      last_error: nil,
      reconciliation_policy: encode_policy(policy),
      updated_at: now
    })
    |> Repo.update!()
  end

  defp mark_proven!(
         %AgentTerminationIncident{proof_id: proof_id} = incident,
         %{id: proof_id},
         _now,
         _policy
       ),
       do: incident

  defp mark_proven!(_incident, _proof, _now, _policy),
    do: Repo.rollback(:termination_proof_mismatch)

  defp exact_identity_present(
         %AgentRuntimeLease{owner_token: lease_token},
         _incident,
         _agent_id,
         lease_token
       ),
       do: :ok

  defp exact_identity_present(
         _lease,
         %AgentTerminationIncident{agent_id: agent_id, lease_token: lease_token},
         agent_id,
         lease_token
       ),
       do: :ok

  defp exact_identity_present(_lease, _incident, _agent_id, _lease_token),
    do: Repo.rollback(:stale_agent_owner)

  defp exact_lease(%AgentRuntimeLease{owner_token: token} = lease, token), do: {:ok, lease}
  defp exact_lease(_lease, _token), do: :stale

  defp ensure_external_lease_expired!(nil, %AgentTerminationIncident{}, _now), do: :ok

  defp ensure_external_lease_expired!(
         %AgentRuntimeLease{owner_token: token, lease_until: lease_until},
         %AgentTerminationIncident{lease_token: token},
         now
       ) do
    if DateTime.compare(lease_until, now) in [:lt, :eq],
      do: :ok,
      else: Repo.rollback(:agent_lease_still_live)
  end

  defp ensure_external_lease_expired!(_lease, _incident, _now),
    do: Repo.rollback(:stale_agent_owner)

  defp coordinated_external_identity(%AgentTerminationIncident{
         activation_epoch: activation_epoch,
         node_incarnation_id: node_incarnation_id,
         partition_id: partition_id,
         partition_epoch: partition_epoch
       })
       when is_binary(activation_epoch) and is_binary(node_incarnation_id) and
              is_integer(partition_id) and is_integer(partition_epoch),
       do: :ok

  defp coordinated_external_identity(_incident),
    do: {:error, :external_attestation_requires_coordination_identity}

  defp ensure_same_incident!(left, right) do
    if {left.id, left.activation_epoch, left.node_incarnation_id, left.partition_id,
        left.partition_epoch, left.agent_id, left.lease_token} ==
         {right.id, right.activation_epoch, right.node_incarnation_id, right.partition_id,
          right.partition_epoch, right.agent_id, right.lease_token},
       do: :ok,
       else: Repo.rollback(:termination_incident_changed)
  end

  defp lock_agent(agent_id) do
    case Repo.one(from agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE") do
      %Agent{} = agent -> agent
      nil -> Repo.rollback(:agent_not_found)
    end
  end

  defp lock_lease(agent_id) do
    Repo.one(
      from lease in AgentRuntimeLease,
        where: lease.agent_id == ^agent_id,
        lock: "FOR UPDATE"
    )
  end

  defp lock_incident(id) do
    case Repo.one(
           from incident in AgentTerminationIncident,
             where: incident.id == ^id,
             lock: "FOR UPDATE"
         ) do
      %AgentTerminationIncident{} = incident -> incident
      nil -> Repo.rollback(:termination_incident_not_found)
    end
  end

  defp lock_incident_by_lease(lease_token) do
    Repo.one(
      from incident in AgentTerminationIncident,
        where: incident.lease_token == ^lease_token,
        lock: "FOR UPDATE"
    )
  end

  defp lock_proof(incident_id) do
    Repo.one(
      from proof in AgentTerminationProof,
        where: proof.incident_id == ^incident_id,
        lock: "FOR SHARE"
    )
  end

  defp set_local!(key, value) do
    SQL.query!(Repo, "SELECT set_config($1, $2, true)", [key, to_string(value)])
  end

  defp unwrap_request({:ok, {:ignored, reason}}), do: {:ignored, reason}

  defp unwrap_request({:ok, {status, incident, inserted?}}) do
    if inserted?, do: record_incident(incident)
    {status, incident}
  end

  defp unwrap_request({:error, reason}), do: {:error, reason}

  defp record_incident(incident) do
    IncidentLog.record(%{
      kind: :agent_termination_unproven,
      agent_id: incident.agent_id,
      reason: incident.request_reason,
      metadata: %{
        "termination_incident_id" => incident.id,
        "lease_token" => incident.lease_token,
        "activation_epoch" => incident.activation_epoch,
        "node_incarnation_id" => incident.node_incarnation_id,
        "partition_id" => incident.partition_id,
        "partition_epoch" => incident.partition_epoch,
        "owner_node" => incident.owner_node,
        "operator_url" => operator_url(incident),
        "required_role" => @operator_role
      }
    })
  end

  defp policy(opts) do
    allowed = [:window_ms, :max_crashes, :backoffs_ms]

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      policy = %{
        window_ms: Keyword.get(opts, :window_ms, @default_window_ms),
        max_crashes: Keyword.get(opts, :max_crashes, @default_max_crashes),
        backoffs_ms: Keyword.get(opts, :backoffs_ms, @default_backoffs_ms)
      }

      if is_integer(policy.window_ms) and policy.window_ms in 1_000..86_400_000 and
           is_integer(policy.max_crashes) and policy.max_crashes in 1..100 and
           is_list(policy.backoffs_ms) and policy.backoffs_ms != [] and
           Enum.all?(policy.backoffs_ms, &(is_integer(&1) and &1 in 0..3_600_000)) do
        {:ok, policy}
      else
        {:error, :invalid_agent_termination}
      end
    else
      {:error, :invalid_agent_termination}
    end
  end

  defp encode_policy(policy) do
    %{
      "window_ms" => policy.window_ms,
      "max_crashes" => policy.max_crashes,
      "backoffs_ms" => policy.backoffs_ms
    }
  end

  defp policy_from_incident(%AgentTerminationIncident{reconciliation_policy: stored}) do
    %{
      window_ms: stored["window_ms"] || @default_window_ms,
      max_crashes: stored["max_crashes"] || @default_max_crashes,
      backoffs_ms: stored["backoffs_ms"] || @default_backoffs_ms
    }
  end

  defp attestation_public_key do
    value =
      Application.get_env(:maraithon, __MODULE__, [])
      |> Keyword.get(:external_attestation_public_key)

    case value do
      key when is_binary(key) and byte_size(key) == 32 ->
        {:ok, key}

      encoded when is_binary(encoded) ->
        encoded = String.trim(encoded)

        case Base.decode16(encoded, case: :mixed) do
          {:ok, key} when byte_size(key) == 32 ->
            {:ok, key}

          _ ->
            case decode_base64(encoded) do
              {:ok, key} when byte_size(key) == 32 -> {:ok, key}
              _ -> {:error, :external_attestation_key_unavailable}
            end
        end

      _ ->
        {:error, :external_attestation_key_unavailable}
    end
  end

  defp digest(value) when is_binary(value) and byte_size(value) == 32, do: {:ok, value}

  defp digest(value) when is_binary(value) do
    case Base.decode16(String.trim(value), case: :mixed) do
      {:ok, digest} when byte_size(digest) == 32 -> {:ok, digest}
      _ -> {:error, :invalid_external_termination_attestation}
    end
  end

  defp digest(_value), do: {:error, :invalid_external_termination_attestation}

  defp signature(value) when is_binary(value) and byte_size(value) == 64, do: {:ok, value}

  defp signature(value) when is_binary(value) do
    case decode_base64(String.trim(value)) do
      {:ok, signature} when byte_size(signature) == 64 -> {:ok, signature}
      _ -> {:error, :invalid_external_termination_attestation}
    end
  end

  defp signature(_value), do: {:error, :invalid_external_termination_attestation}

  defp decode_base64(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.decode64(value, padding: false)
    end
  end

  defp bounded(value, max) when is_binary(value) do
    value = String.trim(value)

    if byte_size(value) in 1..max and String.valid?(value) and
         not Regex.match?(~r/[\x00-\x1F\x7F]/u, value),
       do: {:ok, value},
       else: {:error, :invalid_external_termination_attestation}
  end

  defp bounded(_value, _max), do: {:error, :invalid_external_termination_attestation}

  defp identity_value(nil), do: "none"
  defp identity_value(value), do: to_string(value)

  defp safe_label(value, fallback) do
    value
    |> Maraithon.Redaction.error_class()
    |> case do
      label when is_binary(label) and byte_size(label) in 1..255 ->
        if String.valid?(label) and not Regex.match?(~r/[\x00-\x1F\x7F]/u, label),
          do: label,
          else: fallback

      _ ->
        fallback
    end
  end

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_agent_termination}
    end
  end

  defp uuid(_value), do: {:error, :invalid_agent_termination}
end
