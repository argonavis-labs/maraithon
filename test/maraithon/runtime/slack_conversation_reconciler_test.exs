defmodule Maraithon.Runtime.SlackConversationReconcilerTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Connectors.SourceCursor
  alias Maraithon.Crm.Observation
  alias Maraithon.OAuth
  alias Maraithon.Repo
  alias Maraithon.Runtime.SlackConversationReconciler
  alias Maraithon.Runtime.{BackgroundJob, SourceWatermarkCommit}

  setup do
    original_slack_config = Application.get_env(:maraithon, :slack, [])

    on_exit(fn -> Application.put_env(:maraithon, :slack, original_slack_config) end)

    :ok
  end

  test "plans readable conversation fan-outs and seals history plus replies before its cursor" do
    now = ~U[2026-08-31 12:00:00Z]
    user_id = "slack-reconciler@example.com"
    team_id = "T-RECONCILE"
    bypass = Bypass.open()

    _user = Accounts.get_or_create_user_by_email(user_id)

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "slack:#{team_id}", %{
               access_token: "xoxb-bot-token",
               scopes: ["channels:read", "channels:history"],
               metadata: %{"team_id" => team_id}
             })

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "slack:#{team_id}:user:U-SELF", %{
               access_token: "xoxp-user-token",
               scopes: [
                 "channels:read",
                 "channels:history",
                 "im:read",
                 "im:history"
               ]
             })

    account = Maraithon.ConnectedAccounts.get(user_id, "slack:#{team_id}")
    root_ts = slack_ts(DateTime.add(now, -30, :second))
    reply_ts = slack_ts(DateTime.add(now, -10, :second))

    Bypass.stub(bypass, "GET", "/api/conversations.list", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "channels" => [
            %{"id" => "C-READABLE", "name" => "team", "is_member" => true},
            %{"id" => "D-READABLE", "is_im" => true, "user" => "U-DM"},
            %{"id" => "C-OUTSIDE", "name" => "outside", "is_member" => false}
          ]
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/api/conversations.history", fn conn ->
      params = Plug.Conn.Query.decode(conn.query_string)
      assert params["channel"] == "C-READABLE"
      assert params["inclusive"] == "true"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "messages" => [
            %{
              "ts" => root_ts,
              "user" => "U-ROOT",
              "text" => "Provider root",
              "reply_count" => 1
            }
          ],
          "has_more" => false
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/api/conversations.replies", fn conn ->
      params = Plug.Conn.Query.decode(conn.query_string)
      assert params["channel"] == "C-READABLE"
      assert params["ts"] == root_ts

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "messages" => [
            %{"ts" => root_ts, "user" => "U-ROOT", "text" => "Provider root"},
            %{
              "ts" => reply_ts,
              "thread_ts" => root_ts,
              "user" => "U-REPLY",
              "text" => "Provider reply"
            }
          ],
          "has_more" => false
        })
      )
    end)

    assert {:ok, %{readable_conversations: 2, due: [default_due]}} =
             SlackConversationReconciler.plan(account)

    assert default_due.conversation_kind == "public_channel"

    assert {:ok, %{readable_conversations: 2, due: due}} =
             SlackConversationReconciler.plan(account, batch_size: 2)

    assert Enum.map(due, & &1.conversation_kind) == ["public_channel", "dm"]
    assert Enum.all?(due, &is_binary(&1.dedupe_key))

    assert {:ok,
            %{
              outcome: "reconciled",
              source_items: 2,
              root_messages: 1,
              thread_replies: 1,
              model_calls: 0,
              upper_cursor: upper_cursor,
              deferred_watermarks: [_watermark]
            }} =
             result =
             SlackConversationReconciler.run_conversation(
               account,
               "C-READABLE",
               "public_channel",
               now: now
             )

    assert upper_cursor == Integer.to_string(DateTime.to_unix(now, :second))

    refute Repo.exists?(
             from(cursor in SourceCursor,
               where: cursor.connected_account_id == ^account.id,
               where: like(cursor.kind, "slack_conversation:%")
             )
           )

    job = %BackgroundJob{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      job_type: "runtime_partition:slack_conversation_reconcile"
    }

    assert {:ok, {:ok, %{advanced_watermarks: 1}}} =
             Repo.transaction(fn ->
               SourceWatermarkCommit.commit_and_sanitize(job, result)
             end)
             |> then(fn {:ok, committed} -> committed end)

    assert 2 ==
             Repo.aggregate(
               from(observation in Observation,
                 where:
                   observation.user_id == ^user_id and observation.source == "slack" and
                     observation.source_account == ^team_id
               ),
               :count
             )

    assert %SourceCursor{value: ^upper_cursor} =
             Repo.one!(
               from(cursor in SourceCursor,
                 where: cursor.connected_account_id == ^account.id,
                 where: like(cursor.kind, "slack_conversation:%")
               )
             )
  end

  defp slack_ts(datetime) do
    seconds = DateTime.to_unix(datetime, :second)
    "#{seconds}.000000"
  end
end
