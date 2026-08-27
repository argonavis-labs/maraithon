defmodule Maraithon.ChiefOfStaff.AcquisitionTest do
  use Maraithon.DataCase, async: false

  import ExUnit.CaptureLog

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
          "channels" => [%{"id" => "CSELECTED", "name" => "exec-priority"}]
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

    test "advances the live watermark after an intact truncated window", %{
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
      refute log =~ "Gmail candidate fetch was incomplete"

      refute Maraithon.Connectors.SourceCursors.get(account.id, "gmail_poll_watermark")

      assert [%{account: proposed_account, kind: "gmail_poll_watermark", value: value}] =
               proposed_watermarks

      assert proposed_account.id == account.id
      assert is_binary(value)
      assert get_in(telemetry, ["sources", "gmail", "status"]) == "partial"
      assert get_in(telemetry, ["sources", "gmail", "partial_providers"]) == [provider]
      assert get_in(telemetry, ["sources", "gmail", "failed_providers"]) == []
      assert get_in(telemetry, ["sources", "gmail", "backfill_needed_providers"]) == [provider]

      assert [%{"status" => "partial", "detail_failure_count" => 0, "truncated" => true}] =
               Enum.filter(telemetry["fetches"], &(&1["provider"] == provider))

      healed_account = Maraithon.Repo.get!(Maraithon.Accounts.ConnectedAccount, account.id)
      assert healed_account.status == "connected"
      assert is_binary(healed_account.metadata["last_successful_sync_at"])
      refute Map.has_key?(healed_account.metadata, "last_error")
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
