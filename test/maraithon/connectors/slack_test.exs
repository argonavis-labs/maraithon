defmodule Maraithon.Connectors.SlackTest do
  use Maraithon.DataCase, async: false

  import Plug.Test

  alias Maraithon.Accounts
  alias Maraithon.Connectors.Slack
  alias Maraithon.Crm.Observation
  alias Maraithon.OAuth
  alias Maraithon.Repo

  describe "handle_webhook/2" do
    test "handles url_verification challenge" do
      params = %{
        "type" => "url_verification",
        "challenge" => "test_challenge_string"
      }

      conn = conn(:post, "/webhooks/slack", params)

      assert {:challenge, "test_challenge_string"} = Slack.handle_webhook(conn, params)
    end

    test "parses message event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event_id" => "Ev12345",
        "authorizations" => [%{"user_id" => "U_SELF", "is_bot" => false}],
        "event" => %{
          "type" => "message",
          "channel" => "C12345",
          "user" => "U12345",
          "text" => "Hello world",
          "ts" => "1234567890.123456"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "message"
      assert event.source == "slack"
      assert event.data.team_id == "T12345"
      assert event.data.self_user_id == "U_SELF"
      assert event.data.text == "Hello world"
      assert event.id == "Ev12345"
      assert event.dedupe_key == "slack-event:Ev12345"
    end

    test "routes dm messages to dm topic" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "channel" => "D99999",
          "user" => "U12345",
          "text" => "DM hello",
          "ts" => "1234567890.123456"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:dm:U12345"
      assert event.type == "message"
    end

    test "parses app_mention event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "app_mention",
          "channel" => "C12345",
          "user" => "U12345",
          "text" => "<@U_BOT> help me",
          "ts" => "1234567890.123456"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "app_mention"
    end

    test "parses reaction_added event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event_id" => "Ev-reaction-added",
        "event" => %{
          "type" => "reaction_added",
          "user" => "U12345",
          "reaction" => "thumbsup",
          "event_ts" => "1234567891.123456",
          "item" => %{
            "type" => "message",
            "channel" => "C12345",
            "ts" => "1234567890.123456"
          }
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "reaction_added"
    end

    test "parses bot messages so connected workspaces retain full coverage" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "channel" => "C12345",
          "bot_id" => "B12345",
          "text" => "Bot message",
          "ts" => "1234567890.123456"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      assert {:ok, "slack:T12345:C12345", event} = Slack.handle_webhook(conn, params)
      assert event.type == "message"
      assert event.data.user_id == "B12345"
      assert event.data.text == "Bot message"
    end

    test "handles generic event type with string channel" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "file_shared",
          "channel" => "C99999",
          "file_id" => "F12345"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C99999"
      assert event.type == "file_shared"
    end

    test "handles event without channel" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "team_join",
          "user" => %{"id" => "U99999", "name" => "newuser"}
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345"
      assert event.type == "team_join"
    end

    test "returns ignore for unknown payload type" do
      params = %{"type" => nil}
      conn = conn(:post, "/webhooks/slack", params)

      assert {:ignore, "unknown type: "} = Slack.handle_webhook(conn, params)
    end

    test "returns ignore for missing type" do
      params = %{"invalid" => "payload"}
      conn = conn(:post, "/webhooks/slack", params)

      assert {:ignore, "unknown type: "} = Slack.handle_webhook(conn, params)
    end

    test "parses member_joined event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "member_joined_channel",
          "channel" => "C12345",
          "user" => "U99999"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "member_joined"
    end

    test "handles channel in item object" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "reaction_added",
          "item" => %{
            "channel" => "C77777"
          },
          "reaction" => "thumbsup"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, _event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C77777"
    end

    test "handles message subtype" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "subtype" => "channel_join",
          "channel" => "C12345",
          "user" => "U12345",
          "text" => "<@U12345> has joined the channel",
          "ts" => "1234567890.123456"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, _topic, event} = Slack.handle_webhook(conn, params)

      # Message with subtype becomes message_subtype
      assert event.type == "message_channel_join"
    end

    test "parses message_changed event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event_id" => "Ev-message-changed",
        "event" => %{
          "type" => "message",
          "subtype" => "message_changed",
          "channel" => "C12345",
          "event_ts" => "1234567891.123456",
          "message" => %{
            "user" => "U12345",
            "text" => "Edited message",
            "ts" => "1234567890.123456"
          }
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, _topic, event} = Slack.handle_webhook(conn, params)

      assert event.type == "message_changed"
    end

    test "parses message_deleted event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event_id" => "Ev-message-deleted",
        "event" => %{
          "type" => "message",
          "subtype" => "message_deleted",
          "channel" => "C12345",
          "event_ts" => "1234567892.123456",
          "deleted_ts" => "1234567890.123456",
          "previous_message" => %{"user" => "U12345", "ts" => "1234567890.123456"}
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, _topic, event} = Slack.handle_webhook(conn, params)

      assert event.type == "message_deleted"
    end

    test "parses message with files" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "channel" => "C12345",
          "user" => "U12345",
          "text" => "Here's a file",
          "ts" => "1234567890.123456",
          "files" => [
            %{
              "id" => "F12345",
              "name" => "test.txt",
              "mimetype" => "text/plain",
              "url_private" => "https://files.slack.com/...",
              "size" => 1234
            }
          ]
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, _topic, event} = Slack.handle_webhook(conn, params)

      assert event.type == "message"
      assert length(event.data.files) == 1
    end

    test "parses member_left_channel event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "member_left_channel",
          "channel" => "C12345",
          "user" => "U99999"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "member_left"
    end

    test "parses reaction_removed event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event_id" => "Ev-reaction-removed",
        "event" => %{
          "type" => "reaction_removed",
          "user" => "U12345",
          "reaction" => "thumbsup",
          "event_ts" => "1234567891.123457",
          "item" => %{
            "type" => "message",
            "channel" => "C12345",
            "ts" => "1234567890.123456"
          }
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "reaction_removed"
    end

    test "fails closed when a message mutation lacks its event timestamp" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event_id" => "Ev-malformed-edit",
        "event" => %{
          "type" => "message",
          "subtype" => "message_changed",
          "channel" => "C12345",
          "message" => %{
            "user" => "U12345",
            "text" => "Edited without an event timestamp",
            "ts" => "1234567890.123456"
          }
        }
      }

      assert {:error,
              {:slack_message_persistence_failed, :invalid_slack_mutation_event_timestamp}} =
               Slack.handle_webhook(conn(:post, "/webhooks/slack", params), params)
    end

    test "parses bot_message subtype as a durable message event" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "subtype" => "bot_message",
          "channel" => "C12345",
          "bot_id" => "B12345",
          "text" => "Bot message",
          "ts" => "1234567890.123456"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      assert {:ok, "slack:T12345:C12345", event} = Slack.handle_webhook(conn, params)
      assert event.type == "message_bot_message"
      assert event.data.text == "Bot message"
    end

    test "handles generic event type" do
      params = %{
        "type" => "event_callback",
        "team_id" => "T12345",
        "event" => %{
          "type" => "channel_archive",
          "channel" => "C12345"
        }
      }

      conn = conn(:post, "/webhooks/slack", params)

      {:ok, topic, event} = Slack.handle_webhook(conn, params)

      assert topic == "slack:T12345:C12345"
      assert event.type == "channel_archive"
    end
  end

  describe "durable message fidelity" do
    test "persists a useful excerpt and compact metadata for a file-only message" do
      {user_id, team_id} = connect_slack_account("file-only")
      ts = "1787069900.000001"

      params = %{
        "type" => "event_callback",
        "team_id" => team_id,
        "authorizations" => [%{"user_id" => "U-SELF", "is_bot" => false}],
        "event" => %{
          "type" => "message",
          "subtype" => "file_share",
          "channel" => "D-FILES",
          "user" => "U-SENDER",
          "text" => "",
          "ts" => ts,
          "files" => [
            %{
              "id" => "F-PLAN",
              "name" => "launch-plan.pdf",
              "title" => "Launch plan",
              "mimetype" => "application/pdf",
              "size" => 42_000,
              "preview_plain_text" => "Final launch checklist and named owners"
            }
          ]
        }
      }

      assert {:ok, _topic, _event} = Slack.handle_webhook(conn(:post, "/"), params)

      assert %Observation{excerpt: excerpt, metadata: metadata} =
               Repo.get_by(Observation,
                 user_id: user_id,
                 source: "slack",
                 source_item_id: "#{team_id}:D-FILES:#{ts}"
               )

      assert excerpt =~ "Launch plan"
      assert excerpt =~ "Final launch checklist"
      assert metadata["file_count"] == 1

      assert [file] = metadata["files"]
      assert file["id"] == "F-PLAN"
      assert file["name"] == "launch-plan.pdf"
      assert file["preview"] == "Final launch checklist and named owners"
    end

    test "persists blocks-only text instead of counting an empty Slack item" do
      {user_id, team_id} = connect_slack_account("blocks-only")
      ts = "1787069901.000002"

      params = %{
        "type" => "event_callback",
        "team_id" => team_id,
        "authorizations" => [%{"user_id" => "U-SELF", "is_bot" => false}],
        "event" => %{
          "type" => "message",
          "channel" => "C-BLOCKS",
          "user" => "U-SENDER",
          "text" => "",
          "ts" => ts,
          "blocks" => [
            %{
              "type" => "section",
              "block_id" => "approval",
              "text" => %{
                "type" => "mrkdwn",
                "text" => "*Approve the launch plan* by Friday"
              }
            }
          ]
        }
      }

      assert {:ok, _topic, _event} = Slack.handle_webhook(conn(:post, "/"), params)

      assert %Observation{excerpt: excerpt, metadata: metadata} =
               Repo.get_by(Observation,
                 user_id: user_id,
                 source: "slack",
                 source_item_id: "#{team_id}:C-BLOCKS:#{ts}"
               )

      assert excerpt == "*Approve the launch plan* by Friday"
      assert metadata["block_count"] == 1

      assert [%{"type" => "section", "block_id" => "approval", "text" => block_text}] =
               metadata["blocks"]

      assert block_text == "*Approve the launch plan* by Friday"
    end

    test "preserves semantic text beyond compact metadata limits" do
      {user_id, team_id} = connect_slack_account("lossless-semantic-text")
      ts = "1787069901.000003"
      tail = "ACTION REQUIRED: approve the final launch"
      long_preview = String.duplicate("context ", 180) <> tail

      files =
        Enum.map(1..20, fn index ->
          %{"id" => "F-#{index}", "title" => "Reference #{index}"}
        end) ++
          [%{"id" => "F-21", "title" => "Final approval", "preview_plain_text" => long_preview}]

      params = %{
        "type" => "event_callback",
        "team_id" => team_id,
        "authorizations" => [%{"user_id" => "U-SELF", "is_bot" => false}],
        "event" => %{
          "type" => "message",
          "subtype" => "file_share",
          "channel" => "C-LOSSLESS",
          "user" => "U-SENDER",
          "text" => "",
          "ts" => ts,
          "files" => files
        }
      }

      assert {:ok, _topic, _event} = Slack.handle_webhook(conn(:post, "/"), params)

      assert %Observation{metadata: metadata} =
               Repo.get_by(Observation,
                 user_id: user_id,
                 source: "slack",
                 source_item_id: "#{team_id}:C-LOSSLESS:#{ts}"
               )

      assert metadata["file_count"] == 21
      assert length(metadata["files"]) == 20
      assert metadata["text"] =~ "Final approval"
      assert String.ends_with?(metadata["text"], tail)
    end

    test "fails closed when a nominally content-bearing block has no durable content" do
      {_user_id, team_id} = connect_slack_account("empty-block")

      params = %{
        "type" => "event_callback",
        "team_id" => team_id,
        "event" => %{
          "type" => "message",
          "channel" => "C-EMPTY",
          "user" => "U-SENDER",
          "text" => "",
          "ts" => "1787069902.000003",
          "blocks" => [%{"type" => "divider"}]
        }
      }

      assert {:error, {:slack_message_persistence_failed, :missing_slack_message_durable_content}} =
               Slack.handle_webhook(conn(:post, "/"), params)
    end
  end

  describe "verify_signature/2" do
    test "returns error for missing headers when secret configured" do
      Application.put_env(:maraithon, :slack, signing_secret: "test_secret")
      on_exit(fn -> Application.delete_env(:maraithon, :slack) end)

      conn = conn(:post, "/webhooks/slack", %{})

      assert {:error, :missing_headers} = Slack.verify_signature(conn, "{}")
    end

    test "verifies valid signature" do
      signing_secret = "test_signing_secret"
      Application.put_env(:maraithon, :slack, signing_secret: signing_secret)
      on_exit(fn -> Application.delete_env(:maraithon, :slack) end)

      raw_body = ~s({"type":"event_callback"})
      timestamp = "#{System.system_time(:second)}"
      basestring = "v0:#{timestamp}:#{raw_body}"

      signature =
        :crypto.mac(:hmac, :sha256, signing_secret, basestring) |> Base.encode16(case: :lower)

      signature_header = "v0=#{signature}"

      conn =
        conn(:post, "/webhooks/slack", %{})
        |> Plug.Conn.put_req_header("x-slack-signature", signature_header)
        |> Plug.Conn.put_req_header("x-slack-request-timestamp", timestamp)

      assert :ok = Slack.verify_signature(conn, raw_body)
    end

    test "returns error for invalid signature" do
      Application.put_env(:maraithon, :slack, signing_secret: "test_secret")
      on_exit(fn -> Application.delete_env(:maraithon, :slack) end)

      timestamp = "#{System.system_time(:second)}"

      conn =
        conn(:post, "/webhooks/slack", %{})
        |> Plug.Conn.put_req_header("x-slack-signature", "v0=invalid")
        |> Plug.Conn.put_req_header("x-slack-request-timestamp", timestamp)

      assert {:error, :invalid_signature} = Slack.verify_signature(conn, "{}")
    end
  end

  defp connect_slack_account(suffix) do
    unique = System.unique_integer([:positive])
    user_id = "slack-fidelity-#{suffix}-#{unique}@example.com"
    team_id = "T-FIDELITY-#{unique}"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "slack:#{team_id}", %{
        access_token: "slack-token",
        metadata: %{"team_id" => team_id, "authed_user_id" => "U-SELF"}
      })

    {user_id, team_id}
  end
end
