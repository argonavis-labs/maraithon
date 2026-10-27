defmodule Maraithon.DurablePayloadVerificationTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Agents
  alias Maraithon.DurablePayloadPrivacy
  alias Maraithon.DurablePayloadVerification
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Events
  alias Maraithon.Repo
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol
  alias Maraithon.Runtime.Snapshot

  @moduletag database_role: :session

  @evidence_id "test:stopped-fleet:durable-payload-verification"
  @evidence_digest :crypto.hash(:sha256, "test durable payload verification stopped fleet")
  @evidence_operator "durable-payload-verification@example.test"
  @revision String.duplicate("f", 40)
  @activation_evidence [
    evidence_id: @evidence_id,
    evidence_digest: @evidence_digest,
    activated_by: @evidence_operator,
    revision: @revision
  ]
  @contraction_evidence [
    confirmation: "NON_ROLLING_FLEET_DRAINED",
    evidence_id: @evidence_id,
    evidence_digest: @evidence_digest,
    operator: @evidence_operator,
    revision: @revision
  ]

  setup do
    assert ProtocolCutover.mode() == :legacy

    assert {:ok, attestation} =
             CoordinationProtocol.attest_effect_activation_evidence(@activation_evidence)

    assert attestation in [:attested, :already_attested]
    set_runtime_role!()

    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "durable-payload-verification-test"},
        status: "stopped"
      })

    %{agent: agent}
  end

  test "verifies an exact-shaped Snapshot with its integer identity and typed scope", %{
    agent: agent
  } do
    assert {:ok, snapshot} =
             Snapshot.persist(agent.id, 7, :idle, %{cursor: 7}, %{llm_calls: 1}, 3)

    assert {:ok, %{migrated_snapshots: 1, blocked_snapshots: []}} =
             contract_payload_batch!(batch_size: 10)

    snapshot_id = snapshot.id

    assert {:ok, %{verified: 1, failures: []}} =
             DurablePayloadVerification.verify_batch("snapshots", limit: 10)

    assert [[row_identity, ciphertext_digest, projection_digest, version_digest, purge_digest]] =
             Repo.query!("""
             SELECT row_identity, ciphertext_digest, projection_digest, version_digest, purge_digest
             FROM durable_payload_verifications
             WHERE payload_table = 'snapshots'
             """).rows

    assert row_identity == Integer.to_string(snapshot_id)

    for digest <- [ciphertext_digest, projection_digest, version_digest, purge_digest] do
      assert is_binary(digest) and byte_size(digest) == 32
    end

    assert {:ok, %{verified: 0, failures: []}} =
             DurablePayloadVerification.verify_batch("snapshots", limit: 10)
  end

  test "verifies a composite Event identity and invalidates stale proof digests", %{agent: agent} do
    assert {:ok, event} = Events.append(agent.id, "verification_test", %{"secret" => true})

    Repo.query!("UPDATE events SET payload = '{}'::jsonb WHERE id = $1", [event.id])

    assert {:ok, %{verified: 1, failures: []}} =
             DurablePayloadVerification.verify_batch("events", limit: 10)

    expected_identity = Jason.encode!([agent.id, Integer.to_string(event.sequence_num)])

    assert [[^expected_identity]] =
             Repo.query!("""
             SELECT row_identity
             FROM durable_payload_verifications
             WHERE payload_table = 'events'
             """).rows

    Repo.query!("UPDATE events SET payload = $1::jsonb WHERE id = $2", [
      %{"visible" => true},
      event.id
    ])

    assert [] =
             Repo.query!(
               "SELECT 1 FROM durable_payload_verifications WHERE payload_table = 'events'"
             ).rows

    assert {:ok, %{verified: 0, failures: [%{failure: :projection_mismatch}]}} =
             DurablePayloadVerification.verify_batch("events", limit: 10)

    Repo.query!("UPDATE events SET payload = '{}'::jsonb WHERE id = $1", [event.id])

    assert [] =
             Repo.query!(
               "SELECT 1 FROM durable_payload_verification_failures WHERE payload_table = 'events'"
             ).rows

    assert {:ok, %{verified: 1, failures: []}} =
             DurablePayloadVerification.verify_batch("events", limit: 10)
  end

  defp contract_payload_batch!(opts) do
    try do
      DurablePayloadPrivacy.backfill_batch(Keyword.merge(@contraction_evidence, opts))
    after
      set_runtime_role!()
    end
  end

  defp set_runtime_role! do
    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    :ok
  end
end
