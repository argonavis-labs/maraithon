defmodule Maraithon.Connectors.IngestionIdentityTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query
  import Plug.Conn, only: [put_req_header: 3]

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Connectors.{Gmail, GoogleCalendar, Slack, SourceCursors}
  alias Maraithon.Crm.Observation
  alias Maraithon.OAuth
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs

  test "production validator emits aggregate-only data for the authorized account" do
    {:ok, _user} = Accounts.get_or_create_user_by_email("kent@runner.now")

    assert {:ok, report} = Maraithon.Todos.ProductionValidator.run("kent@runner.now")
    assert report.authorized_user
    assert report.todos.total == 0
    assert report.connected_account_families == %{google: 0, other: 0, slack: 0}
    refute inspect(report) =~ "kent@runner.now"

    assert {:error, :unauthorized_validation_target} =
             Maraithon.Todos.ProductionValidator.run("someone-else@example.com")
  end

  test "Gmail webhook preserves the modern Google account provider" do
    user_id = unique_email("gmail")
    mailbox = unique_email("mailbox")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:#{mailbox}", %{
        access_token: "google-token",
        metadata: %{"account_email" => mailbox}
      })

    params = %{
      "message" => %{
        "data" => Base.encode64(Jason.encode!(%{"emailAddress" => mailbox, "historyId" => "42"})),
        "messageId" => "gmail-message-#{System.unique_integer([:positive])}"
      }
    }

    assert {:ok, _topic, _event} = Gmail.handle_webhook(nil, params)

    job = find_job(user_id, "gmail_incremental_sync")
    assert job.payload["provider"] == "google:#{mailbox}"
  end

  test "Calendar webhook preserves the provider that owns its watch channel" do
    user_id = unique_email("calendar")
    mailbox = unique_email("calendar-mailbox")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:#{mailbox}", %{
        access_token: "google-token",
        metadata: %{"account_email" => mailbox}
      })

    account = Maraithon.ConnectedAccounts.get(user_id, "google:#{mailbox}")
    channel_id = "channel-#{System.unique_integer([:positive])}"

    assert {:ok, _cursor} =
             SourceCursors.put(account, "calendar_sync_token", %{
               "watch_channel_id" => channel_id,
               "watch_resource_id" => "resource-1",
               "watch_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second)
             })

    conn =
      Plug.Test.conn(:post, "/webhooks/google/calendar")
      |> put_req_header("x-goog-channel-id", channel_id)
      |> put_req_header("x-goog-resource-id", "resource-1")
      |> put_req_header("x-goog-resource-state", "exists")
      |> put_req_header("x-goog-channel-token", user_id)
      |> put_req_header("x-goog-message-number", "1")

    assert {:ok, _topic, _event} = GoogleCalendar.handle_webhook(conn, %{})

    job = find_job(user_id, "calendar_incremental_sync")
    assert job.payload["provider"] == "google:#{mailbox}"
  end

  test "Slack webhook resolves a multi-workspace provider and schedules a bounded flush" do
    user_id = unique_email("slack")
    team_id = "T#{System.unique_integer([:positive])}"
    sender_id = "U#{System.unique_integer([:positive])}"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "slack:#{team_id}", %{
        access_token: "slack-token",
        metadata: %{"team_id" => team_id, "authed_user_id" => sender_id}
      })

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{},
        status: "running"
      })

    full_text = String.duplicate("context ", 1_100) <> "ACTION REQUIRED after character 8000"

    params = %{
      "type" => "event_callback",
      "team_id" => team_id,
      "authorizations" => [%{"user_id" => sender_id, "is_bot" => false}],
      "event" => %{
        "type" => "message",
        "channel" => "C123",
        "user" => sender_id,
        "text" => full_text,
        "ts" => "1787069800.000001"
      }
    }

    assert {:ok, _topic, _event} = Slack.handle_webhook(Plug.Test.conn(:post, "/"), params)

    assert %Observation{direction: "outbound", excerpt: excerpt, metadata: metadata} =
             Repo.get_by(Observation, user_id: user_id, source: "slack")

    assert String.length(excerpt) <= 8_000
    assert String.length(excerpt) >= 7_900
    assert metadata["text"] == full_text
    assert String.ends_with?(metadata["text"], "ACTION REQUIRED after character 8000")

    changed_params = %{
      "type" => "event_callback",
      "team_id" => team_id,
      "event_id" => "Ev-edited-#{System.unique_integer([:positive])}",
      "authorizations" => [%{"user_id" => sender_id, "is_bot" => false}],
      "event" => %{
        "type" => "message",
        "subtype" => "message_changed",
        "channel" => "C123",
        "event_ts" => "1787069801.000002",
        "message" => %{
          "user" => sender_id,
          "text" => "Edited to add an actionable request",
          "ts" => "1787069800.000001"
        }
      }
    }

    assert {:ok, _topic, _event} =
             Slack.handle_webhook(Plug.Test.conn(:post, "/"), changed_params)

    reaction_params = %{
      "type" => "event_callback",
      "team_id" => team_id,
      "event_id" => "Ev-reaction-#{System.unique_integer([:positive])}",
      "authorizations" => [%{"user_id" => sender_id, "is_bot" => false}],
      "event" => %{
        "type" => "reaction_added",
        "user" => sender_id,
        "reaction" => "white_check_mark",
        "event_ts" => "1787069802.000003",
        "item" => %{"type" => "message", "channel" => "C123", "ts" => "1787069800.000001"}
      }
    }

    assert {:ok, _topic, _event} =
             Slack.handle_webhook(Plug.Test.conn(:post, "/"), reaction_params)

    observations =
      Repo.all(
        from(observation in Observation,
          where: observation.user_id == ^user_id and observation.source == "slack"
        )
      )

    assert Enum.any?(observations, fn observation ->
             observation.metadata["event_type"] == "message_changed" and
               observation.metadata["target_ts"] == "1787069800.000001" and
               observation.metadata["text"] == "Edited to add an actionable request"
           end)

    assert Enum.any?(observations, fn observation ->
             observation.metadata["event_type"] == "reaction_added" and
               observation.metadata["target_ts"] == "1787069800.000001" and
               observation.metadata["text"] =~ "white_check_mark"
           end)

    discovery_job = find_job(user_id, "runtime_partition:source_account_discovery")
    assert discovery_job.payload["agent_id"] == agent.id
    assert discovery_job.payload["role"] == "discovery"

    assert {:ok, 1} =
             Maraithon.Crm.Ingest.sweep_windows_older_than(
               DateTime.add(DateTime.utc_now(), 121, :second),
               120
             )
  end

  test "Slack webhook persists a private event only for its authorized account" do
    team_id = "T#{System.unique_integer([:positive])}"
    sender_id = "U#{System.unique_integer([:positive])}"
    authorized_user_id = unique_email("slack-authorized")
    {:ok, _user} = Accounts.get_or_create_user_by_email(authorized_user_id)

    {:ok, _token} =
      OAuth.store_tokens(authorized_user_id, "slack:#{team_id}", %{
        access_token: "slack-token",
        metadata: %{"team_id" => team_id, "authed_user_id" => "U-AUTHORIZED"}
      })

    params = %{
      "type" => "event_callback",
      "team_id" => team_id,
      "event_context" => "EC-PRIVATE-AUTHORIZED",
      "authorizations" => [%{"user_id" => "U-AUTHORIZED", "is_bot" => false}],
      "event" => %{
        "type" => "message",
        "channel" => "D123",
        "user" => sender_id,
        "text" => "A fresh reply on an old thread",
        "ts" => "1787069801.000002",
        "thread_ts" => "1700000000.000001"
      }
    }

    assert {:ok, topic, _event} = Slack.handle_webhook(Plug.Test.conn(:post, "/"), params)
    assert topic == "slack:#{team_id}:dm:#{sender_id}"

    assert %Observation{metadata: metadata, excerpt: "A fresh reply on an old thread"} =
             Repo.get_by(Observation,
               user_id: authorized_user_id,
               source: "slack",
               source_item_id: "#{team_id}:D123:1787069801.000002"
             )

    assert metadata["thread_ts"] == "1700000000.000001"
    assert find_job(authorized_user_id, "runtime_partition:source_account_discovery")
  end

  test "Slack webhook fails closed when a workspace has multiple installations" do
    team_id = "T#{System.unique_integer([:positive])}"
    first_user_id = unique_email("slack-full-auth-first")
    second_user_id = unique_email("slack-full-auth-second")

    Enum.each(
      [{first_user_id, "U-FIRST"}, {second_user_id, "U-SECOND"}],
      fn {user_id, slack_user_id} ->
        {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

        {:ok, _token} =
          OAuth.store_tokens(user_id, "slack:#{team_id}", %{
            access_token: "slack-token",
            metadata: %{"team_id" => team_id, "authed_user_id" => slack_user_id}
          })
      end
    )

    params = %{
      "type" => "event_callback",
      "team_id" => team_id,
      "event_context" => "EC-FULL-AUTHORIZATION-FANOUT",
      "authorizations" => [%{"user_id" => "U-FIRST", "is_bot" => false}],
      "event" => %{
        "type" => "message",
        "channel" => "C-SHARED",
        "user" => "U-SENDER",
        "text" => "Visible to both connected installations",
        "ts" => "1787069802.000004"
      }
    }

    assert {:error,
            {:slack_message_persistence_failed, :slack_event_authorization_expansion_required}} =
             Slack.handle_webhook(Plug.Test.conn(:post, "/"), params)

    for user_id <- [first_user_id, second_user_id] do
      refute Repo.get_by(Observation,
               user_id: user_id,
               source: "slack",
               source_item_id: "#{team_id}:C-SHARED:1787069802.000004"
             )
    end
  end

  test "Slack webhook rejects an explicit authorization mismatch for one installation" do
    team_id = "T#{System.unique_integer([:positive])}"
    user_id = unique_email("slack-authorization-mismatch")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "slack:#{team_id}", %{
        access_token: "slack-token",
        metadata: %{"team_id" => team_id, "authed_user_id" => "U-CONNECTED"}
      })

    params = %{
      "type" => "event_callback",
      "team_id" => team_id,
      "authorizations" => [%{"user_id" => "U-DIFFERENT", "is_bot" => false}],
      "event" => %{
        "type" => "message",
        "channel" => "D-MISMATCH",
        "user" => "U-SENDER",
        "text" => "Private mismatch",
        "ts" => "1787069803.000005"
      }
    }

    assert {:error,
            {:slack_message_persistence_failed, :slack_event_account_authorization_mismatch}} =
             Slack.handle_webhook(Plug.Test.conn(:post, "/"), params)

    refute Repo.get_by(Observation,
             user_id: user_id,
             source: "slack",
             source_item_id: "#{team_id}:D-MISMATCH:1787069803.000005"
           )
  end

  defp find_job(user_id, job_type) do
    user_id
    |> then(&BackgroundJobs.list(user_id: &1, limit: 50))
    |> Enum.find(&(&1.job_type == job_type))
    |> tap(&assert &1)
  end

  defp unique_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.com"
  end
end
