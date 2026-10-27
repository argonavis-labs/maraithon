defmodule Maraithon.Runtime.IngressReceiptsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.ChiefLineageFixtures
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.Runtime.IngressReceipt
  alias Maraithon.Runtime.IngressReceipts

  test "provider identity is tenant-exact, canonical, permanent, and conflict detecting" do
    fixture = ChiefLineageFixtures.base("ingress")

    attrs = %{
      user_id: fixture.user_id,
      agent_id: fixture.agent.id,
      connected_account_id: fixture.account.id,
      provider: fixture.provider,
      ingress_kind: :poll,
      provider_event_key: "event-#{fixture.unique}",
      payload: %{cursor_hint: "safe"}
    }

    assert {:ok, duplicate, :duplicate} = IngressReceipts.record(attrs)
    assert duplicate.id == fixture.receipt.id
    assert duplicate.payload == %{"cursor_hint" => "safe"}
    assert duplicate.provider_account_key == fixture.account.external_account_id
    assert byte_size(duplicate.receipt_key) == 32
    assert byte_size(duplicate.request_fingerprint) == 32

    assert {:error, :ingress_idempotency_conflict} =
             IngressReceipts.record(%{attrs | payload: %{"cursor_hint" => "changed"}})

    assert {:error, :ingress_idempotency_conflict} =
             attrs
             |> Map.put(:provider_occurred_at, ~U[2026-08-09 12:00:00.000000Z])
             |> IngressReceipts.record()

    assert {:error, :ingress_provider_account_mismatch} =
             attrs
             |> Map.put(:provider_account_key, "caller-forked-account")
             |> IngressReceipts.record()

    assert {:error, :ingress_owner_mismatch} =
             IngressReceipts.record(%{attrs | user_id: "other@example.com"})
  end

  test "admission rejects paused, revoked, and disconnected authority without storing content" do
    paused = ChiefLineageFixtures.base("ingress-paused")
    assert {:ok, _paused_agent} = Agents.update_agent(paused.agent, %{install_status: "paused"})

    assert {:error, :ingress_agent_not_enabled} =
             paused
             |> ingress_attrs("paused-event")
             |> IngressReceipts.record()

    revoked = ChiefLineageFixtures.base("ingress-revoked")

    assert {:ok, _revoked_binding} =
             AgentIsolation.upsert_binding(revoked.agent, %{status: "revoked"})

    assert {:error, :ingress_binding_inactive} =
             revoked
             |> ingress_attrs("revoked-event")
             |> IngressReceipts.record()

    disconnected = ChiefLineageFixtures.base("ingress-disconnected")

    assert {:ok, _account} =
             ConnectedAccounts.mark_disconnected(disconnected.user_id, disconnected.provider)

    assert {:error, :ingress_account_not_connected} =
             disconnected
             |> ingress_attrs("disconnected-event")
             |> IngressReceipts.record()

    assert Repo.aggregate(IngressReceipt, :count) == 3
  end

  test "admission requires the exact persisted provider account grant" do
    fixture = ChiefLineageFixtures.base("ingress-grant")

    assert {:ok, _agent} =
             Agents.update_agent(fixture.agent, %{
               connector_grants: %{
                 fixture.provider => %{"account_ids" => ["another-account"]}
               }
             })

    assert {:error, :ingress_connector_not_granted} =
             fixture
             |> ingress_attrs("wrong-grant-event")
             |> IngressReceipts.record()

    other = ChiefLineageFixtures.base("ingress-other-account")

    assert {:error, :ingress_owner_mismatch} =
             fixture
             |> ingress_attrs("wrong-owner-event")
             |> Map.put(:connected_account_id, other.account.id)
             |> IngressReceipts.record()

    assert Repo.aggregate(IngressReceipt, :count) == 2
  end

  test "admission fails closed when the connected account lacks stable external identity" do
    fixture = ChiefLineageFixtures.base("ingress-no-external-identity")

    Repo.query!(
      "UPDATE connected_accounts SET external_account_id = NULL WHERE id = $1",
      [fixture.account.id]
    )

    assert {:error, :invalid_provider_account_identity} =
             fixture
             |> ingress_attrs("missing-provider-account")
             |> IngressReceipts.record()
  end

  test "raw admission rejects credentials and oversized payloads before persistence" do
    fixture = ChiefLineageFixtures.base("ingress-bounds")

    base = %{
      user_id: fixture.user_id,
      agent_id: fixture.agent.id,
      connected_account_id: fixture.account.id,
      provider: fixture.provider,
      provider_account_key: fixture.account.external_account_id,
      ingress_kind: "webhook",
      provider_event_key: "bounded-event"
    }

    assert {:error, :invalid_ingress_payload} =
             IngressReceipts.record(
               Map.put(base, :payload, %{"nested" => %{"access_token" => "do-not-store"}})
             )

    assert {:error, :invalid_ingress_payload} =
             IngressReceipts.record(
               Map.put(base, :payload, %{"providerExceptionBody" => "do-not-store"})
             )

    assert {:error, :invalid_ingress_payload} =
             IngressReceipts.record(
               Map.put(base, :payload, %{"body" => String.duplicate("x", 128_001)})
             )
  end

  defp ingress_attrs(fixture, event_key) do
    %{
      user_id: fixture.user_id,
      agent_id: fixture.agent.id,
      connected_account_id: fixture.account.id,
      provider: fixture.provider,
      ingress_kind: "webhook",
      provider_event_key: event_key,
      payload: %{"source" => "bounded-authorized-event"}
    }
  end
end
