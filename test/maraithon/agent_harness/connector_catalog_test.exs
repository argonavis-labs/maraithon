defmodule Maraithon.AgentHarness.ConnectorCatalogTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.AgentHarness.ConnectorCatalog
  alias Maraithon.ConnectedAccounts

  test "summarizes connected apps, missing requirements, tools, and MCP allowlist" do
    user_id = "connector-catalog-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, google_account} =
      ConnectedAccounts.upsert_manual(user_id, "google", %{
        external_account_id: "google-account",
        metadata: %{"email" => user_id}
      })

    {:ok, telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042"}
      })

    manifest = %{
      required_connectors: %{
        "google" => [%{"label" => "Google"}],
        "telegram" => [%{"label" => "Telegram"}],
        "slack" => [%{"label" => "Slack"}]
      },
      tool_allowlist: ["gmail.search", "telegram.send", "unknown.tool"],
      mcp_allowlist: ["google", "telegram"]
    }

    catalog = ConnectorCatalog.for_user(user_id, manifest)
    google_account_id = google_account.id
    telegram_account_id = telegram_account.id

    assert catalog.mcp_allowlist == ["google", "telegram"]

    assert [
             %{provider: "google", connected_accounts: 1, account_ids: [^google_account_id]},
             %{provider: "telegram", connected_accounts: 1, account_ids: [^telegram_account_id]}
           ] = catalog.connected_apps

    assert catalog.missing_required_connectors == [
             %{provider: "slack", requirements: [%{"label" => "Slack"}]}
           ]

    assert Enum.map(catalog.tools, & &1.name) == ["gmail.search", "telegram.send", "unknown.tool"]
    assert Enum.find(catalog.tools, &(&1.name == "telegram.send")).side_effect == "write"
    assert Enum.find(catalog.tools, &(&1.name == "unknown.tool")).side_effect == "unknown"
  end

  test "returns a dry catalog for anonymous or system agents" do
    catalog =
      ConnectorCatalog.for_user(nil, %{
        required_connectors: %{"google" => [%{"label" => "Google"}]},
        tool_allowlist: ["llm.complete"],
        mcp_allowlist: ["google"]
      })

    assert catalog.connected_apps == []
    assert catalog.missing_required_connectors == []
    assert catalog.required_connectors == %{"google" => [%{"label" => "Google"}]}
    assert [%{name: "llm.complete", side_effect: "generate"}] = catalog.tools
  end
end
