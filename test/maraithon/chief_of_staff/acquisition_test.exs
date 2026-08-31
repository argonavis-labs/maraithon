defmodule Maraithon.ChiefOfStaff.AcquisitionTest do
  use Maraithon.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maraithon.Accounts
  alias Maraithon.ChiefOfStaff.{Acquisition, SourceBundle, SourceScope}
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Crm.Observation
  alias Maraithon.LogBuffer
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Repo
  alias Maraithon.TestSupport.{NewsStub, TravelCalendarStub, TravelGmailStub}

  setup do
    original_config = Application.get_env(:maraithon, Acquisition, [])
    original_gmail_stub = Application.get_env(:maraithon, TravelGmailStub, [])
    original_calendar_stub = Application.get_env(:maraithon, TravelCalendarStub, [])
    original_slack_config = Application.get_env(:maraithon, :slack, [])

    Application.put_env(
      :maraithon,
      Acquisition,
      Keyword.merge(original_config,
        gmail_module: TravelGmailStub,
        calendar_module: TravelCalendarStub,
        news_module: NewsStub
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, Acquisition, original_config)
      Application.put_env(:maraithon, TravelGmailStub, original_gmail_stub)
      Application.put_env(:maraithon, TravelCalendarStub, original_calendar_stub)
      Application.put_env(:maraithon, :slack, original_slack_config)
    end)

    :ok
  end

  test "execution context can target exactly one live Gmail account" do
    user_id = "chief-account-scope@example.com"
    now = ~U[2026-08-30 03:12:00Z]
    _user = Accounts.get_or_create_user_by_email(user_id)

    selected_provider = "google:selected@example.com"
    ignored_provider = "google:ignored@example.com"

    for {provider, account_email} <- [
          {selected_provider, "selected@example.com"},
          {ignored_provider, "ignored@example.com"}
        ] do
      assert {:ok, _token} =
               OAuth.store_tokens(user_id, provider, %{
                 access_token: "token-#{account_email}",
                 scopes: Google.scopes_for(["gmail"]),
                 metadata: %{"account_email" => account_email}
               })
    end

    TravelGmailStub.configure(
      messages_by_provider: %{
        selected_provider => [
          %{
            message_id: "selected-message",
            thread_id: "selected-thread",
            subject: "Selected account message",
            labels: ["INBOX"],
            internal_date: DateTime.add(now, -60, :second),
            text_body: "Please send the selected account update."
          }
        ],
        ignored_provider => [
          %{
            message_id: "ignored-message",
            thread_id: "ignored-thread",
            subject: "Ignored account message",
            labels: ["INBOX"],
            internal_date: DateTime.add(now, -60, :second),
            text_body: "Please send the ignored account update."
          }
        ]
      }
    )

    all_accounts_scope = %{
      "google_accounts" => [
        %{
          "provider" => selected_provider,
          "account_email" => "selected@example.com",
          "services" => ["gmail"]
        },
        %{
          "provider" => ignored_provider,
          "account_email" => "ignored@example.com",
          "services" => ["gmail"]
        }
      ]
    }

    context = %{
      agent_id: "chief-agent-account-scope",
      user_id: user_id,
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil,
      source_scope: %{
        "google_accounts" => [
          %{
            "provider" => selected_provider,
            "services" => ["gmail"]
          }
        ]
      }
    }

    {bundle, _telemetry, _watermarks} =
      Acquisition.build(
        user_id,
        ["followthrough"],
        %{"followthrough" => %{"source_scope" => all_accounts_scope}},
        context
      )

    assert SourceScope.google_account_providers(SourceBundle.source_scope(bundle), "gmail") == [
             selected_provider
           ]

    message_ids = SourceBundle.gmail_messages(bundle) |> Enum.map(& &1["message_id"])
    assert "selected-message" in message_ids
    refute "ignored-message" in message_ids
  end

  test "expands Slack parent threads for thread broadcasts in the source bundle" do
    now = ~U[2026-06-18 15:00:00Z]
    bypass = Bypass.open()

    _user = Accounts.get_or_create_user_by_email("chief-slack-thread@example.com")

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    assert {:ok, _token} =
             OAuth.store_tokens("chief-slack-thread@example.com", "slack:T123:user:UKENT", %{
               access_token: "xoxp-user-token",
               scopes: ["channels:read", "channels:history", "groups:history"]
             })

    Bypass.expect(bypass, "GET", "/api/conversations.list", fn conn ->
      assert ["Bearer xoxp-user-token"] == Plug.Conn.get_req_header(conn, "authorization")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "channels" => [
            %{"id" => "C111", "name" => "exec-hr", "is_private" => true, "is_member" => true}
          ]
        })
      )
    end)

    Bypass.expect(bypass, "GET", "/api/conversations.history", fn conn ->
      assert ["Bearer xoxp-user-token"] == Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string =~ "channel=C111"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "messages" => [
            %{
              "ts" => "1781125242.926539",
              "thread_ts" => "1780502644.660749",
              "subtype" => "thread_broadcast",
              "user" => "UJEFF",
              "text" => "Do we have benefits? I'm about to get a bill for braces today."
            }
          ]
        })
      )
    end)

    Bypass.expect(bypass, "GET", "/api/conversations.replies", fn conn ->
      assert ["Bearer xoxp-user-token"] == Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string =~ "channel=C111"
      assert conn.query_string =~ "ts=1780502644.660749"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "messages" => [
            %{
              "ts" => "1780502644.660749",
              "thread_ts" => "1780502644.660749",
              "user" => "ULAURA",
              "text" => "Taking a look."
            },
            %{
              "ts" => "1781125242.926539",
              "thread_ts" => "1780502644.660749",
              "subtype" => "thread_broadcast",
              "user" => "UJEFF",
              "text" => "Do we have benefits? I'm about to get a bill for braces today."
            },
            %{
              "ts" => "1781551858.300399",
              "thread_ts" => "1780502644.660749",
              "user" => "ULAURA",
              "text" => "Canada is unaffected; this is only impacting the US."
            },
            %{
              "ts" => "1781722316.603969",
              "thread_ts" => "1780502644.660749",
              "user" => "UKENT",
              "text" => "Looks resolved, thank you."
            }
          ]
        })
      )
    end)

    Bypass.expect(bypass, "GET", "/api/search.messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"ok" => true, "messages" => %{"total" => 0, "matches" => []}})
      )
    end)

    Bypass.expect(bypass, "GET", "/api/users.info", fn conn ->
      user =
        conn.query_string
        |> Plug.Conn.Query.decode()
        |> Map.get("user")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "user" => %{"id" => user, "profile" => %{"display_name" => user}}
        })
      )
    end)

    source_scope = %{
      "slack_workspaces" => [
        %{"team_id" => "T123", "team_name" => "Agora", "services" => ["channels"]}
      ]
    }

    skill_configs = %{
      "followthrough" => %{
        "source_scope" => source_scope,
        "lookback_hours" => 24,
        "slack_message_scan_limit" => 10
      }
    }

    context = %{
      agent_id: "chief-agent-slack-thread",
      user_id: "chief-slack-thread@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build(
        "chief-slack-thread@example.com",
        ["followthrough"],
        skill_configs,
        context
      )

    messages = SourceBundle.slack_messages(bundle)
    texts = Enum.map(messages, & &1["text"])

    assert "Canada is unaffected; this is only impacting the US." in texts
    assert "Looks resolved, thank you." in texts
    assert Enum.any?(messages, &(&1["ts"] == "1781125242.926539"))
    assert Enum.any?(messages, &(&1["thread_ts"] == "1780502644.660749"))

    slack_fetches = Enum.filter(telemetry["fetches"], &(&1["source"] == "slack"))
    assert Enum.any?(slack_fetches, &(&1["mode"] == "thread_replies" and &1["count"] == 4))
    assert get_in(telemetry, ["sources", "slack", "message_count"]) == 4
  end

  test "exact Slack acquisition skips channel history and retains durable event threads" do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(10, :second)
    user_id = "chief-slack-access-boundary@example.com"
    team_id = "T-ACCESS-BOUNDARY"
    bypass = Bypass.open()
    test_pid = self()

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
                 "groups:read",
                 "groups:history",
                 "im:read",
                 "im:history",
                 "mpim:read",
                 "mpim:history",
                 "search:read"
               ]
             })

    event_ts = slack_test_ts(now)
    thread_ts = slack_test_ts(DateTime.add(now, -120, :second))

    assert {:ok, _observation} =
             Observation.new(%{
               user_id: user_id,
               source: "slack",
               source_account: team_id,
               source_item_id: "#{team_id}:C-OUTSIDE:#{event_ts}",
               occurred_at: now,
               direction: "inbound",
               participants: [
                 %{"role" => "from", "identifier" => %{"slack_id" => "U-SENDER"}}
               ],
               excerpt: "A fresh reply from an inaccessible historical thread",
               metadata: %{
                 "team_id" => team_id,
                 "channel" => "C-OUTSIDE",
                 "ts" => event_ts,
                 "thread_ts" => thread_ts
               }
             })
             |> Repo.insert()

    readable_event_at = DateTime.add(now, -10, :second)
    readable_event_ts = slack_test_ts(readable_event_at)
    readable_thread_ts = slack_test_ts(DateTime.add(now, -180, :second))

    assert {:ok, _observation} =
             Observation.new(%{
               user_id: user_id,
               source: "slack",
               source_account: team_id,
               source_item_id: "#{team_id}:C-READABLE:#{readable_event_ts}",
               occurred_at: readable_event_at,
               direction: "inbound",
               participants: [
                 %{"role" => "from", "identifier" => %{"slack_id" => "U-SENDER"}}
               ],
               excerpt: "The current readable thread reply",
               metadata: %{
                 "team_id" => team_id,
                 "channel" => "C-READABLE",
                 "ts" => readable_event_ts,
                 "thread_ts" => readable_thread_ts,
                 "text" => "The current readable thread reply"
               }
             })
             |> Repo.insert()

    deferred_at = %{DateTime.add(now, 1, :second) | microsecond: {0, 6}}
    deferred_ts = slack_test_ts(deferred_at)

    assert {:ok, _observation} =
             Observation.new(%{
               user_id: user_id,
               source: "slack",
               source_account: team_id,
               source_item_id: "#{team_id}:C-READABLE:#{deferred_ts}",
               occurred_at: deferred_at,
               direction: "inbound",
               participants: [
                 %{"role" => "from", "identifier" => %{"slack_id" => "U-SENDER"}}
               ],
               excerpt: "A concurrently arriving event for the next sealed delta",
               metadata: %{
                 "team_id" => team_id,
                 "channel" => "C-READABLE",
                 "ts" => deferred_ts
               }
             })
             |> Ecto.Changeset.put_change(:inserted_at, deferred_at)
             |> Ecto.Changeset.put_change(:updated_at, deferred_at)
             |> Repo.insert()

    Bypass.stub(bypass, "GET", "/api/conversations.list", fn conn ->
      send(test_pid, :slack_conversations_listed)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "channels" => [
            %{"id" => "C-READABLE", "name" => "team", "is_member" => true},
            %{"id" => "C-OUTSIDE", "name" => "outside", "is_member" => false},
            %{"id" => "D-READABLE", "is_im" => true, "user" => "U-DM"},
            %{"id" => "G-READABLE", "is_mpim" => true, "name" => "mpdm"}
          ]
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/api/conversations.history", fn conn ->
      channel_id = conn.query_string |> Plug.Conn.Query.decode() |> Map.fetch!("channel")
      send(test_pid, {:slack_history_channel, channel_id})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "messages" => []}))
    end)

    Bypass.stub(bypass, "GET", "/api/conversations.replies", fn conn ->
      send(test_pid, {:slack_thread_fetch, conn.query_string})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "messages" => [
            %{"ts" => readable_thread_ts, "user" => "U-ROOT", "text" => "Thread root"},
            %{
              "ts" => slack_test_ts(DateTime.add(now, -20, :second)),
              "thread_ts" => readable_thread_ts,
              "user" => "U-PRIOR",
              "text" => "Prior reply"
            },
            %{
              "ts" => readable_event_ts,
              "thread_ts" => readable_thread_ts,
              "user" => "U-SENDER",
              "text" => "The current readable thread reply"
            },
            %{
              "ts" => slack_test_ts(DateTime.add(now, 30, :second)),
              "thread_ts" => readable_thread_ts,
              "user" => "U-FUTURE",
              "text" => "Future reply must not leak backward"
            }
          ]
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/api/search.messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"ok" => true, "messages" => %{"total" => 0, "matches" => []}})
      )
    end)

    Bypass.stub(bypass, "GET", "/api/users.info", fn conn ->
      user_id = conn.query_string |> Plug.Conn.Query.decode() |> Map.fetch!("user")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"ok" => true, "user" => %{"id" => user_id, "profile" => %{}}})
      )
    end)

    {bundle, telemetry, proposed_watermarks} =
      Acquisition.build(
        user_id,
        ["followthrough"],
        slack_exact_skill_configs(team_id),
        slack_exact_build_context(user_id, team_id, now)
      )

    assert Acquisition.source_complete?(telemetry, "slack")

    assert_received :slack_conversations_listed
    refute_received {:slack_history_channel, _channel_id}
    assert_received {:slack_thread_fetch, _query}

    assert [%{kind: "slack_discovery_watermark", value: frontier}] = proposed_watermarks
    assert frontier == now |> DateTime.to_unix() |> to_string()

    refute Enum.any?(
             SourceBundle.slack_messages(bundle),
             &(&1["text"] == "A fresh reply from an inaccessible historical thread")
           )

    refute Enum.any?(
             SourceBundle.slack_messages(bundle),
             &(&1["text"] == "A concurrently arriving event for the next sealed delta")
           )

    readable_message =
      Enum.find(
        SourceBundle.slack_messages(bundle),
        &(&1["text"] == "The current readable thread reply")
      )

    assert readable_message["thread_context_complete"]
    assert readable_message["thread_context_frontier"] == readable_event_ts

    assert Enum.map(readable_message["thread_context"], & &1["text"]) == [
             "Thread root",
             "Prior reply"
           ]

    assert [workspace] = SourceBundle.slack_workspaces(bundle)
    assert get_in(workspace, ["metadata", "conversation_count"]) == 3
    refute Enum.any?(workspace["channels"], &(&1["id"] == "C-OUTSIDE"))

    assert Enum.any?(telemetry["fetches"], fn fetch ->
             fetch["mode"] == "durable_event_authorization" and
               fetch["status"] == "terminal" and fetch["reason"] == "access_boundary" and
               fetch["channel_id"] == "C-OUTSIDE" and fetch["count"] == 1
           end)

    assert Enum.any?(telemetry["fetches"], fn fetch ->
             fetch["mode"] == "durable_event_delta" and fetch["status"] == "ok" and
               fetch["history_request_count"] == 0
           end)

    account = ConnectedAccounts.get(user_id, "slack:#{team_id}")

    assert {:ok, _cursor} =
             SourceCursors.put(account, "slack_discovery_watermark", %{value: frontier})

    next_now = DateTime.add(now, 2, :second)

    {next_bundle, next_telemetry, next_watermarks} =
      Acquisition.build(
        user_id,
        ["followthrough"],
        slack_exact_skill_configs(team_id),
        slack_exact_build_context(user_id, team_id, next_now)
      )

    assert Acquisition.source_complete?(next_telemetry, "slack")

    assert MapSet.new(Enum.map(SourceBundle.slack_messages(next_bundle), & &1["text"])) ==
             MapSet.new([
               "The current readable thread reply",
               "A concurrently arriving event for the next sealed delta"
             ])

    assert [%{kind: "slack_discovery_watermark", value: next_frontier}] = next_watermarks
    assert next_frontier == next_now |> DateTime.to_unix() |> to_string()
  end

  test "exact Slack acquisition paginates provider search to repair missed events" do
    now = ~U[2026-08-31 12:00:00Z]
    user_id = "chief-slack-search-repair@example.com"
    team_id = "T-SEARCH-REPAIR"
    bypass = Bypass.open()
    test_pid = self()

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
                 "im:history",
                 "search:read"
               ]
             })

    root_ts = slack_test_ts(DateTime.add(now, -120, :second))
    channel_ts = slack_test_ts(DateTime.add(now, -30, :second))
    dm_ts = slack_test_ts(DateTime.add(now, -20, :second))
    reply_ts = slack_test_ts(DateTime.add(now, -10, :second))
    future_ts = slack_test_ts(DateTime.add(now, 1, :second))

    Bypass.stub(bypass, "GET", "/api/conversations.list", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "channels" => [
            %{"id" => "C-READABLE", "name" => "team", "is_member" => true},
            %{"id" => "D-READABLE", "is_im" => true, "user" => "U-DM"}
          ]
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/api/conversations.history", fn conn ->
      send(test_pid, :unexpected_slack_history_fetch)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(500, Jason.encode!(%{"ok" => false, "error" => "unexpected"}))
    end)

    Bypass.stub(bypass, "GET", "/api/search.messages", fn conn ->
      params = Plug.Conn.Query.decode(conn.query_string)
      send(test_pid, {:slack_provider_search_page, params})

      matches =
        case params["page"] do
          "1" ->
            [
              %{
                "channel" => %{"id" => "C-READABLE", "name" => "team"},
                "ts" => channel_ts,
                "user" => "U-CHANNEL",
                "text" => "Provider channel message"
              },
              %{
                "channel" => %{"id" => "D-READABLE", "name" => "U-DM"},
                "type" => "im",
                "ts" => dm_ts,
                "user" => "U-DM",
                "text" => "Provider direct message"
              }
            ]

          "2" ->
            [
              %{
                "channel" => %{"id" => "C-READABLE", "name" => "team"},
                "ts" => reply_ts,
                "thread_ts" => root_ts,
                "user" => "U-REPLY",
                "text" => "Provider thread reply"
              },
              %{
                "channel" => %{"id" => "C-READABLE", "name" => "team"},
                "ts" => future_ts,
                "user" => "U-FUTURE",
                "text" => "Future provider message"
              }
            ]
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "messages" => %{
            "total" => 4,
            "matches" => matches,
            "pagination" => %{"page_count" => 2}
          }
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
            %{"ts" => root_ts, "user" => "U-ROOT", "text" => "Historical thread root"},
            %{
              "ts" => reply_ts,
              "thread_ts" => root_ts,
              "user" => "U-REPLY",
              "text" => "Provider thread reply"
            }
          ]
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/api/users.info", fn conn ->
      user = conn.query_string |> Plug.Conn.Query.decode() |> Map.fetch!("user")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"ok" => true, "user" => %{"id" => user, "profile" => %{}}})
      )
    end)

    {bundle, telemetry, proposed_watermarks} =
      Acquisition.build(
        user_id,
        ["followthrough"],
        slack_exact_skill_configs(team_id),
        slack_exact_build_context(user_id, team_id, now)
      )

    assert Acquisition.source_complete?(telemetry, "slack")
    refute_received :unexpected_slack_history_fetch

    assert_received {:slack_provider_search_page, first_page}
    assert first_page["page"] == "1"
    assert first_page["count"] == "100"
    assert first_page["query"] == "after:2026-08-28 before:2026-09-01"

    assert_received {:slack_provider_search_page, second_page}
    assert second_page["page"] == "2"

    messages = SourceBundle.slack_messages(bundle)

    assert MapSet.new(Enum.map(messages, & &1["text"])) ==
             MapSet.new([
               "Provider channel message",
               "Provider direct message",
               "Provider thread reply"
             ])

    reply = Enum.find(messages, &(&1["text"] == "Provider thread reply"))
    assert reply["thread_context_complete"]
    assert Enum.map(reply["thread_context"], & &1["text"]) == ["Historical thread root"]

    assert Enum.any?(telemetry["fetches"], fn fetch ->
             fetch["mode"] == "provider_search_delta" and fetch["status"] == "ok" and
               fetch["count"] == 3 and fetch["provider_match_count"] == 4 and
               fetch["page_count"] == 2
           end)

    assert [%{kind: "slack_discovery_watermark", value: frontier}] = proposed_watermarks
    assert frontier == now |> DateTime.to_unix() |> to_string()
  end

  test "exact Slack acquisition advances its delta when optional thread context is unavailable" do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(10, :second)
    user_id = "chief-slack-scope-failure@example.com"
    team_id = "T-SCOPE-FAILURE"
    bypass = Bypass.open()

    _user = Accounts.get_or_create_user_by_email(user_id)

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "slack:#{team_id}", %{
               access_token: "xoxb-bot-token",
               scopes: ["channels:read", "channels:history"],
               metadata: %{"team_id" => team_id}
             })

    event_ts = slack_test_ts(DateTime.add(now, -10, :second))
    thread_ts = slack_test_ts(DateTime.add(now, -120, :second))

    assert {:ok, _observation} =
             Observation.new(%{
               user_id: user_id,
               source: "slack",
               source_account: team_id,
               source_item_id: "#{team_id}:C-READABLE:#{event_ts}",
               occurred_at: DateTime.add(now, -10, :second),
               direction: "inbound",
               participants: [
                 %{"role" => "from", "identifier" => %{"slack_id" => "U-SENDER"}}
               ],
               excerpt: "A fresh reply whose thread must be hydrated",
               metadata: %{
                 "team_id" => team_id,
                 "channel" => "C-READABLE",
                 "ts" => event_ts,
                 "thread_ts" => thread_ts
               }
             })
             |> Repo.insert()

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "slack:#{team_id}:user:U-SELF", %{
               access_token: "xoxp-user-token",
               scopes: ["channels:read", "channels:history", "search:read"]
             })

    Bypass.stub(bypass, "GET", "/api/conversations.list", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "channels" => [%{"id" => "C-READABLE", "name" => "team", "is_member" => true}]
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/api/conversations.history", fn conn ->
      send(self(), :unexpected_slack_history_fetch)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(500, Jason.encode!(%{"ok" => false, "error" => "unexpected"}))
    end)

    Bypass.stub(bypass, "GET", "/api/conversations.replies", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => false, "error" => "missing_scope"}))
    end)

    Bypass.stub(bypass, "GET", "/api/search.messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"ok" => true, "messages" => %{"total" => 0, "matches" => []}})
      )
    end)

    {bundle, telemetry, proposed_watermarks} =
      Acquisition.build(
        user_id,
        ["followthrough"],
        slack_exact_skill_configs(team_id),
        slack_exact_build_context(user_id, team_id, now)
      )

    assert Acquisition.source_complete?(telemetry, "slack")
    assert get_in(telemetry, ["sources", "slack", "status"]) == "ready"
    assert [%{kind: "slack_discovery_watermark", value: frontier}] = proposed_watermarks
    assert frontier == now |> DateTime.to_unix() |> to_string()

    assert Enum.any?(SourceBundle.slack_messages(bundle), fn message ->
             message["text"] == "A fresh reply whose thread must be hydrated"
           end)

    assert Enum.any?(telemetry["fetches"], fn fetch ->
             fetch["mode"] == "event_thread_replies" and fetch["status"] == "error" and
               fetch["reason"] == "slack_error"
           end)

    :ok = Logger.flush()
    _ = :sys.get_state(LogBuffer)

    assert [] ==
             LogBuffer.recent_matching(5, fn entry ->
               entry.message == "ChiefOfStaff acquisition failed to fetch Slack" and
                 entry.metadata["failure_code"] == "slack_workspace_incomplete"
             end)
  end

  test "limits Slack history scans after priority sorting" do
    now = ~U[2026-06-18 15:00:00Z]
    bypass = Bypass.open()

    _user = Accounts.get_or_create_user_by_email("chief-slack-limit@example.com")

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    assert {:ok, _token} =
             OAuth.store_tokens("chief-slack-limit@example.com", "slack:T123:user:UKENT", %{
               access_token: "xoxp-user-token",
               scopes: ["channels:read", "channels:history", "groups:history"]
             })

    Bypass.expect(bypass, "GET", "/api/conversations.list", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "channels" => [
            %{
              "id" => "CLOW",
              "name" => "random",
              "is_private" => false,
              "is_member" => true
            },
            %{
              "id" => "CEXEC",
              "name" => "exec-real-estate",
              "is_private" => true,
              "is_member" => true
            },
            %{"id" => "CDM", "name" => nil, "is_im" => true, "user" => "UBENJI"}
          ]
        })
      )
    end)

    Bypass.expect(bypass, "GET", "/api/conversations.history", fn conn ->
      params = Plug.Conn.Query.decode(conn.query_string)
      assert params["channel"] == "CEXEC"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "messages" => [
            %{
              "ts" => "1781125242.926539",
              "user" => "UBENJI",
              "text" => "Real estate webinar Luma is live."
            }
          ]
        })
      )
    end)

    Bypass.expect(bypass, "GET", "/api/search.messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"ok" => true, "messages" => %{"total" => 0, "matches" => []}})
      )
    end)

    Bypass.expect(bypass, "GET", "/api/users.info", fn conn ->
      user =
        conn.query_string
        |> Plug.Conn.Query.decode()
        |> Map.get("user")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"ok" => true, "user" => %{"id" => user, "profile" => %{}}})
      )
    end)

    source_scope = %{
      "slack_workspaces" => [
        %{"team_id" => "T123", "team_name" => "Agora", "services" => ["channels"]}
      ]
    }

    skill_configs = %{
      "commitment_tracker" => %{
        "source_scope" => source_scope,
        "lookback_hours" => 24,
        "slack_channel_scan_limit" => 1,
        "slack_message_scan_limit" => 10
      }
    }

    context = %{
      agent_id: "chief-agent-slack-limit",
      user_id: "chief-slack-limit@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build(
        "chief-slack-limit@example.com",
        ["commitment_tracker"],
        skill_configs,
        context
      )

    messages = SourceBundle.slack_messages(bundle)
    assert Enum.map(messages, & &1["channel_id"]) == ["CEXEC"]
    assert get_in(telemetry, ["sources", "slack", "conversation_count"]) == 1
  end

  test "recovers exact Slack broadcast mentions outside the bounded channel scan" do
    now = ~U[2026-08-27 17:24:00Z]
    bypass = Bypass.open()

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    assert {:ok, _user} =
             Maraithon.Accounts.get_or_create_user_by_email("chief-slack-broadcast@example.com")

    assert {:ok, _token} =
             OAuth.store_tokens("chief-slack-broadcast@example.com", "slack:T123:user:UKENT", %{
               access_token: "xoxp-user-token",
               scopes: ["channels:read", "channels:history", "search:read", "users:read"]
             })

    Bypass.stub(bypass, "GET", "/api/conversations.list", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "channels" => [
            %{"id" => "CSELECTED", "name" => "exec-priority", "is_member" => true}
          ]
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/api/conversations.history", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "messages" => []}))
    end)

    Bypass.stub(bypass, "GET", "/api/search.messages", fn conn ->
      query = conn.query_string |> Plug.Conn.Query.decode() |> Map.get("query")

      matches =
        if String.starts_with?(query, "@here after:") do
          [
            %{
              "ts" => "1787792700.000001",
              "user" => "UKEVIN",
              "text" =>
                "<!here> Please dm me with the following information depending on the OS you have\n" <>
                  "macOS screenshots: FileVault turned on, lock screen, automatic security updates, " <>
                  "device model and serial, macOS version, and password-length attestation.",
              "channel" => %{"id" => "C-SOC2", "name" => "p-certificates-soc2"},
              "permalink" => "https://example.slack.com/archives/C-SOC2/p1787792700000001"
            }
          ]
        else
          []
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "messages" => %{"total" => length(matches), "matches" => matches}
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/api/users.info", fn conn ->
      user = conn.query_string |> Plug.Conn.Query.decode() |> Map.get("user")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "user" => %{
            "id" => user,
            "profile" => %{"display_name" => if(user == "UKEVIN", do: "Kevin", else: user)}
          }
        })
      )
    end)

    source_scope = %{
      "slack_workspaces" => [
        %{"team_id" => "T123", "team_name" => "Agora", "services" => ["channels"]}
      ]
    }

    context = %{
      agent_id: "chief-agent-slack-broadcast",
      user_id: "chief-slack-broadcast@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build(
        "chief-slack-broadcast@example.com",
        ["followthrough"],
        %{
          "followthrough" => %{
            "source_scope" => source_scope,
            "lookback_hours" => 48,
            "slack_channel_scan_limit" => 1,
            "slack_message_scan_limit" => 100
          }
        },
        context
      )

    [mention] = SourceBundle.slack_mentions(bundle)
    assert mention["channel_id"] == "C-SOC2"
    assert mention["text"] =~ "<!here> Please dm me"
    assert mention["search_mode"] == "broadcast_mention"

    assert Enum.any?(
             telemetry["fetches"],
             &(&1["mode"] == "broadcast_mention_search" and &1["mention"] == "@here" and
                 &1["count"] == 1)
           )
  end

  test "adds self-authored Slack search matches when private channel history is not enumerable" do
    now = ~U[2026-06-18 21:24:00Z]
    bypass = Bypass.open()

    _user = Accounts.get_or_create_user_by_email("chief-slack-search@example.com")

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    assert {:ok, _token} =
             OAuth.store_tokens("chief-slack-search@example.com", "slack:T123:user:UKENT", %{
               access_token: "xoxp-user-token",
               scopes: [
                 "channels:read",
                 "channels:history",
                 "groups:read",
                 "groups:history",
                 "search:read"
               ]
             })

    Bypass.expect(bypass, "GET", "/api/conversations.list", fn conn ->
      assert ["Bearer xoxp-user-token"] == Plug.Conn.get_req_header(conn, "authorization")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "channels" => [
            %{
              "id" => "C111",
              "name" => "runner-general",
              "is_private" => false,
              "is_member" => true
            }
          ]
        })
      )
    end)

    Bypass.expect(bypass, "GET", "/api/conversations.history", fn conn ->
      assert ["Bearer xoxp-user-token"] == Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string =~ "channel=C111"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "messages" => []}))
    end)

    Bypass.expect(bypass, "GET", "/api/search.messages", fn conn ->
      assert ["Bearer xoxp-user-token"] == Plug.Conn.get_req_header(conn, "authorization")

      query =
        conn.query_string
        |> Plug.Conn.Query.decode()
        |> Map.get("query")

      matches =
        if query == "\"I am going to\"" do
          [
            %{
              "ts" => "1781817087.758159",
              "thread_ts" => "1781817044.000000",
              "user" => "UKENT",
              "text" => "I am going to message Sheila tomorrow",
              "channel" => %{"id" => "CPRIVATE", "name" => "runner-gtm"},
              "permalink" => "https://example.slack.com/archives/CPRIVATE/p1781817087758159"
            }
          ]
        else
          []
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "messages" => %{"total" => length(matches), "matches" => matches}
        })
      )
    end)

    Bypass.expect(bypass, "GET", "/api/users.info", fn conn ->
      user =
        conn.query_string
        |> Plug.Conn.Query.decode()
        |> Map.get("user")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "user" => %{"id" => user, "profile" => %{"display_name" => "Kent"}}
        })
      )
    end)

    source_scope = %{
      "slack_workspaces" => [
        %{"team_id" => "T123", "team_name" => "Agora", "services" => ["channels", "dms"]}
      ]
    }

    skill_configs = %{
      "commitment_tracker" => %{
        "source_scope" => source_scope,
        "lookback_hours" => 336,
        "slack_message_scan_limit" => 100
      }
    }

    context = %{
      agent_id: "chief-agent-slack-search",
      user_id: "chief-slack-search@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build(
        "chief-slack-search@example.com",
        ["commitment_tracker"],
        skill_configs,
        context
      )

    messages = SourceBundle.slack_messages(bundle)

    assert %{
             "channel_name" => "runner-gtm",
             "search_mode" => "self_authored",
             "text" => "I am going to message Sheila tomorrow",
             "user" => "UKENT"
           } = Enum.find(messages, &(&1["text"] == "I am going to message Sheila tomorrow"))

    slack_fetches = Enum.filter(telemetry["fetches"], &(&1["source"] == "slack"))

    assert Enum.any?(
             slack_fetches,
             &(&1["mode"] == "self_authored_search" and &1["query"] == "\"I am going to\"" and
                 &1["count"] == 1)
           )

    assert get_in(telemetry, ["sources", "slack", "message_count"]) == 1
  end

  test "deeply searches every Gmail account after a metadata-only sync event" do
    now = ~U[2026-08-27 20:00:00Z]
    providers = ["google:alpha@example.com", "google:beta@example.com"]

    base_messages =
      Map.new(providers, fn provider ->
        prefix = if provider =~ "alpha", do: "alpha", else: "beta"

        {provider,
         [
           %{
             message_id: "#{prefix}-newest",
             thread_id: "#{prefix}-newest-thread",
             subject: "Newest but not actionable",
             labels: ["INBOX"],
             internal_date: now
           }
         ]}
      end)

    targeted_messages =
      Map.new(providers, fn provider ->
        prefix = if provider =~ "alpha", do: "alpha", else: "beta"

        {provider,
         [
           %{
             message_id: "#{prefix}-buried-ask",
             thread_id: "#{prefix}-buried-thread",
             subject: "Security evidence",
             snippet: "Could you please send the requested screenshots?",
             labels: ["INBOX"],
             internal_date: DateTime.add(now, -6, :hour)
           }
         ]}
      end)

    contents =
      targeted_messages
      |> Map.values()
      |> List.flatten()
      |> Map.new(fn message ->
        {message.message_id,
         Map.put(message, :text_body, "Could you please send the requested screenshots?")}
      end)

    TravelGmailStub.configure(
      messages_by_provider: base_messages,
      messages_by_query_match: [{"please send", targeted_messages}],
      contents: contents
    )

    source_scope = %{
      "google_accounts" =>
        Enum.map(providers, fn provider ->
          %{
            "provider" => provider,
            "account_email" => String.replace_prefix(provider, "google:", ""),
            "services" => ["gmail"]
          }
        end)
    }

    context = %{
      agent_id: "chief-agent-deep-gmail",
      user_id: "chief@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :pubsub_event, topic: "email:alpha@example.com"},
      event: %{
        topic: "email:alpha@example.com",
        payload: %{
          "source" => "gmail",
          "data" => %{"provider" => "google:alpha@example.com", "count" => 1}
        }
      }
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build(
        "chief@example.com",
        ["followthrough"],
        %{
          "followthrough" => %{
            "source_scope" => source_scope,
            "email_scan_limit" => 10,
            "lookback_hours" => 48
          }
        },
        context
      )

    buried =
      bundle
      |> SourceBundle.gmail_messages()
      |> Enum.filter(&String.ends_with?(&1["message_id"], "-buried-ask"))

    assert Enum.sort(Enum.map(buried, & &1["google_provider"])) == Enum.sort(providers)
    assert Enum.all?(buried, &(&1["search_mode"] == "targeted_actionable"))
    assert Enum.all?(buried, &(&1["body_available"] == true))

    assert Enum.all?(buried, fn message ->
             Enum.any?(
               SourceBundle.gmail_inbox_messages(bundle),
               &(&1["message_id"] == message["message_id"])
             )
           end)

    gmail_fetches = Enum.filter(telemetry["fetches"], &(&1["source"] == "gmail"))

    assert Enum.all?(providers, fn provider ->
             Enum.any?(
               gmail_fetches,
               &(&1["provider"] == provider and &1["targeted_search_count"] >= 1)
             )
           end)

    assert get_in(telemetry, ["sources", "gmail", "commercial_provider_count"]) == 2
  end

  test "builds one shared gmail and calendar bundle for overlapping skills" do
    now = ~U[2026-04-02 13:00:00Z]

    TravelGmailStub.configure(
      messages: [
        %{
          message_id: "msg-1",
          thread_id: "thread-1",
          subject: "Customer ask",
          labels: ["INBOX"],
          internal_date: now
        },
        %{
          message_id: "msg-2",
          thread_id: "thread-2",
          subject: "Sent update",
          labels: ["SENT"],
          internal_date: DateTime.add(now, -1, :hour)
        }
      ],
      contents: %{
        "msg-1" => %{
          message_id: "msg-1",
          thread_id: "thread-1",
          subject: "Customer ask",
          labels: ["INBOX"],
          internal_date: now,
          text_body: "Customer needs a decision from Kent before Friday."
        },
        "msg-2" => %{
          message_id: "msg-2",
          thread_id: "thread-2",
          subject: "Sent update",
          labels: ["SENT"],
          internal_date: DateTime.add(now, -1, :hour),
          text_body: "Kent sent the promised update."
        }
      }
    )

    TravelCalendarStub.configure(
      events: [
        %{
          event_id: "evt-1",
          summary: "Project sync",
          start: DateTime.add(now, 4, :hour),
          end: DateTime.add(now, 5, :hour)
        }
      ]
    )

    source_scope = %{
      "google_accounts" => [
        %{
          "provider" => "google:shared@example.com",
          "account_email" => "shared@example.com",
          "services" => ["gmail", "calendar"]
        }
      ]
    }

    skill_configs = %{
      "followthrough" => %{
        "source_scope" => source_scope,
        "email_scan_limit" => 10,
        "event_scan_limit" => 12,
        "lookback_hours" => 48
      },
      "travel_logistics" => %{
        "source_scope" => source_scope,
        "email_scan_limit" => 25,
        "event_scan_limit" => 25,
        "lookback_hours" => 24 * 30
      }
    }

    context = %{
      agent_id: "chief-agent-1",
      user_id: "chief@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build(
        "chief@example.com",
        ["followthrough", "travel_logistics"],
        skill_configs,
        context
      )

    assert length(SourceBundle.gmail_messages(bundle)) == 2
    assert Enum.all?(SourceBundle.gmail_messages(bundle), &(&1["body_available"] == true))
    assert Enum.all?(SourceBundle.gmail_messages(bundle), &is_binary(&1["body_text"]))
    assert length(SourceBundle.gmail_inbox_messages(bundle)) == 1
    assert length(SourceBundle.gmail_sent_messages(bundle)) == 1
    assert length(SourceBundle.calendar_events(bundle)) == 1
    assert get_in(telemetry, ["sources", "gmail", "status"]) == "ready"
    assert get_in(telemetry, ["sources", "gmail", "candidate_limit"]) == 100
    assert get_in(telemetry, ["sources", "gmail", "per_provider_candidate_limit"]) == 100
    assert Keyword.get(TravelGmailStub.last_fetch_opts(), :message_format) == :metadata
    assert get_in(telemetry, ["sources", "gmail", "full_body_count"]) == 2
    assert get_in(telemetry, ["sources", "gmail", "body_missing_count"]) == 0
    assert get_in(telemetry, ["sources", "calendar", "status"]) == "ready"
  end

  test "shares one global body budget fairly across Gmail accounts" do
    now = ~U[2026-04-02 13:00:00Z]
    providers = ["google:alpha@example.com", "google:beta@example.com"]

    messages_by_provider =
      Map.new(providers, fn provider ->
        prefix = if provider =~ "alpha", do: "a", else: "b"

        messages =
          Enum.map(1..30, fn index ->
            %{
              message_id: "#{prefix}#{index}",
              thread_id: "#{prefix}f#{index}",
              subject: "#{provider} message #{index}",
              labels: ["INBOX"],
              internal_date: DateTime.add(now, -index, :minute)
            }
          end)

        {provider, messages}
      end)

    contents =
      messages_by_provider
      |> Map.values()
      |> List.flatten()
      |> Map.new(fn message ->
        {message.message_id,
         Map.put(message, :text_body, "Fetched body for #{message.message_id}")}
      end)

    TravelGmailStub.configure(
      messages_by_provider: messages_by_provider,
      contents: contents
    )

    source_scope = %{
      "google_accounts" =>
        Enum.map(providers, fn provider ->
          %{
            "provider" => provider,
            "account_email" => String.replace_prefix(provider, "google:", ""),
            "services" => ["gmail"]
          }
        end)
    }

    skill_configs = %{
      "followthrough" => %{
        "source_scope" => source_scope,
        "email_scan_limit" => 100,
        "lookback_hours" => 48
      }
    }

    context = %{
      agent_id: "chief-agent-fair-gmail",
      user_id: "chief@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build("chief@example.com", ["followthrough"], skill_configs, context)

    assert length(SourceBundle.gmail_messages(bundle)) == 60

    full_body_counts =
      bundle
      |> SourceBundle.gmail_messages()
      |> Enum.group_by(& &1["google_provider"])
      |> Map.new(fn {provider, messages} ->
        {provider, Enum.count(messages, &(&1["body_available"] == true))}
      end)

    assert full_body_counts == %{
             "google:alpha@example.com" => 20,
             "google:beta@example.com" => 20
           }

    assert get_in(telemetry, ["sources", "gmail", "candidate_limit"]) == 250

    assert get_in(telemetry, ["sources", "gmail", "provider_candidate_limits"]) == %{
             "google:alpha@example.com" => 125,
             "google:beta@example.com" => 125
           }

    assert get_in(telemetry, ["sources", "gmail", "full_body_count"]) == 40
    assert get_in(telemetry, ["sources", "gmail", "body_missing_count"]) == 20
  end

  test "keeps other source evidence when one provider times out" do
    now = ~U[2026-04-02 13:00:00Z]

    TravelGmailStub.configure(fetch_messages_hang: true)

    TravelCalendarStub.configure(
      events: [
        %{
          event_id: "evt-current",
          summary: "Current customer webinar",
          start: DateTime.add(now, 2, :hour),
          end: DateTime.add(now, 3, :hour)
        }
      ]
    )

    source_scope = %{
      "google_accounts" => [
        %{
          "provider" => "google:shared@example.com",
          "account_email" => "shared@example.com",
          "services" => ["gmail", "calendar"]
        }
      ]
    }

    skill_configs = %{
      "followthrough" => %{
        "source_scope" => source_scope,
        "email_scan_limit" => 10,
        "event_scan_limit" => 10,
        "gmail_fetch_timeout_ms" => 100,
        "calendar_fetch_timeout_ms" => 200,
        "companion_fetch_timeout_ms" => 5,
        "slack_fetch_timeout_ms" => 5
      }
    }

    context = %{
      agent_id: "chief-agent-source-timeout",
      user_id: "chief@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build("chief@example.com", ["followthrough"], skill_configs, context)

    [event] = SourceBundle.calendar_events(bundle)
    assert event["summary"] == "Current customer webinar"
    assert SourceBundle.gmail_messages(bundle) == []

    assert get_in(SourceBundle.freshness(bundle), ["gmail", "status"]) == "partial"
    assert get_in(telemetry, ["sources", "gmail", "status"]) == "partial"

    assert get_in(telemetry, ["sources", "gmail", "failed_providers"]) == [
             "google:shared@example.com"
           ]

    assert get_in(telemetry, ["sources", "calendar", "status"]) == "ready"
  end

  test "skips commercial Gmail work when every base provider fails" do
    now = ~U[2026-04-02 13:00:00Z]
    provider = "google:failed@example.com"

    TravelGmailStub.configure(fetch_errors_by_provider: %{provider => :reauth_required})

    source_scope = %{
      "google_accounts" => [
        %{
          "provider" => provider,
          "account_email" => "failed@example.com",
          "services" => ["gmail"]
        }
      ]
    }

    skill_configs = %{
      "followthrough" => %{
        "source_scope" => source_scope,
        "email_scan_limit" => 10,
        "commercial_gmail_queries" => ["invoice OR receipt"]
      }
    }

    context = %{
      agent_id: "chief-agent-gmail-all-failed",
      user_id: "chief@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build("chief@example.com", ["followthrough"], skill_configs, context)

    assert SourceBundle.gmail_messages(bundle) == []
    assert get_in(telemetry, ["sources", "gmail", "status"]) == "partial"
    assert get_in(telemetry, ["sources", "gmail", "failed_providers"]) == [provider]
  end

  test "marks Gmail bodies unavailable when body enrichment times out" do
    now = ~U[2026-04-02 13:00:00Z]

    current_config = Application.get_env(:maraithon, Acquisition, [])

    Application.put_env(
      :maraithon,
      Acquisition,
      Keyword.put(current_config, :gmail_body_fetch_timeout_ms, 5)
    )

    TravelGmailStub.configure(
      messages: [
        %{
          message_id: "slow-msg",
          thread_id: "thread-1",
          subject: "Slow body",
          labels: ["INBOX"],
          internal_date: now
        },
        %{
          message_id: "fast-msg",
          thread_id: "thread-2",
          subject: "Fast body",
          labels: ["INBOX"],
          internal_date: DateTime.add(now, -1, :minute)
        }
      ],
      content_hang_ids: ["slow-msg"],
      contents: %{
        "fast-msg" => %{
          message_id: "fast-msg",
          thread_id: "thread-2",
          subject: "Fast body",
          labels: ["INBOX"],
          internal_date: DateTime.add(now, -1, :minute),
          text_body: "This body was fetched."
        }
      }
    )

    source_scope = %{
      "google_accounts" => [
        %{
          "provider" => "google:shared@example.com",
          "account_email" => "shared@example.com",
          "services" => ["gmail"]
        }
      ]
    }

    skill_configs = %{
      "followthrough" => %{"source_scope" => source_scope, "email_scan_limit" => 10}
    }

    context = %{
      agent_id: "chief-agent-gmail-timeout",
      user_id: "chief@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build("chief@example.com", ["followthrough"], skill_configs, context)

    messages = SourceBundle.gmail_messages(bundle)
    slow = Enum.find(messages, &(&1["message_id"] == "slow-msg"))
    fast = Enum.find(messages, &(&1["message_id"] == "fast-msg"))

    assert slow["body_available"] == false
    assert slow["body_status"] == "fetch_failed"
    assert fast["body_available"] == true
    assert fast["body_text"] == "This body was fetched."
    assert get_in(telemetry, ["sources", "gmail", "full_body_count"]) == 1
    assert get_in(telemetry, ["sources", "gmail", "body_missing_count"]) == 1
  end

  test "existing Gmail bodies do not consume hydration slots" do
    now = ~U[2026-04-02 13:00:00Z]

    existing =
      Enum.map(1..5, fn index ->
        %{
          message_id: "existing-#{index}",
          thread_id: "existing-thread-#{index}",
          subject: "Existing body #{index}",
          labels: ["INBOX"],
          internal_date: DateTime.add(now, -index, :minute),
          text_body: "Already hydrated #{index}",
          body_status: "available_truncated"
        }
      end)

    missing =
      Enum.map(1..45, fn index ->
        %{
          message_id: "missing-#{index}",
          thread_id: "missing-thread-#{index}",
          subject: "Missing body #{index}",
          labels: ["INBOX"],
          internal_date: DateTime.add(now, -(index + 5), :minute)
        }
      end)

    contents =
      Map.new(missing, fn message ->
        {message.message_id, Map.put(message, :text_body, "Fetched #{message.message_id}")}
      end)

    TravelGmailStub.configure(messages: existing ++ missing, contents: contents)

    source_scope = %{
      "google_accounts" => [
        %{
          "provider" => "google:shared@example.com",
          "account_email" => "shared@example.com",
          "services" => ["gmail"]
        }
      ]
    }

    skill_configs = %{
      "followthrough" => %{"source_scope" => source_scope, "email_scan_limit" => 20}
    }

    context = %{
      agent_id: "chief-agent-gmail-existing-bodies",
      user_id: "chief@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build("chief@example.com", ["followthrough"], skill_configs, context)

    messages = SourceBundle.gmail_messages(bundle)
    assert Enum.count(messages, &(&1["body_available"] == true)) == 45
    assert Enum.count(messages, &(&1["body_available"] == false)) == 5

    assert messages
           |> Enum.filter(&String.starts_with?(&1["message_id"], "existing-"))
           |> Enum.all?(&(&1["body_status"] == "available_truncated"))

    assert get_in(telemetry, ["sources", "gmail", "full_body_count"]) == 45
    assert get_in(telemetry, ["sources", "gmail", "body_missing_count"]) == 5
  end

  test "enriches event Gmail payloads with full bodies before model synthesis" do
    now = ~U[2026-05-08 12:00:00Z]

    TravelGmailStub.configure(
      contents: %{
        "school-1" => %{
          message_id: "school-1",
          thread_id: "thread-school-1",
          subject: "4M Weekly Newsletter May 11-15",
          labels: ["INBOX", "UNREAD"],
          internal_date: now,
          from: "Marla Maharaj <teacher@example.com>",
          text_body: "This week's class note covers the field trip form and spelling words."
        }
      }
    )

    source_scope = %{
      "google_accounts" => [
        %{
          "provider" => "google:kent@example.com",
          "account_email" => "kent@example.com",
          "services" => ["gmail"]
        }
      ]
    }

    skill_configs = %{
      "followthrough" => %{"source_scope" => source_scope, "email_scan_limit" => 10}
    }

    context = %{
      agent_id: "chief-agent-event-gmail",
      user_id: "chief@example.com",
      timestamp: now,
      trigger: %{type: :event},
      event: %{
        topic: "email:kent@example.com",
        payload: %{
          "source" => "gmail",
          "data" => %{
            "messages" => [
              %{
                "message_id" => "school-1",
                "thread_id" => "thread-school-1",
                "subject" => "4M Weekly Newsletter May 11-15",
                "labels" => ["INBOX", "UNREAD"],
                "snippet" => "Weekly newsletter"
              }
            ]
          }
        }
      }
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build("chief@example.com", ["followthrough"], skill_configs, context)

    [message] = SourceBundle.gmail_messages(bundle)
    assert message["body_available"] == true
    assert message["body_status"] == "available"
    assert message["body_text"] =~ "field trip form"
    assert message["google_provider"] == "google:kent@example.com"
    assert get_in(telemetry, ["sources", "gmail", "full_body_count"]) == 1
  end

  test "adds configured news to the morning briefing source bundle" do
    now = ~U[2026-05-08 12:00:00Z]

    skill_configs = %{
      "morning_briefing" => %{
        "news_enabled" => true,
        "news_feeds" => [
          %{"name" => "Test News", "url" => "https://example.com/rss.xml"}
        ]
      }
    }

    context = %{
      agent_id: "chief-agent-news",
      user_id: "chief@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      # News is only fetched on an actual briefing cycle (the cron-scheduled
      # wakeup), not on every 10-minute scheduled scan.
      trigger: %{
        type: :wakeup,
        job_type: "wakeup",
        payload: %{"source" => "briefing_cron", "cadence" => "morning"}
      },
      event: nil
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build("chief@example.com", ["morning_briefing"], skill_configs, context)

    [item] = SourceBundle.news_items(bundle)
    assert item["title"] =~ "Slack launches"
    assert get_in(telemetry, ["sources", "news", "status"]) == "ready"
    assert get_in(telemetry, ["sources", "news", "item_count"]) == 1
  end

  describe "watermark advancement (SPEC 04 R4)" do
    setup do
      user_id = "chief-watermark@example.com"
      provider = "google:watermark@example.com"

      {:ok, _user} = Maraithon.Accounts.get_or_create_user_by_email(user_id)

      {:ok, account} =
        Maraithon.ConnectedAccounts.upsert_from_oauth(user_id, provider, %{
          access_token: "token",
          scopes: ["gmail"]
        })

      %{user_id: user_id, provider: provider, account: account}
    end

    defp mark_watermark_account_error(account) do
      metadata =
        (account.metadata || %{})
        |> Map.put("last_error", %{
          "reason" => "temporary_failure",
          "at" => "2026-05-31T12:00:00Z"
        })

      account
      |> Ecto.Changeset.change(%{
        status: "error",
        metadata: metadata,
        last_refreshed_at: ~U[2026-05-31 12:00:00.000000Z]
      })
      |> Maraithon.Repo.update!()
    end

    defp watermark_build_context(user_id, defer?) do
      base = %{
        agent_id: "chief-agent-watermark",
        user_id: user_id,
        timestamp: ~U[2026-06-01 12:00:00Z],
        budget: %{llm_calls: 10, tool_calls: 10},
        recent_events: [],
        trigger: %{type: :wakeup, job_type: "wakeup"},
        event: nil
      }

      if defer?, do: Map.put(base, :defer_watermark_advance, true), else: base
    end

    defp gmail_window_message(id, internal_date) do
      %{
        message_id: id,
        thread_id: "thread-#{id}",
        subject: "Window message #{id}",
        labels: ["INBOX"],
        internal_date: internal_date,
        from: "sender@example.com",
        text_body: "Message #{id}"
      }
    end

    test "uses and proposes the independent closure watermark", %{
      user_id: user_id,
      provider: provider,
      account: account
    } do
      closure_watermark = "1780311600"
      cycle_boundary = "1780315200"

      expected_query =
        "after:#{String.to_integer(closure_watermark) - 3_601} before:#{String.to_integer(cycle_boundary) + 1}"

      {:ok, _cursor} =
        Maraithon.Connectors.SourceCursors.put(account, "gmail_closure_watermark", %{
          "value" => closure_watermark
        })

      TravelGmailStub.configure(
        messages: [],
        messages_by_query_match: [
          {expected_query,
           [
             %{
               message_id: "closure-delta-message",
               thread_id: "closure-delta-thread",
               subject: "Closure delta",
               labels: ["INBOX"],
               internal_date: ~U[2026-06-01 11:30:00Z],
               text_body: "The closure delta was handled."
             }
           ]}
        ],
        contents: %{}
      )

      source_scope = %{
        "google_accounts" => [
          %{
            "provider" => provider,
            "account_email" => "watermark@example.com",
            "services" => ["gmail"]
          }
        ]
      }

      context =
        user_id
        |> watermark_build_context(true)
        |> Map.put(:source_watermark_role, "closure")

      {bundle, telemetry, proposed_watermarks} =
        Acquisition.build(
          user_id,
          ["followthrough"],
          %{"followthrough" => %{"source_scope" => source_scope}},
          context
        )

      assert Keyword.get(TravelGmailStub.last_fetch_opts(), :query) ==
               expected_query

      assert Enum.any?(
               SourceBundle.gmail_messages(bundle),
               &(&1["message_id"] == "closure-delta-message")
             )

      assert get_in(telemetry, ["sources", "gmail", "commercial_provider_count"]) == 0

      assert [%{kind: "gmail_closure_watermark", value: value}] = proposed_watermarks
      assert is_binary(value)
    end

    test "replays late-indexed Gmail messages and filters the exact local window", %{
      user_id: user_id,
      provider: provider,
      account: account
    } do
      previous_boundary = ~U[2026-06-01 11:00:00Z]
      current_boundary = ~U[2026-06-01 12:00:00Z]
      next_boundary = ~U[2026-06-01 12:01:00Z]
      previous_watermark = DateTime.to_unix(previous_boundary)
      current_watermark = DateTime.to_unix(current_boundary)

      assert {:ok, _token} =
               OAuth.store_tokens(user_id, provider, %{
                 access_token: "overlap-token",
                 scopes: Google.scopes_for(["gmail"]),
                 metadata: %{"account_email" => "watermark@example.com"}
               })

      source_scope = %{
        "google_accounts" => [
          %{
            "provider" => provider,
            "account_email" => "watermark@example.com",
            "services" => ["gmail"]
          }
        ]
      }

      skill_configs = %{"followthrough" => %{"source_scope" => source_scope}}

      exact_context = fn timestamp ->
        user_id
        |> watermark_build_context(true)
        |> Map.merge(%{
          timestamp: timestamp,
          source_scope: source_scope,
          source_watermark_role: "closure",
          exhaustive_account_delta: true,
          account_delta_source: "gmail"
        })
      end

      TravelGmailStub.configure(messages: [], contents: %{})

      {_first_bundle, first_telemetry, first_watermarks} =
        Acquisition.build(
          user_id,
          ["followthrough"],
          skill_configs,
          exact_context.(previous_boundary)
        )

      assert Acquisition.source_complete?(first_telemetry, "gmail")

      assert [%{kind: "gmail_closure_watermark", value: first_value}] = first_watermarks
      assert first_value == Integer.to_string(previous_watermark)

      assert {:ok, _cursor} =
               SourceCursors.put(account, "gmail_closure_watermark", %{"value" => first_value})

      exact_lower = DateTime.add(previous_boundary, -1, :hour)

      messages = [
        gmail_window_message("exact-lower", exact_lower),
        gmail_window_message("late-prior-window", DateTime.add(previous_boundary, -5, :minute)),
        gmail_window_message("inside-upper", DateTime.add(current_boundary, -1, :second)),
        gmail_window_message("before-lower", DateTime.add(exact_lower, -1, :second)),
        gmail_window_message("exact-upper", current_boundary)
      ]

      TravelGmailStub.configure(messages: messages, contents: %{})

      {second_bundle, second_telemetry, second_watermarks} =
        Acquisition.build(
          user_id,
          ["followthrough"],
          skill_configs,
          exact_context.(current_boundary)
        )

      assert Acquisition.source_complete?(second_telemetry, "gmail")

      assert Keyword.get(TravelGmailStub.last_fetch_opts(), :query) ==
               "after:#{DateTime.to_unix(exact_lower) - 1} before:#{current_watermark + 1}"

      assert second_bundle
             |> SourceBundle.gmail_messages()
             |> Enum.map(& &1["message_id"])
             |> Enum.sort() == ["exact-lower", "inside-upper", "late-prior-window"]

      assert [%{kind: "gmail_closure_watermark", value: second_value}] = second_watermarks
      assert second_value == Integer.to_string(current_watermark)

      assert {:ok, _cursor} =
               SourceCursors.put(account, "gmail_closure_watermark", %{"value" => second_value})

      TravelGmailStub.configure(
        messages: [gmail_window_message("exact-upper", current_boundary)],
        contents: %{}
      )

      {third_bundle, third_telemetry, _third_watermarks} =
        Acquisition.build(
          user_id,
          ["followthrough"],
          skill_configs,
          exact_context.(next_boundary)
        )

      assert Acquisition.source_complete?(third_telemetry, "gmail")

      assert Enum.map(SourceBundle.gmail_messages(third_bundle), & &1["message_id"]) == [
               "exact-upper"
             ]
    end

    test "exact discovery hydrates complete Gmail threads without promoting historical messages",
         %{
           user_id: user_id,
           provider: provider
         } do
      assert {:ok, _token} =
               OAuth.store_tokens(user_id, provider, %{
                 access_token: "exact-discovery-token",
                 scopes: Google.scopes_for(["gmail"]),
                 metadata: %{"account_email" => "watermark@example.com"}
               })

      root_at = ~U[2026-06-01 10:00:00Z]
      inbox_at = ~U[2026-06-01 11:00:00Z]
      sent_at = ~U[2026-06-01 11:30:00Z]
      future_at = ~U[2026-06-01 12:30:00Z]

      root = %{
        message_id: "thread-root",
        thread_id: "shared-thread",
        subject: "Original request",
        labels: ["INBOX"],
        internal_date: root_at,
        from: "sender@example.com",
        text_body: "Could you send the signed plan?"
      }

      inbox_reply = %{
        message_id: "delta-inbox",
        thread_id: "shared-thread",
        subject: "Re: Original request",
        labels: ["INBOX"],
        internal_date: inbox_at,
        from: "sender@example.com",
        text_body: "A reminder about the signed plan."
      }

      sent_reply = %{
        message_id: "delta-sent",
        thread_id: "shared-thread",
        subject: "Re: Original request",
        labels: ["SENT"],
        internal_date: sent_at,
        from: "watermark@example.com",
        text_body: "I will send it today."
      }

      future_reply = %{
        message_id: "future-message",
        thread_id: "shared-thread",
        subject: "Re: Original request",
        labels: ["INBOX"],
        internal_date: future_at,
        from: "sender@example.com",
        text_body: "This arrived after the acquisition frontier."
      }

      TravelGmailStub.configure(
        messages_by_provider: %{provider => [inbox_reply, sent_reply]},
        threads_by_provider: %{
          provider => %{
            "shared-thread" => [root, inbox_reply, sent_reply, future_reply]
          }
        }
      )

      source_scope = %{
        "google_accounts" => [
          %{
            "provider" => provider,
            "account_email" => "watermark@example.com",
            "services" => ["gmail"]
          }
        ]
      }

      context =
        user_id
        |> watermark_build_context(true)
        |> Map.merge(%{
          source_scope: source_scope,
          source_watermark_role: "discovery",
          exhaustive_account_delta: true,
          account_delta_source: "gmail"
        })

      {bundle, telemetry, proposed_watermarks} =
        Acquisition.build(
          user_id,
          ["followthrough"],
          %{"followthrough" => %{"source_scope" => source_scope}},
          context
        )

      messages = SourceBundle.gmail_messages(bundle)

      assert telemetry["plan"].exhaustive_account_delta?

      assert messages |> Enum.map(& &1["message_id"]) |> Enum.sort() ==
               ["delta-inbox", "delta-sent"]

      inbox = Enum.find(messages, &(&1["message_id"] == "delta-inbox"))
      sent = Enum.find(messages, &(&1["message_id"] == "delta-sent"))

      assert Enum.map(inbox["thread_context"], & &1["message_id"]) == ["thread-root"]

      assert Enum.map(sent["thread_context"], & &1["message_id"]) == [
               "thread-root",
               "delta-inbox"
             ]

      refute Enum.any?(messages, &(&1["message_id"] in ["thread-root", "future-message"]))
      assert inbox["thread_context_complete"]
      assert sent["thread_context_complete"]
      assert Acquisition.source_complete?(telemetry, "gmail")
      assert [%{kind: "gmail_discovery_watermark"}] = proposed_watermarks

      assert [%{"thread_fetch_count" => 1, "thread_failure_count" => 0}] =
               Enum.filter(telemetry["fetches"], &(&1["provider"] == provider))
    end

    test "exact closure fails closed when Gmail thread hydration fails", %{
      user_id: user_id,
      provider: provider
    } do
      assert {:ok, _token} =
               OAuth.store_tokens(user_id, provider, %{
                 access_token: "exact-closure-token",
                 scopes: Google.scopes_for(["gmail"]),
                 metadata: %{"account_email" => "watermark@example.com"}
               })

      delta = %{
        message_id: "closure-thread-delta",
        thread_id: "closure-thread",
        subject: "Closure evidence",
        labels: ["SENT"],
        internal_date: ~U[2026-06-01 11:30:00Z],
        text_body: "The requested work is complete."
      }

      TravelGmailStub.configure(
        messages_by_provider: %{provider => [delta]},
        thread_fetch_errors_by_thread: %{"closure-thread" => :temporarily_unavailable}
      )

      source_scope = %{
        "google_accounts" => [
          %{
            "provider" => provider,
            "account_email" => "watermark@example.com",
            "services" => ["gmail"]
          }
        ]
      }

      context =
        user_id
        |> watermark_build_context(true)
        |> Map.merge(%{
          source_scope: source_scope,
          source_watermark_role: "closure",
          exhaustive_account_delta: true,
          account_delta_source: "gmail"
        })

      {_bundle, telemetry, proposed_watermarks} =
        Acquisition.build(
          user_id,
          ["followthrough"],
          %{"followthrough" => %{"source_scope" => source_scope}},
          context
        )

      assert telemetry["plan"].exhaustive_account_delta?
      assert proposed_watermarks == []
      refute Acquisition.source_complete?(telemetry, "gmail")
      assert get_in(telemetry, ["sources", "gmail", "status"]) == "partial"

      assert [
               %{
                 "status" => "partial",
                 "detail_failure_count" => 1,
                 "thread_fetch_count" => 1,
                 "thread_failure_count" => 1
               }
             ] = Enum.filter(telemetry["fetches"], &(&1["provider"] == provider))
    end

    test "defers the watermark advance and proposes it instead when the caller asks", %{
      user_id: user_id,
      provider: provider,
      account: account
    } do
      TravelGmailStub.configure(
        messages: [
          %{
            message_id: "wm-msg-1",
            thread_id: "wm-thread-1",
            subject: "Hello",
            labels: ["INBOX"],
            internal_date: ~U[2026-06-01 11:00:00Z]
          }
        ],
        contents: %{}
      )

      skill_configs = %{
        "followthrough" => %{
          "source_scope" => %{
            "google_accounts" => [
              %{
                "provider" => provider,
                "account_email" => "watermark@example.com",
                "services" => ["gmail"]
              }
            ]
          },
          "email_scan_limit" => 10,
          "lookback_hours" => 48
        }
      }

      {_bundle, _telemetry, proposed_watermarks} =
        Acquisition.build(
          user_id,
          ["followthrough"],
          skill_configs,
          watermark_build_context(user_id, true)
        )

      # Not advanced immediately — R4 requires this to happen only after the
      # cycle's durable writes commit (in AIChiefOfStaff.finalize_cycle/1).
      refute Maraithon.Connectors.SourceCursors.get(account.id, "gmail_poll_watermark")

      assert [%{account: proposed_account, kind: "gmail_poll_watermark", value: value}] =
               proposed_watermarks

      assert proposed_account.id == account.id
      assert is_binary(value)
    end

    test "does not advance a watermark after failed candidate details", %{
      user_id: user_id,
      provider: provider,
      account: account
    } do
      TravelGmailStub.configure(
        messages: [
          %{
            message_id: "aa11",
            thread_id: "bb22",
            subject: "Partial fetch",
            labels: ["INBOX"],
            internal_date: ~U[2026-06-01 11:00:00Z]
          }
        ],
        fetch_metadata: %{
          listed_count: 40,
          requested_count: 35,
          detail_success_count: 34,
          detail_failure_count: 1,
          truncated?: true,
          complete?: false
        },
        contents: %{}
      )

      mark_watermark_account_error(account)

      skill_configs = %{
        "followthrough" => %{
          "source_scope" => %{
            "google_accounts" => [
              %{
                "provider" => provider,
                "account_email" => "watermark@example.com",
                "services" => ["gmail"]
              }
            ]
          },
          "email_scan_limit" => 10,
          "lookback_hours" => 48
        }
      }

      log =
        capture_log(fn ->
          result =
            Acquisition.build(
              user_id,
              ["followthrough"],
              skill_configs,
              watermark_build_context(user_id, true)
            )

          send(self(), {:failed_detail_fetch_result, result})
        end)

      assert_receive {:failed_detail_fetch_result, {_bundle, telemetry, proposed_watermarks}}
      assert log =~ "Gmail candidate fetch was incomplete"
      assert log =~ "detail failures: 1, truncated: true"

      assert proposed_watermarks == []
      refute Maraithon.Connectors.SourceCursors.get(account.id, "gmail_poll_watermark")
      assert get_in(telemetry, ["sources", "gmail", "status"]) == "partial"
      assert get_in(telemetry, ["sources", "gmail", "partial_providers"]) == [provider]
      assert get_in(telemetry, ["sources", "gmail", "failed_providers"]) == []
      assert get_in(telemetry, ["sources", "gmail", "backfill_needed_providers"]) == []

      assert [%{"status" => "partial", "detail_failure_count" => 1, "truncated" => true}] =
               Enum.filter(telemetry["fetches"], &(&1["provider"] == provider))

      unchanged_account = Maraithon.Repo.get!(Maraithon.Accounts.ConnectedAccount, account.id)
      assert unchanged_account.status == "error"
      assert is_map(unchanged_account.metadata["last_error"])
    end

    test "does not advance the live watermark after an intact truncated window", %{
      user_id: user_id,
      provider: provider,
      account: account
    } do
      TravelGmailStub.configure(
        messages: [
          %{
            message_id: "aa11",
            thread_id: "bb22",
            subject: "Newest bounded result",
            labels: ["INBOX"],
            internal_date: ~U[2026-06-01 11:00:00Z]
          }
        ],
        fetch_metadata: %{
          listed_count: 250,
          requested_count: 250,
          detail_success_count: 250,
          detail_failure_count: 0,
          truncated?: true,
          complete?: false
        },
        contents: %{}
      )

      mark_watermark_account_error(account)

      skill_configs = %{
        "followthrough" => %{
          "source_scope" => %{
            "google_accounts" => [
              %{
                "provider" => provider,
                "account_email" => "watermark@example.com",
                "services" => ["gmail"]
              }
            ]
          },
          "email_scan_limit" => 10,
          "lookback_hours" => 48
        }
      }

      log =
        capture_log(fn ->
          result =
            Acquisition.build(
              user_id,
              ["followthrough"],
              skill_configs,
              watermark_build_context(user_id, true)
            )

          send(self(), {:bounded_fetch_result, result})
        end)

      assert_receive {:bounded_fetch_result, {_bundle, telemetry, proposed_watermarks}}
      assert log =~ "Gmail candidate fetch was incomplete"

      refute Maraithon.Connectors.SourceCursors.get(account.id, "gmail_poll_watermark")
      assert proposed_watermarks == []
      assert get_in(telemetry, ["sources", "gmail", "status"]) == "partial"
      assert get_in(telemetry, ["sources", "gmail", "partial_providers"]) == [provider]
      assert get_in(telemetry, ["sources", "gmail", "failed_providers"]) == []
      assert get_in(telemetry, ["sources", "gmail", "backfill_needed_providers"]) == [provider]

      assert [%{"status" => "partial", "detail_failure_count" => 0, "truncated" => true}] =
               Enum.filter(telemetry["fetches"], &(&1["provider"] == provider))

      unchanged_account = Maraithon.Repo.get!(Maraithon.Accounts.ConnectedAccount, account.id)
      assert unchanged_account.status == "error"
      assert is_map(unchanged_account.metadata["last_error"])
    end

    # Regression test for the "non-agent callers advance the agent's poll
    # watermarks" fix: any caller that does not explicitly identify itself as
    # the scheduled AIChiefOfStaff cycle (`defer_watermark_advance: true`)
    # must leave `gmail_poll_watermark` untouched, since the scheduled
    # cycle's own delta fetch reads that cursor — a caller like
    # CrossSourceCompletion's evidence sweep advancing it immediately would
    # silently swallow deltas the agent never sees.
    test "does not advance or propose the watermark when the caller does not defer", %{
      user_id: user_id,
      provider: provider,
      account: account
    } do
      TravelGmailStub.configure(
        messages: [
          %{
            message_id: "wm-msg-2",
            thread_id: "wm-thread-2",
            subject: "Hello again",
            labels: ["INBOX"],
            internal_date: ~U[2026-06-01 11:00:00Z]
          }
        ],
        contents: %{}
      )

      skill_configs = %{
        "followthrough" => %{
          "source_scope" => %{
            "google_accounts" => [
              %{
                "provider" => provider,
                "account_email" => "watermark@example.com",
                "services" => ["gmail"]
              }
            ]
          },
          "email_scan_limit" => 10,
          "lookback_hours" => 48
        }
      }

      {_bundle, _telemetry, proposed_watermarks} =
        Acquisition.build(
          user_id,
          ["followthrough"],
          skill_configs,
          watermark_build_context(user_id, false)
        )

      assert proposed_watermarks == []
      refute Maraithon.Connectors.SourceCursors.get(account.id, "gmail_poll_watermark")
    end

    test "advances the watermark immediately when the caller explicitly opts in", %{
      user_id: user_id,
      provider: provider,
      account: account
    } do
      TravelGmailStub.configure(
        messages: [
          %{
            message_id: "wm-msg-3",
            thread_id: "wm-thread-3",
            subject: "Hello a third time",
            labels: ["INBOX"],
            internal_date: ~U[2026-06-01 11:00:00Z]
          }
        ],
        contents: %{}
      )

      skill_configs = %{
        "followthrough" => %{
          "source_scope" => %{
            "google_accounts" => [
              %{
                "provider" => provider,
                "account_email" => "watermark@example.com",
                "services" => ["gmail"]
              }
            ]
          },
          "email_scan_limit" => 10,
          "lookback_hours" => 48
        }
      }

      context =
        user_id
        |> watermark_build_context(false)
        |> Map.put(:advance_watermarks, true)

      {_bundle, _telemetry, proposed_watermarks} =
        Acquisition.build(user_id, ["followthrough"], skill_configs, context)

      assert proposed_watermarks == []

      assert %{value: value} =
               Maraithon.Connectors.SourceCursors.get(account.id, "gmail_poll_watermark")

      assert is_binary(value)
    end

    test "a deep-lookback fetch bypasses the cursor and does not advance or propose it", %{
      user_id: user_id,
      provider: provider,
      account: account
    } do
      {:ok, _cursor} =
        Maraithon.Connectors.SourceCursors.put(account, "gmail_poll_watermark", %{
          "value" => "1717200000"
        })

      TravelGmailStub.configure(
        messages: [
          %{
            message_id: "wm-msg-4",
            thread_id: "wm-thread-4",
            subject: "Deep lookback",
            labels: ["INBOX"],
            internal_date: ~U[2026-06-01 11:00:00Z]
          }
        ],
        contents: %{}
      )

      skill_configs = %{
        "followthrough" => %{
          "source_scope" => %{
            "google_accounts" => [
              %{
                "provider" => provider,
                "account_email" => "watermark@example.com",
                "services" => ["gmail"]
              }
            ]
          },
          "email_scan_limit" => 10,
          "lookback_hours" => 48
        }
      }

      context =
        user_id
        |> watermark_build_context(false)
        |> Map.put(:acquisition_deep_lookback, true)

      {_bundle, _telemetry, proposed_watermarks} =
        Acquisition.build(user_id, ["followthrough"], skill_configs, context)

      # The widened window query is used instead of "after:<cursor>" — the
      # whole point of a deep-lookback fetch is to see past what the cursor
      # would otherwise limit it to.
      refute Keyword.get(TravelGmailStub.last_fetch_opts(), :query) =~ "after:"

      assert proposed_watermarks == []

      assert %{value: "1717200000"} =
               Maraithon.Connectors.SourceCursors.get(account.id, "gmail_poll_watermark")
    end
  end

  defp slack_exact_skill_configs(team_id) do
    %{
      "followthrough" => %{
        "source_scope" => %{
          "slack_workspaces" => [
            %{"team_id" => team_id, "team_name" => "Exact workspace", "services" => ["channels"]}
          ]
        },
        "lookback_hours" => 48,
        "slack_message_scan_limit" => 100
      }
    }
  end

  defp slack_exact_build_context(user_id, team_id, now) do
    %{
      agent_id: "chief-agent-#{team_id}",
      user_id: user_id,
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "runtime_partition:source_account_discovery"},
      event: nil,
      source_scope: %{
        "slack_workspaces" => [
          %{"team_id" => team_id, "team_name" => "Exact workspace", "services" => ["channels"]}
        ]
      },
      exhaustive_account_delta: true,
      account_delta_source: "slack",
      source_watermark_role: "discovery",
      defer_watermark_advance: true
    }
  end

  defp slack_test_ts(%DateTime{} = datetime) do
    seconds = DateTime.to_unix(datetime, :second)
    microseconds = elem(datetime.microsecond, 0)
    "#{seconds}.#{microseconds |> Integer.to_string() |> String.pad_leading(6, "0")}"
  end

  # SPEC 07 R10/R11: pubsub-triggered cycles on the three subscribed topic
  # families skip news/weather/companion fetchers entirely, while always
  # fetching gmail + calendar + slack together; every other trigger (and any
  # unrecognized pubsub topic) fails open to the full unscoped fetch.
  @companion_sources ~w(calendar_local imessage voice_memos notes reminders files browser_history)

  defp scoped_build_context(trigger, event) do
    %{
      agent_id: "chief-agent-1",
      user_id: "chief@example.com",
      timestamp: ~U[2026-07-01 13:00:00Z],
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: trigger,
      event: event
    }
  end

  defp build_sources(context) do
    {_bundle, telemetry, _watermarks} =
      Acquisition.build(
        "chief@example.com",
        ["followthrough"],
        %{"followthrough" => %{"lookback_hours" => 48}},
        context
      )

    Map.keys(telemetry["sources"])
  end

  describe "trigger-scoped acquisition (SPEC 07 R10/R11)" do
    test "a pubsub email trigger fetches gmail+calendar+slack but not news/weather/companion sources" do
      sources =
        build_sources(
          scoped_build_context(
            %{type: :pubsub_event, topic: "email:chief@example.com"},
            %{topic: "email:chief@example.com", payload: %{"history_id" => "1"}}
          )
        )

      # R11: all three connector sources are attempted together (they report
      # unavailable/partial without connected accounts, but are never skipped).
      assert "gmail" in sources
      assert "calendar" in sources
      assert "slack" in sources

      refute "news" in sources
      refute "weather" in sources

      for companion <- @companion_sources do
        refute companion in sources
      end
    end

    test "a message-triggered cycle still fetches every source" do
      sources =
        build_sources(scoped_build_context(%{type: :message}, nil))

      assert "gmail" in sources
      assert "calendar" in sources
      assert "slack" in sources

      for companion <- @companion_sources do
        assert companion in sources
      end
    end

    test "an unrecognized pubsub topic fails open to the full fetch" do
      sources =
        build_sources(
          scoped_build_context(
            %{type: :pubsub_event, topic: "telegram:updates"},
            %{topic: "telegram:updates", payload: %{}}
          )
        )

      for companion <- @companion_sources do
        assert companion in sources
      end
    end
  end
end
