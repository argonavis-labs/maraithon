defmodule Maraithon.Todos.CrossSourceCompletionTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.Todos
  alias Maraithon.Todos.CrossSourceCompletion

  defp unique_user! do
    user_id = "cross-source-completion-#{Ecto.UUID.generate()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    user_id
  end

  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(DateTime.truncate(datetime, :second))

  defp open_todo_attrs(title, source_at, overrides \\ %{}) do
    %{
      "source" => Map.get(overrides, "source", "slack"),
      "kind" => "general",
      "title" => title,
      "summary" => Map.get(overrides, "summary", "This work needs source-backed completion."),
      "next_action" =>
        Map.get(overrides, "next_action", "Use the source material to close the loop."),
      "source_item_id" =>
        Map.get(overrides, "source_item_id", "C-events:#{System.unique_integer([:positive])}"),
      "source_occurred_at" => iso(source_at),
      "dedupe_key" => Map.get(overrides, "dedupe_key", "cross-source:#{Ecto.UUID.generate()}"),
      "metadata" => Map.get(overrides, "metadata", %{})
    }
    # Pass through any additional attrs (e.g. direction/counterparty_label)
    # the defaults above don't cover.
    |> Map.merge(overrides)
  end

  defp open_work_items(prompt) do
    captures =
      Regex.named_captures(
        ~r/OPEN_WORK_ITEMS_JSON:\n(?<json>\[.*?\])\n\nRECENT_ACTIVITY_JSON/s,
        prompt
      )

    Jason.decode!(captures["json"])
  end

  defp recent_activity(prompt) do
    captures =
      Regex.named_captures(
        ~r/RECENT_ACTIVITY_JSON \(current time [^)]+\):\n(?<json>\[.*?\])\n\nRespond with only/s,
        prompt
      )

    Jason.decode!(captures["json"])
  end

  defp exact_recent_activity(prompt) do
    captures =
      Regex.named_captures(
        ~r/RECENT_ACTIVITY_JSON \(current time [^)]+\):\n(?<json>\[.*?\])\n\nThis is an exact closure sweep/s,
        prompt
      )

    Jason.decode!(captures["json"])
  end

  test "an empty complete account delta makes no model call" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Keep the quiet account todo open", ~U[2099-06-20 12:00:00Z])
      ])

    source_bundle =
      %{timestamp: now, trigger: %{type: :wakeup}}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        "status" => "ready",
        "fetched_at" => now,
        "messages" => [],
        "inbox_messages" => [],
        "sent_messages" => [],
        "messages_by_provider" => %{}
      })

    llm_request = fn _params -> flunk("empty deltas must not call the model") end

    assert {:skip, :no_evidence} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               llm_request: llm_request
             )
  end

  test "closes stale event-creation work when later source evidence shows the event is live" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-18 18:56:06Z]

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs(
          "Create Luma event for Real Estate Webinar and invite Benji",
          source_at,
          %{
            "source_item_id" => "C-growth:4085845393.717109",
            "summary" =>
              "You committed to create the real estate webinar event and invite Benji to Luma.",
            "next_action" =>
              "Create the Luma event, invite Benji, and share the live event link.",
            "metadata" => %{
              "commitment_direction" => "i_owe",
              "completion_check" => %{
                "status" => "open",
                "reasoning" => "No later source evidence had been checked yet."
              },
              "quote" => "Kent to create the webinar, invite Benji to the Luma.",
              "why_it_matters" => "Unblocks webinar promotion and tracking setup."
            }
          }
        )
      ])

    source_bundle =
      %{timestamp: now, trigger: %{type: :wakeup}}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_slack(%{
        "status" => "ready",
        "fetched_at" => now,
        "workspaces" => [
          %{
            "team_id" => "T-growth",
            "team_name" => "Growth Crew",
            "channels" => [
              %{
                "id" => "C-growth",
                "name" => "growthcrew-x-runner",
                "messages" => [
                  %{
                    "ts" => "4085845400.900001",
                    "thread_ts" => "4085845393.717109",
                    "user" => "U-benji",
                    "text" =>
                      "There's definitely early signs of something worthwhile with the Luma thing. Check out the guest list: https://luma.com/event/manage/evt-real-estate/guests",
                    "permalink" => "https://example.slack.test/luma-real-estate"
                  }
                ]
              }
            ]
          }
        ]
      })

    llm_request = fn params ->
      assert params["max_tokens"] == 2_048
      assert params["reasoning_effort"] == "none"
      assert [%{"role" => "user", "content" => prompt}] = params["messages"]
      assert prompt =~ "current source material from every connected"
      assert prompt =~ "later source material showing the same event exists"
      assert prompt =~ "Create Luma event for Real Estate Webinar"
      assert prompt =~ "early signs of something worthwhile with the Luma thing"
      assert prompt =~ "evt-real-estate/guests"
      assert prompt =~ ~s("target_source_item_id":"C-growth:4085845393.717109")

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "resolutions" => [
               %{
                 "todo_id" => todo.id,
                 "completed" => true,
                 "evidence_channel" => "slack",
                 "evidence_quote" =>
                   "There's definitely early signs of something worthwhile with the Luma thing. Check out the guest list: https://luma.com/event/manage/evt-real-estate/guests",
                 "reasoning" =>
                   "The later Slack message links to the live Luma guest list for the same real estate webinar.",
                 "confidence" => 0.94
               }
             ]
           })
       }}
    end

    assert %{checked: 1, completed: 1} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               llm_request: llm_request
             )

    updated = Todos.get_for_user(user_id, todo.id)
    assert updated.status == "done"
    assert updated.metadata["resolution_note"] =~ "Handled already"
    assert updated.metadata["resolution_note"] =~ "Luma thing"
  end

  test "model-backed sweep prompt includes evidence from every connected source category" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-25 12:00:00Z]

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Review source-backed completion coverage", source_at)
      ])

    source_bundle =
      %{timestamp: now, trigger: %{type: :wakeup}}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        "status" => "ready",
        "fetched_at" => now,
        "messages" => [
          %{
            "message_id" => "gmail-marker",
            "thread_id" => "thread-gmail-marker",
            "subject" => "Gmail source marker",
            "text_body" => "gmail-source-marker",
            "internal_date" => now,
            "labels" => ["INBOX"],
            "account" => user_id
          }
        ]
      })
      |> SourceBundle.put_calendar(%{
        "status" => "ready",
        "fetched_at" => now,
        "events" => [
          %{
            "event_id" => "calendar-marker",
            "summary" => "Google Calendar source marker",
            "description" => "google-calendar-source-marker",
            "start" => now
          }
        ]
      })
      |> SourceBundle.put_calendar_local(%{
        "events" => [
          %{
            "guid" => "local-calendar-marker",
            "title" => "Local Calendar source marker",
            "notes" => "local-calendar-source-marker",
            "start_at" => now
          }
        ]
      })
      |> SourceBundle.put_slack(%{
        "status" => "ready",
        "fetched_at" => now,
        "workspaces" => [
          %{
            "team_id" => "T-marker",
            "channels" => [
              %{
                "id" => "C-marker",
                "name" => "source-markers",
                "messages" => [
                  %{"ts" => "4086280800.000000", "text" => "slack-source-marker"}
                ]
              }
            ]
          }
        ],
        "mentions" => [
          %{
            "channel_id" => "C-marker",
            "channel_name" => "source-markers",
            "ts" => "4086280801.000000",
            "text" => "slack-mention-source-marker"
          }
        ]
      })
      |> SourceBundle.put_imessage(%{
        "messages" => [
          %{
            "guid" => "imessage-marker",
            "chat_display_name" => "Messages Marker",
            "text" => "imessage-source-marker",
            "sent_at" => now,
            "is_from_me" => false
          }
        ]
      })
      |> SourceBundle.put_notes(%{
        "notes" => [
          %{"guid" => "note-marker", "title" => "Note marker", "body" => "notes-source-marker"}
        ]
      })
      |> SourceBundle.put_reminders(%{
        "reminders" => [
          %{
            "guid" => "reminder-marker",
            "title" => "Reminder marker",
            "notes" => "reminders-source-marker",
            "is_completed" => true,
            "completed_at" => now
          }
        ]
      })
      |> SourceBundle.put_files(%{
        "files" => [
          %{"id" => "file-marker", "name" => "File marker", "path" => "files-source-marker"}
        ]
      })
      |> SourceBundle.put_browser_history(%{
        "visits" => [
          %{
            "id" => "browser-marker",
            "title" => "Browser marker",
            "url" => "https://example.test/browser-history-source-marker",
            "visited_at" => now
          }
        ]
      })
      |> SourceBundle.put_voice_memos(%{
        "memos" => [
          %{
            "guid" => "voice-marker",
            "title" => "Voice memo marker",
            "transcript" => "voice-memos-source-marker",
            "created_at" => now
          }
        ]
      })

    llm_complete = fn prompt ->
      activity = recent_activity(prompt)
      assert Enum.any?(activity, &(&1["channel"] == "source_health"))

      for marker <- [
            "gmail-source-marker",
            "google-calendar-source-marker",
            "local-calendar-source-marker",
            "slack-source-marker",
            "slack-mention-source-marker",
            "imessage-source-marker",
            "notes-source-marker",
            "reminders-source-marker",
            "files-source-marker",
            "browser-history-source-marker",
            "voice-memos-source-marker"
          ] do
        assert prompt =~ marker
      end

      {:ok, %{content: Jason.encode!(%{"resolutions" => []})}}
    end

    assert %{checked: 1, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               llm_complete: llm_complete
             )
  end

  test "bounds the rendered prompt while preserving linked and cross-channel evidence" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-18 18:56:06Z]
    giant = String.duplicate("oversized-\"\n🙂", 20_000)
    noisy_text = String.duplicate("escaped-\"\n🙂", 80)

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Review the directly linked completion evidence", source_at, %{
          "source" => "gmail",
          "source_item_id" => "linked-thread",
          "summary" => noisy_text,
          "next_action" => noisy_text
        })
      ])

    gmail_messages =
      [
        %{
          "message_id" => giant,
          "thread_id" => "linked-thread",
          "subject" => "Directly linked message",
          "text_body" => "linked-evidence-marker " <> noisy_text,
          "internal_date" => DateTime.add(now, -500, :second),
          "labels" => ["INBOX"],
          "account" => giant
        }
      ] ++
        Enum.map(1..119, fn index ->
          %{
            "message_id" => "gmail-filler-#{index}",
            "thread_id" => "gmail-filler-thread-#{index}",
            "subject" => "Gmail filler #{index}",
            "text_body" => noisy_text,
            "internal_date" => DateTime.add(now, -index, :second),
            "labels" => ["INBOX"]
          }
        end)

    browser_visits =
      Enum.map(1..120, fn index ->
        %{
          "id" => "browser-filler-#{index}",
          "title" => "Browser marker #{index}",
          "url" => "https://example.test/browser-marker/#{index}?q=" <> noisy_text,
          "visited_at" => DateTime.add(now, -index, :second)
        }
      end)

    notes =
      Enum.map(1..120, fn index ->
        %{
          "guid" => "note-#{index}",
          "title" => "Notes marker #{index}",
          "body" => noisy_text,
          "updated_at" => DateTime.add(now, -index, :second)
        }
      end)

    imessages =
      Enum.map(1..120, fn index ->
        %{
          "guid" => "imessage-#{index}",
          "chat_display_name" => "Messages marker #{index}",
          "text" => noisy_text,
          "sent_at" => DateTime.add(now, -index, :second),
          "is_from_me" => false
        }
      end)

    source_bundle =
      %{timestamp: now, trigger: %{type: :wakeup}}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        "status" => "ready",
        "fetched_at" => now,
        "messages" => gmail_messages,
        "providers" => [giant],
        "metadata" => %{"unbounded" => giant}
      })
      |> SourceBundle.put_slack(%{
        "status" => "ready",
        "fetched_at" => now,
        "workspaces" => [
          %{
            "team_id" => "T-budget",
            "channels" => [
              %{
                "id" => "C-budget",
                "name" => "budget",
                "messages" => [
                  %{
                    "ts" => "4086280800.000000",
                    "date" => now,
                    "text" => "slack-channel-marker",
                    "permalink" => giant
                  }
                ]
              }
            ]
          }
        ]
      })
      |> SourceBundle.put_imessage(%{"messages" => imessages})
      |> SourceBundle.put_notes(%{"notes" => notes})
      |> SourceBundle.put_reminders(%{
        "reminders" => [
          %{
            "guid" => "reminder-budget",
            "title" => "reminders-channel-marker",
            "notes" => noisy_text,
            "updated_at" => now
          }
        ]
      })
      |> SourceBundle.put_browser_history(%{"visits" => browser_visits})
      |> SourceBundle.put_voice_memos(%{
        "status" => "partial",
        "fetched_at" => now,
        "memos" => [
          %{
            "guid" => "voice-budget",
            "title" => "voice-memos-channel-marker",
            "transcript" => noisy_text,
            "created_at" => now
          }
        ],
        "metadata" => %{"unbounded" => giant}
      })

    source_bundle =
      source_bundle
      |> put_in(
        ["freshness", "aaa_first"],
        %{"status" => "ready", "metadata" => %{"unbounded" => giant}}
      )
      |> put_in(
        ["freshness", "zzz_last"],
        %{
          "status" => "unavailable",
          "reason" => "last-source-reason",
          "metadata" => %{"unbounded" => giant}
        }
      )

    test_pid = self()

    llm_complete = fn prompt ->
      send(test_pid, {:bounded_prompt, prompt, recent_activity(prompt)})
      {:ok, %{content: Jason.encode!(%{"resolutions" => []})}}
    end

    assert %{checked: 1, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               llm_complete: llm_complete
             )

    assert_receive {:bounded_prompt, prompt, activity}
    assert byte_size(prompt) <= 96_000
    assert length(activity) <= 96

    channels = activity |> Enum.map(& &1["channel"]) |> MapSet.new()

    for channel <-
          ~w(source_health gmail slack imessage notes reminders browser_history voice_memos) do
      assert MapSet.member?(channels, channel)
    end

    linked = Enum.find(activity, &(&1["thread_id"] == "linked-thread"))
    assert linked["text"] =~ "linked-evidence-marker"
    assert byte_size(linked["source_item_id"]) <= 256
    assert byte_size(linked["account"]) <= 200

    health = Enum.find(activity, &(&1["channel"] == "source_health"))
    health_map = Jason.decode!(health["text"])
    assert health_map["aaa_first"]["status"] == "ready"
    assert health_map["zzz_last"]["status"] == "unavailable"
    assert health_map["zzz_last"]["reason"] == "last-source-reason"
    refute health["text"] =~ "unbounded"
  end

  test "fails closed without stamping when checked todos alone exceed the prompt budget" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-18 18:56:06Z]
    escaped = "\"\\\n"

    attrs =
      Enum.map(1..40, fn index ->
        title = ("#{index}:" <> String.duplicate(escaped, 80)) |> String.slice(0, 240)

        open_todo_attrs(title, source_at, %{
          "source" => "gmail",
          "summary" => String.duplicate(escaped, 666),
          "next_action" => String.duplicate(escaped, 333),
          "source_item_id" => "pathological-thread-#{index}",
          "source_account_label" => String.duplicate(escaped, 85),
          "counterparty_label" => String.duplicate(escaped, 85),
          "dedupe_key" => "pathological-budget:#{index}:#{Ecto.UUID.generate()}"
        })
      end)

    {:ok, todos} = Todos.upsert_many(user_id, attrs)

    source_bundle =
      %{timestamp: now, trigger: %{type: :wakeup}}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        "status" => "ready",
        "fetched_at" => now,
        "messages" =>
          Enum.map(1..40, fn index ->
            %{
              "message_id" => "pathological-message-#{index}",
              "thread_id" => "pathological-thread-#{index}",
              "subject" => "Pathological evidence #{index}",
              "text_body" => String.duplicate(escaped, 100),
              "internal_date" => DateTime.add(now, -index, :second),
              "labels" => ["INBOX"]
            }
          end)
      })

    llm_complete = fn prompt ->
      send(self(), {:pathological_prompt, prompt})
      {:ok, %{content: Jason.encode!(%{"resolutions" => []})}}
    end

    assert %{checked: checked, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               llm_complete: llm_complete
             )

    assert checked in 1..40
    assert_receive {:pathological_prompt, prompt}

    assert prompt
           |> then(&[%{"role" => "user", "content" => &1}])
           |> Maraithon.AssistantHarness.PromptStability.encode!()
           |> byte_size() <= 96_000

    stamped =
      Enum.count(todos, fn todo ->
        not is_nil(Todos.get_for_user(user_id, todo.id).last_completion_checked_at)
      end)

    assert stamped == checked
  end

  defp bulk_todo_attrs(title, source_at, index) do
    open_todo_attrs(title, source_at, %{
      "source_item_id" => "bulk-item-#{index}:#{System.unique_integer([:positive])}",
      "dedupe_key" => "cross-source-bulk:#{index}:#{Ecto.UUID.generate()}"
    })
  end

  defp gmail_reply_bundle(now, thread_id, text) do
    %{timestamp: now, trigger: %{type: :wakeup}}
    |> SourceBundle.empty(%{})
    |> SourceBundle.put_gmail(%{
      "status" => "ready",
      "fetched_at" => now,
      "messages" => [
        %{
          "message_id" => "gmail-#{thread_id}",
          "thread_id" => thread_id,
          "subject" => "Re: the thing you are waiting on",
          "text_body" => text,
          "internal_date" => now,
          "labels" => ["INBOX"]
        }
      ]
    })
  end

  test "evidence-linked todo is checked even when it is not among the 40 oldest open todos" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-18 18:56:06Z]

    backstop_attrs =
      Enum.map(1..44, fn index ->
        bulk_todo_attrs("Backstop bulk item number #{index}", source_at, index)
      end)

    {:ok, _todos} = Todos.upsert_many(user_id, backstop_attrs)

    # Created LAST, so it is the newest by updated_at — the old 40-oldest cap
    # would never check it.
    {:ok, [target]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Evidence linked newest waiting item", source_at, %{
          "source_item_id" => "thread-evidence-linked-newest",
          "dedupe_key" => "cross-source-bulk:target:#{Ecto.UUID.generate()}"
        })
      ])

    source_bundle =
      gmail_reply_bundle(now, "thread-evidence-linked-newest", "Here is the answer you needed.")

    test_pid = self()

    llm_complete = fn prompt ->
      send(test_pid, {:prompt, prompt})
      {:ok, %{content: Jason.encode!(%{"resolutions" => []})}}
    end

    assert %{checked: 40, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               llm_complete: llm_complete
             )

    assert_receive {:prompt, prompt}
    assert prompt =~ "Evidence linked newest waiting item"

    # The cycle stamp advanced for the checked target.
    assert %DateTime{} = Todos.get_for_user(user_id, target.id).last_completion_checked_at
  end

  test "linked candidate cap rotates instead of starving the same later todos" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-18 18:56:06Z]

    attrs =
      Enum.map(1..45, fn index ->
        open_todo_attrs("Linked rotation item #{index}", source_at, %{
          "source" => "gmail",
          "source_item_id" => "linked-rotation-thread-#{index}",
          "dedupe_key" => "linked-rotation:#{index}:#{Ecto.UUID.generate()}"
        })
      end)

    {:ok, todos} = Todos.upsert_many(user_id, attrs)

    source_bundle =
      %{timestamp: now, trigger: %{type: :wakeup}}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        "status" => "ready",
        "fetched_at" => now,
        "messages" =>
          Enum.map(1..45, fn index ->
            %{
              "message_id" => "linked-rotation-message-#{index}",
              "thread_id" => "linked-rotation-thread-#{index}",
              "subject" => "Linked rotation evidence #{index}",
              "text_body" => "Evidence for linked rotation item #{index}",
              "internal_date" => DateTime.add(now, -index, :second),
              "labels" => ["INBOX"]
            }
          end)
      })

    test_pid = self()

    llm_complete = fn prompt ->
      send(test_pid, {:rotation_prompt, prompt})
      {:ok, %{content: Jason.encode!(%{"resolutions" => []})}}
    end

    assert %{checked: 40, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               llm_complete: llm_complete
             )

    assert_receive {:rotation_prompt, first_prompt}

    first_ids = first_prompt |> open_work_items() |> MapSet.new(& &1["todo_id"])
    left_out = Enum.reject(todos, &MapSet.member?(first_ids, &1.id))
    assert length(left_out) == 5

    assert %{checked: 40, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: DateTime.add(now, 3600, :second),
               source_bundle: source_bundle,
               llm_complete: llm_complete
             )

    assert_receive {:rotation_prompt, second_prompt}
    second_ids = second_prompt |> open_work_items() |> MapSet.new(& &1["todo_id"])

    for todo <- left_out do
      assert MapSet.member?(second_ids, todo.id)
    end
  end

  test "backstop rotation prefers never-checked todos over ones stamped last cycle" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-18 18:56:06Z]

    attrs =
      Enum.map(1..45, fn index ->
        bulk_todo_attrs("Rotation bulk item number #{index}", source_at, index)
      end)

    {:ok, todos} = Todos.upsert_many(user_id, attrs)

    # No todo matches the evidence, so all 45 compete for the 40-slot backstop.
    source_bundle = gmail_reply_bundle(now, "thread-unrelated-to-everything", "Unrelated note.")

    test_pid = self()

    llm_complete = fn prompt ->
      send(test_pid, {:prompt, prompt})
      {:ok, %{content: Jason.encode!(%{"resolutions" => []})}}
    end

    assert %{checked: 40, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               llm_complete: llm_complete
             )

    assert_receive {:prompt, first_prompt}
    first_ids = first_prompt |> open_work_items() |> MapSet.new(& &1["todo_id"])
    left_out = Enum.reject(todos, &MapSet.member?(first_ids, &1.id))

    assert length(left_out) == 5

    # Every checked candidate was stamped, including non-closers.
    checked = Enum.find(todos, &MapSet.member?(first_ids, &1.id))
    assert %DateTime{} = Todos.get_for_user(user_id, checked.id).last_completion_checked_at

    assert %{checked: 40, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: DateTime.add(now, 3600, :second),
               source_bundle: source_bundle,
               llm_complete: llm_complete
             )

    assert_receive {:prompt, second_prompt}
    second_ids = second_prompt |> open_work_items() |> MapSet.new(& &1["todo_id"])

    # The five never-checked todos sort ahead of the just-stamped forty.
    for todo <- left_out do
      assert MapSet.member?(second_ids, todo.id)
    end
  end

  test "counterparty reply that answers an owed_to_me item closes it with distinct copy and a Telegram confirmation" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-18 18:56:06Z]

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "556677",
        metadata: %{"username" => "cross-source"}
      })

    {:ok, [waiting, owed_by_me]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Waiting on Elena for the pricing doc", source_at, %{
          "source" => "gmail",
          "direction" => "owed_to_me",
          "counterparty_label" => "Elena Fisher",
          "source_item_id" => "thread-elena-pricing",
          "next_action" => "Wait for Elena to send the pricing doc.",
          "dedupe_key" => "cross-source-owed:#{Ecto.UUID.generate()}"
        }),
        open_todo_attrs("Send the board update yourself", source_at, %{
          "source" => "gmail",
          "direction" => "owed_by_me",
          "source_item_id" => "thread-board-update",
          "dedupe_key" => "cross-source-owed-by:#{Ecto.UUID.generate()}"
        })
      ])

    source_bundle =
      gmail_reply_bundle(now, "thread-elena-pricing", "Here's the pricing doc you asked for.")

    test_pid = self()

    llm_complete = fn prompt ->
      assert prompt =~ "\"direction\":\"owed_to_me\""
      assert prompt =~ "Elena Fisher"
      assert prompt =~ "thread-elena-pricing"
      assert prompt =~ "reply_outcome"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "resolutions" => [
               %{
                 "todo_id" => waiting.id,
                 "completed" => true,
                 "evidence_channel" => "gmail",
                 "evidence_quote" => "Here's the pricing doc you asked for.",
                 "reasoning" => "Elena's inbound reply carries the doc the user was waiting on.",
                 "confidence" => 0.93,
                 "reply_outcome" => "answered"
               },
               %{
                 "todo_id" => owed_by_me.id,
                 "completed" => true,
                 "evidence_channel" => "gmail",
                 "evidence_quote" => "Board update sent, thanks all.",
                 "reasoning" => "The user sent the board update.",
                 "confidence" => 0.91
               }
             ]
           })
       }}
    end

    push_deliver = fn candidate ->
      send(test_pid, {:push, candidate})
      {:ok, %{decision: "sent_now", message_id: "1"}}
    end

    assert %{checked: 2, completed: 1} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               llm_complete: llm_complete,
               push_deliver: push_deliver
             )

    closed_waiting = Todos.get_for_user(user_id, waiting.id)
    assert closed_waiting.status == "done"

    assert closed_waiting.metadata["resolution_note"] =~
             "Elena Fisher replied — closing that loop."

    refute closed_waiting.metadata["resolution_note"] =~ "Handled already"

    untouched_owed_by_me = Todos.get_for_user(user_id, owed_by_me.id)
    assert untouched_owed_by_me.status == "open"
    refute Map.has_key?(untouched_owed_by_me.metadata, "resolution_note")

    # Exactly one push: only the source-authorized owed_to_me close is delivered.
    assert_receive {:push, candidate}
    refute_receive {:push, _another}

    assert candidate.user_id == user_id
    assert candidate.chat_id == "556677"
    assert candidate.origin_type == "todo_completion_confirm"
    assert candidate.origin_id == waiting.id
    assert candidate.dedupe_key == "todo_completion_confirm:#{waiting.id}"
    assert candidate.urgency == 0.3
    assert candidate.interrupt_now == false
    assert candidate.body =~ "Elena Fisher replied — closing that loop on:"
  end

  test "acknowledged-only counterparty reply clears the nudge cadence without closing or pushing" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-18 18:56:06Z]

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "556688",
        metadata: %{"username" => "cross-source-ack"}
      })

    {:ok, [waiting]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Waiting on Sam for the contract review", source_at, %{
          "source" => "gmail",
          "direction" => "owed_to_me",
          "counterparty_label" => "Sam Ortiz",
          "source_item_id" => "thread-sam-contract",
          "dedupe_key" => "cross-source-ack:#{Ecto.UUID.generate()}"
        })
      ])

    {:ok, _stamped} =
      Todos.get_for_user(user_id, waiting.id)
      |> Ecto.Changeset.change(next_nudge_at: ~U[2099-06-29 14:00:00Z])
      |> Repo.update()

    source_bundle =
      gmail_reply_bundle(now, "thread-sam-contract", "Got it, will take a look next week.")

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "resolutions" => [
               %{
                 "todo_id" => waiting.id,
                 "completed" => false,
                 "evidence_channel" => "gmail",
                 "evidence_quote" => "Got it, will take a look next week.",
                 "reasoning" => "Sam only acknowledged; the review itself hasn't happened.",
                 "confidence" => 0.9,
                 "reply_outcome" => "acknowledged_only"
               }
             ]
           })
       }}
    end

    test_pid = self()

    push_deliver = fn candidate ->
      send(test_pid, {:push, candidate})
      {:ok, %{decision: "sent_now", message_id: "1"}}
    end

    assert %{checked: 1, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               llm_complete: llm_complete,
               push_deliver: push_deliver
             )

    updated = Todos.get_for_user(user_id, waiting.id)
    assert updated.status == "open"
    assert is_nil(updated.next_nudge_at)
    assert updated.metadata["resolution_note"] =~ "cadence cleared"

    refute_receive {:push, _candidate}
  end

  test "owed_to_me confirmation push is skipped when no Telegram destination resolves, with They fallback copy" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-18 18:56:06Z]

    {:ok, [waiting]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Waiting on the vendor security answers", source_at, %{
          "source" => "gmail",
          "direction" => "owed_to_me",
          "source_item_id" => "thread-vendor-security",
          "dedupe_key" => "cross-source-nochat:#{Ecto.UUID.generate()}"
        })
      ])

    source_bundle =
      gmail_reply_bundle(now, "thread-vendor-security", "Answers attached for every question.")

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "resolutions" => [
               %{
                 "todo_id" => waiting.id,
                 "completed" => true,
                 "evidence_channel" => "gmail",
                 "evidence_quote" => "Answers attached for every question.",
                 "reasoning" => "The counterparty reply delivers exactly what was awaited.",
                 "confidence" => 0.92,
                 "reply_outcome" => "answered"
               }
             ]
           })
       }}
    end

    test_pid = self()

    push_deliver = fn candidate ->
      send(test_pid, {:push, candidate})
      {:ok, %{decision: "sent_now", message_id: "1"}}
    end

    assert %{checked: 1, completed: 1} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               llm_complete: llm_complete,
               push_deliver: push_deliver
             )

    updated = Todos.get_for_user(user_id, waiting.id)
    assert updated.status == "done"
    assert updated.metadata["resolution_note"] =~ "They replied — closing that loop."

    # No connected Telegram account: the push candidate is never built.
    refute_receive {:push, _candidate}
  end

  test "live source acquisition timeout is surfaced as source health evidence" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-25 12:00:00Z]

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Follow up after source acquisition timeout", source_at)
      ])

    source_bundle_fetcher = fn _user_id, _todos, _now, _opts ->
      receive do
        :finish -> :ok
      end
    end

    llm_complete = fn prompt ->
      health = recent_activity(prompt) |> Enum.find(&(&1["channel"] == "source_health"))
      health_map = Jason.decode!(health["text"])
      assert health_map["live_sources"]["status"] == "unavailable"
      assert health_map["live_sources"]["reason"] == "Elixir.RuntimeError"

      {:ok, %{content: Jason.encode!(%{"resolutions" => []})}}
    end

    assert %{checked: 1, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_timeout_ms: 5,
               source_bundle_fetcher: source_bundle_fetcher,
               llm_complete: llm_complete
             )
  end

  test "fabricated evidence quote cannot close linked work" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-25 12:00:00Z]

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Wait for the signed proposal", source_at, %{
          "source" => "gmail",
          "source_item_id" => "thread-proposal"
        })
      ])

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "resolutions" => [
               %{
                 "todo_id" => todo.id,
                 "completed" => true,
                 "evidence_channel" => "gmail",
                 "evidence_quote" => "The proposal is signed and complete.",
                 "reasoning" => "Claimed completion.",
                 "confidence" => 0.99
               }
             ]
           })
       }}
    end

    assert %{checked: 1, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: gmail_reply_bundle(now, "thread-proposal", "Still working on it."),
               llm_complete: llm_complete
             )

    assert Todos.get_for_user(user_id, todo.id).status == "open"
  end

  test "the user's outbound message cannot clear an owed-to-me chase" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-25 12:00:00Z]

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Waiting for Maya to confirm", source_at, %{
          "source" => "imessage",
          "source_item_id" => "thread-maya",
          "direction" => "owed_to_me",
          "next_nudge_at" => DateTime.to_iso8601(DateTime.add(now, 86_400, :second))
        })
      ])

    source_bundle =
      %{timestamp: now, trigger: %{type: :wakeup}}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_imessage(%{
        "status" => "ready",
        "messages" => [
          %{
            "guid" => "thread-maya",
            "is_from_me" => true,
            "text" => "Thanks, I will wait for your confirmation.",
            "sent_at" => now
          }
        ]
      })

    llm_complete = fn _prompt ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "resolutions" => [
               %{
                 "todo_id" => todo.id,
                 "completed" => false,
                 "reply_outcome" => "acknowledged_only",
                 "evidence_channel" => "imessage",
                 "evidence_quote" => "Thanks, I will wait for your confirmation.",
                 "reasoning" => "A message acknowledged the chase.",
                 "confidence" => 0.99
               }
             ]
           })
       }}
    end

    assert %{checked: 1, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               llm_complete: llm_complete
             )

    updated = Todos.get_for_user(user_id, todo.id)
    assert updated.status == "open"
    assert %DateTime{} = updated.next_nudge_at
  end

  test "exact oversized Gmail and Slack evidence evaluates every todo against every lossless chunk" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-20 12:00:00Z]
    slack_ts = "#{DateTime.to_unix(now)}.000001"
    gmail_provider = "google:gmail:exact-large"
    gmail_ref = "gmail:#{gmail_provider}:gmail-large"
    slack_ref = "slack:T-large:C-large:#{slack_ts}"
    gmail_proof = "GMAIL COMPLETION PROOF"
    slack_proof = "SLACK COMPLETION PROOF"

    gmail_text = String.duplicate("gmail-évidence-🔥 ", 6_000) <> gmail_proof
    slack_text = String.duplicate("slack-context-🧵 ", 6_000) <> slack_proof

    {:ok, [gmail_todo, slack_todo, unresolved_todo]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Finish the oversized Gmail work", source_at, %{
          "source" => "gmail",
          "source_item_id" => "gmail-large"
        }),
        open_todo_attrs("Finish the oversized Slack work", source_at, %{
          "source" => "slack",
          "source_item_id" => "C-large:#{slack_ts}"
        }),
        open_todo_attrs("Keep unresolved work open", source_at, %{
          "source" => "gmail",
          "source_item_id" => "unrelated-source-item"
        })
      ])

    gmail_message = %{
      "message_id" => "gmail-large",
      "thread_id" => "gmail-thread-large",
      "google_provider" => gmail_provider,
      "subject" => "Oversized Gmail evidence",
      "body_text" => gmail_text,
      "internal_date" => now,
      "labels" => ["INBOX"]
    }

    source_bundle =
      %{timestamp: now, trigger: %{type: :wakeup}}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        "status" => "ready",
        "fetched_at" => now,
        "messages" => [gmail_message],
        "inbox_messages" => [gmail_message],
        "sent_messages" => []
      })
      |> SourceBundle.put_slack(%{
        "status" => "ready",
        "fetched_at" => now,
        "workspaces" => [
          %{
            "team_id" => "T-large",
            "channels" => [
              %{
                "id" => "C-large",
                "name" => "large-evidence",
                "messages" => [
                  %{
                    "ts" => slack_ts,
                    "user" => "U-counterparty",
                    "text" => slack_text
                  }
                ]
              }
            ]
          }
        ]
      })

    test_pid = self()

    llm_complete = fn prompt ->
      todos = open_work_items(prompt)
      activity = exact_recent_activity(prompt)
      send(test_pid, {:exact_chunk, todos, activity})

      gmail_proven? = Enum.any?(activity, &String.contains?(&1["text"] || "", gmail_proof))
      slack_proven? = Enum.any?(activity, &String.contains?(&1["text"] || "", slack_proof))

      resolutions =
        Enum.map(todos, fn todo ->
          cond do
            todo["todo_id"] == gmail_todo.id and gmail_proven? ->
              %{
                "todo_id" => gmail_todo.id,
                "completed" => true,
                "evidence_channel" => "gmail",
                "evidence_quote" => gmail_proof,
                "reasoning" => "The Gmail evidence proves completion.",
                "confidence" => 0.99
              }

            todo["todo_id"] == slack_todo.id and slack_proven? ->
              %{
                "todo_id" => slack_todo.id,
                "completed" => true,
                "evidence_channel" => "slack",
                "evidence_quote" => slack_proof,
                "reasoning" => "The Slack evidence proves completion.",
                "confidence" => 0.99
              }

            true ->
              %{"todo_id" => todo["todo_id"], "completed" => false}
          end
        end)

      {:ok, %{content: Jason.encode!(%{"resolutions" => resolutions})}}
    end

    assert %{checked: 3, completed: 2, model_calls: model_calls} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               exact_source_delta: true,
               exhaustive_completion: true,
               source_item_refs: [gmail_ref, slack_ref],
               todo_ids: [gmail_todo.id, slack_todo.id, unresolved_todo.id],
               llm_complete: llm_complete
             )

    assert model_calls > 1

    chunks =
      Enum.map(1..model_calls, fn _index ->
        assert_receive {:exact_chunk, todos, activity}

        assert Enum.sort(Enum.map(todos, & &1["todo_id"])) ==
                 Enum.sort([gmail_todo.id, slack_todo.id, unresolved_todo.id])

        activity
      end)

    observed_refs =
      chunks
      |> List.flatten()
      |> Enum.map(& &1["source_ref"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    assert observed_refs == MapSet.new([gmail_ref, slack_ref])

    reconstructed_gmail =
      chunks
      |> List.flatten()
      |> Enum.filter(&(&1["source_ref"] == gmail_ref))
      |> Enum.map_join(& &1["text"])

    reconstructed_slack =
      chunks
      |> List.flatten()
      |> Enum.filter(&(&1["source_ref"] == slack_ref))
      |> Enum.map_join(& &1["text"])

    assert reconstructed_gmail == gmail_text
    assert reconstructed_slack == slack_text
    assert String.valid?(reconstructed_gmail)
    assert String.valid?(reconstructed_slack)
    assert Todos.get_for_user(user_id, gmail_todo.id).status == "done"
    assert Todos.get_for_user(user_id, slack_todo.id).status == "done"
    assert Todos.get_for_user(user_id, unresolved_todo.id).status == "open"
  end

  test "exact Gmail closure can use historical thread context without treating it as a delta item" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-20 12:00:00Z]
    provider = "google:gmail:thread-context"
    delta_ref = "gmail:#{provider}:gmail-delta"
    completion_proof = "The signed agreement is attached and the work is complete."

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Finish the agreement", source_at, %{
          "source" => "gmail",
          "source_item_id" => "agreement-thread"
        })
      ])

    delta_message = %{
      "message_id" => "gmail-delta",
      "thread_id" => "agreement-thread",
      "google_provider" => provider,
      "subject" => "Re: agreement",
      "body_text" => "Thanks for the update.",
      "internal_date" => now,
      "labels" => ["INBOX"],
      "thread_context_complete" => true,
      "thread_context" => [
        %{
          "message_id" => "gmail-history-only",
          "thread_id" => "agreement-thread",
          "from" => "Elena <elena@example.com>",
          "body_text" => completion_proof,
          "internal_date" => DateTime.add(now, -60, :second),
          "labels" => ["INBOX"]
        }
      ]
    }

    source_bundle =
      %{timestamp: now, trigger: %{type: :wakeup}}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        "status" => "ready",
        "fetched_at" => now,
        "messages" => [delta_message],
        "inbox_messages" => [delta_message],
        "sent_messages" => []
      })

    llm_complete = fn prompt ->
      activity =
        prompt
        |> exact_recent_activity()
        |> Enum.find(&(&1["channel"] == "gmail"))

      assert activity["source_ref"] == delta_ref
      assert activity["text"] =~ "Thanks for the update."
      assert activity["text"] =~ completion_proof

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "resolutions" => [
               %{
                 "todo_id" => todo.id,
                 "completed" => true,
                 "evidence_channel" => "gmail",
                 "evidence_quote" => completion_proof,
                 "reasoning" => "The earlier message in the hydrated thread proves completion.",
                 "confidence" => 0.99
               }
             ]
           })
       }}
    end

    assert %{checked: 1, completed: 1, decision_refs: [todo_id]} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               exact_source_delta: true,
               exhaustive_completion: true,
               source_item_refs: [delta_ref],
               todo_ids: [todo.id],
               llm_complete: llm_complete
             )

    assert todo_id == todo.id
    assert Todos.get_for_user(user_id, todo.id).status == "done"
  end

  test "exact evidence applies no early completion when a later chunk fails" do
    user_id = unique_user!()
    now = ~U[2099-06-27 14:00:00Z]
    source_at = ~U[2099-06-20 12:00:00Z]
    slack_ts = "#{DateTime.to_unix(now)}.000002"
    slack_ref = "slack:T-fail-closed:C-fail-closed:#{slack_ts}"
    completion_proof = "EARLY CHUNK COMPLETION PROOF"
    oversized_text = completion_proof <> String.duplicate("🚧", 40_000)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        open_todo_attrs("Do not close before every evidence chunk settles", source_at, %{
          "source" => "slack",
          "source_item_id" => "C-fail-closed:#{slack_ts}"
        })
      ])

    source_bundle =
      %{timestamp: now, trigger: %{type: :wakeup}}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_slack(%{
        "status" => "ready",
        "fetched_at" => now,
        "workspaces" => [
          %{
            "team_id" => "T-fail-closed",
            "channels" => [
              %{
                "id" => "C-fail-closed",
                "messages" => [
                  %{"ts" => slack_ts, "user" => "U-proof", "text" => oversized_text}
                ]
              }
            ]
          }
        ]
      })

    counter_key = {:exact_chunk_counter, make_ref()}
    test_pid = self()

    llm_complete = fn prompt ->
      call = Process.get(counter_key, 0) + 1
      Process.put(counter_key, call)
      send(test_pid, {:exact_fail_closed_chunk, call})

      if call == 1 do
        assert Enum.any?(
                 exact_recent_activity(prompt),
                 &String.contains?(&1["text"] || "", completion_proof)
               )

        {:ok,
         %{
           content:
             Jason.encode!(%{
               "resolutions" => [
                 %{
                   "todo_id" => todo.id,
                   "completed" => true,
                   "evidence_channel" => "slack",
                   "evidence_quote" => completion_proof,
                   "reasoning" => "The first chunk proves completion.",
                   "confidence" => 0.99
                 }
               ]
             })
         }}
      else
        {:error, :later_exact_chunk_failed}
      end
    end

    assert {:error, :later_exact_chunk_failed} =
             CrossSourceCompletion.run_for_user(user_id,
               now: now,
               source_bundle: source_bundle,
               exact_source_delta: true,
               exhaustive_completion: true,
               source_item_refs: [slack_ref],
               todo_ids: [todo.id],
               llm_complete: llm_complete
             )

    assert_receive {:exact_fail_closed_chunk, 1}
    assert_receive {:exact_fail_closed_chunk, 2}
    assert Todos.get_for_user(user_id, todo.id).status == "open"
  end
end
