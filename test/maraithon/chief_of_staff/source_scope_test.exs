defmodule Maraithon.ChiefOfStaff.SourceScopeTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ChiefOfStaff.SourceScope
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google

  test "intersects an exact requested account scope with live credential capabilities" do
    live_scope = %{
      "google_accounts" => [
        %{
          "provider" => "google:founder@example.com",
          "account_email" => "founder@example.com",
          "services" => ["calendar", "gmail"]
        },
        %{
          "provider" => "google:ops@example.com",
          "account_email" => "ops@example.com",
          "services" => ["gmail"]
        }
      ],
      "slack_workspaces" => [
        %{
          "team_id" => "T12345",
          "team_name" => "Agora",
          "services" => ["channels", "dms"]
        }
      ],
      "telegram_connected" => true
    }

    requested_scope = %{
      "google_accounts" => [
        %{
          "provider" => "google:founder@example.com",
          "services" => ["gmail"]
        },
        %{
          "provider" => "google:disconnected@example.com",
          "services" => ["gmail"]
        }
      ],
      "slack_workspaces" => [
        %{"team_id" => "T12345", "services" => ["dms"]}
      ],
      "telegram_connected" => false
    }

    assert SourceScope.intersect(live_scope, requested_scope) == %{
             "google_accounts" => [
               %{
                 "provider" => "google:founder@example.com",
                 "account_email" => "founder@example.com",
                 "services" => ["gmail"]
               }
             ],
             "slack_workspaces" => [
               %{
                 "team_id" => "T12345",
                 "team_name" => "Agora",
                 "services" => ["dms"]
               }
             ],
             "telegram_connected" => false
           }
  end

  test "resolves all connected Google accounts and Slack workspaces for chief of staff" do
    user_id = "chief-scope@example.com"
    _user = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _founder_google} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-founder-token",
        scopes: Google.scopes_for(["gmail", "calendar"]),
        metadata: %{"account_email" => "founder@example.com"}
      })

    {:ok, _ops_google} =
      OAuth.store_tokens(user_id, "google:ops@example.com", %{
        access_token: "google-ops-token",
        scopes: Google.scopes_for(["gmail", "calendar"]),
        metadata: %{"account_email" => "ops@example.com"}
      })

    {:ok, _slack_bot} =
      OAuth.store_tokens(user_id, "slack:T12345", %{
        access_token: "xoxb-agora-token",
        scopes: ["channels:read"],
        metadata: %{"team_id" => "T12345", "team_name" => "Agora"}
      })

    {:ok, _slack_user} =
      OAuth.store_tokens(user_id, "slack:T12345:user:U12345", %{
        access_token: "xoxp-agora-token",
        scopes: ["im:read", "search:read"],
        metadata: %{"team_id" => "T12345", "team_name" => "Agora"}
      })

    {:ok, _slack_two_bot} =
      OAuth.store_tokens(user_id, "slack:T67890", %{
        access_token: "xoxb-vote-token",
        scopes: ["channels:read"],
        metadata: %{"team_id" => "T67890", "team_name" => "Vote Agora"}
      })

    {:ok, _telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042"}
      })

    scope = SourceScope.resolve(user_id)

    assert scope["google_accounts"] == [
             %{
               "account_email" => "founder@example.com",
               "provider" => "google:founder@example.com",
               "services" => ["calendar", "gmail"]
             },
             %{
               "account_email" => "ops@example.com",
               "provider" => "google:ops@example.com",
               "services" => ["calendar", "gmail"]
             }
           ]

    assert scope["slack_workspaces"] == [
             %{
               "services" => ["channels", "dms"],
               "team_id" => "T12345",
               "team_name" => "Agora"
             },
             %{
               "services" => ["channels"],
               "team_id" => "T67890",
               "team_name" => "Vote Agora"
             }
           ]

    assert scope["telegram_connected"] == true

    assert SourceScope.subscriptions(scope, user_id) == [
             "email:founder@example.com",
             "email:ops@example.com",
             "calendar:chief-scope@example.com",
             "slack:T12345",
             "slack:T67890"
           ]
  end

  test "keeps errored providers recoverable but excludes disconnected accounts" do
    user_id = "chief-scope-error@example.com"
    provider = "google:broken@example.com"
    _user = Accounts.get_or_create_user_by_email(user_id)

    token_data = %{
      access_token: "google-broken-token",
      scopes: Google.scopes_for(["gmail"]),
      metadata: %{"account_email" => "broken@example.com"}
    }

    assert {:ok, _token} = OAuth.store_tokens(user_id, provider, token_data)
    assert {:ok, _account} = ConnectedAccounts.upsert_from_oauth(user_id, provider, token_data)
    assert {:ok, _account} = ConnectedAccounts.mark_error(user_id, provider, "reauth required")

    scope = SourceScope.resolve(user_id)
    assert provider in SourceScope.google_account_providers(scope, "gmail")

    assert {:ok, _account} = ConnectedAccounts.mark_disconnected(user_id, provider)

    disconnected_scope = SourceScope.resolve(user_id)
    refute provider in SourceScope.google_account_providers(disconnected_scope, "gmail")
  end
end
