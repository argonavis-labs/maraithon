defmodule Maraithon.ChiefLineageFixtures do
  @moduledoc false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.ChiefOfStaff.AcquisitionStore
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.IngressReceipts

  def base(prefix \\ "chief-lineage") do
    unique = System.unique_integer([:positive])
    user_id = "#{prefix}-#{unique}@example.com"
    provider = "chief_provider_#{unique}"

    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_from_oauth(user_id, provider, %{
        access_token: "fixture-token",
        external_account_id: "provider-account-#{unique}",
        scopes: ["chief-test"]
      })

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{},
        install_status: "enabled",
        status: "running",
        connector_grants: %{
          provider => %{"account_ids" => [account.external_account_id]}
        }
      })

    {:ok, _binding} = AgentIsolation.upsert_binding(agent)

    {:ok, directive} =
      AgentDirectives.enqueue(
        agent.id,
        user_id,
        "connector_sync",
        %{"source" => "fixture"},
        "chief-sync-#{unique}"
      )

    {:ok, receipt, :inserted} =
      IngressReceipts.record(%{
        user_id: user_id,
        agent_id: agent.id,
        connected_account_id: account.id,
        provider: provider,
        provider_account_key: account.external_account_id,
        ingress_kind: "poll",
        provider_event_key: "event-#{unique}",
        payload: %{"cursor_hint" => "safe"}
      })

    {:ok, cursor} = SourceCursors.put(account, "fixture_cursor", %{"value" => "cursor-0"})

    {:ok, acquisition, :inserted} =
      AcquisitionStore.begin_run(%{
        user_id: user_id,
        agent_id: agent.id,
        agent_directive_id: directive.id,
        runtime_ingress_receipt_id: receipt.id,
        connected_account_id: account.id,
        source_cursor_id: cursor.id,
        cursor_kind: cursor.kind,
        provider: provider,
        source: "fixture",
        scope_key: "scope-#{unique}",
        request_key: "request-#{unique}",
        contract_version: 1
      })

    %{
      unique: unique,
      user_id: user_id,
      provider: provider,
      account: account,
      agent: agent,
      directive: directive,
      receipt: receipt,
      cursor: cursor,
      acquisition: acquisition
    }
  end

  def terminal_page(fixture, envelopes \\ []) do
    AcquisitionStore.record_page(
      fixture.acquisition,
      %{
        ordinal: 0,
        request_cursor: fixture.acquisition.start_cursor,
        next_cursor: nil,
        terminal: true,
        request: %{"cursor" => fixture.acquisition.start_cursor},
        response_proof: %{"pagination_exhausted" => true}
      },
      envelopes
    )
  end

  def source_envelope(fixture, suffix \\ "1") do
    %{
      source_item_key: "item-#{fixture.unique}-#{suffix}",
      source_revision_key: "revision-#{suffix}",
      raw_payload: %{"body" => "raw #{suffix}"},
      normalized_payload: %{"summary" => "normalized #{suffix}"},
      provenance: %{"fixture" => true}
    }
  end
end
