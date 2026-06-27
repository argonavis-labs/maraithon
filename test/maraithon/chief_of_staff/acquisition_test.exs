defmodule Maraithon.ChiefOfStaff.AcquisitionTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.ChiefOfStaff.{Acquisition, SourceBundle}
  alias Maraithon.OAuth
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

  test "expands Slack parent threads for thread broadcasts in the source bundle" do
    now = ~U[2026-06-18 15:00:00Z]
    bypass = Bypass.open()

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

    {bundle, telemetry} =
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

  test "limits Slack history scans after priority sorting" do
    now = ~U[2026-06-18 15:00:00Z]
    bypass = Bypass.open()

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
            %{"id" => "CLOW", "name" => "random", "is_private" => false},
            %{"id" => "CEXEC", "name" => "exec-real-estate", "is_private" => true},
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

    {bundle, telemetry} =
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

  test "adds self-authored Slack search matches when private channel history is not enumerable" do
    now = ~U[2026-06-18 21:24:00Z]
    bypass = Bypass.open()

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
            %{"id" => "C111", "name" => "runner-general", "is_private" => false}
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

    {bundle, telemetry} =
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

    {bundle, telemetry} =
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
    assert get_in(telemetry, ["sources", "gmail", "full_body_count"]) == 2
    assert get_in(telemetry, ["sources", "gmail", "body_missing_count"]) == 0
    assert get_in(telemetry, ["sources", "calendar", "status"]) == "ready"
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

    {bundle, telemetry} =
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

    {bundle, telemetry} =
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
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry} =
      Acquisition.build("chief@example.com", ["morning_briefing"], skill_configs, context)

    [item] = SourceBundle.news_items(bundle)
    assert item["title"] =~ "Slack launches"
    assert get_in(telemetry, ["sources", "news", "status"]) == "ready"
    assert get_in(telemetry, ["sources", "news", "item_count"]) == 1
  end
end
