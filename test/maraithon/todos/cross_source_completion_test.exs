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
            "source_item_id" => "C-growth:1781808966.732249",
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
                    "ts" => "4085845393.717109",
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
      for marker <- [
            "source_health",
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

    left_out =
      Enum.filter(todos, fn todo -> not String.contains?(first_prompt, todo.title) end)

    assert length(left_out) == 5

    # Every checked candidate was stamped, including non-closers.
    checked = Enum.find(todos, fn todo -> String.contains?(first_prompt, todo.title) end)
    assert %DateTime{} = Todos.get_for_user(user_id, checked.id).last_completion_checked_at

    assert %{checked: 40, completed: 0} =
             CrossSourceCompletion.run_for_user(user_id,
               now: DateTime.add(now, 3600, :second),
               source_bundle: source_bundle,
               llm_complete: llm_complete
             )

    assert_receive {:prompt, second_prompt}

    # The five never-checked todos sort ahead of the just-stamped forty.
    for todo <- left_out do
      assert second_prompt =~ todo.title
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

    assert %{checked: 2, completed: 2} =
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

    closed_owed_by_me = Todos.get_for_user(user_id, owed_by_me.id)
    assert closed_owed_by_me.status == "done"
    assert closed_owed_by_me.metadata["resolution_note"] =~ "Handled already"

    # Exactly one push: the owed_to_me answered close. owed_by_me stays silent.
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
      Process.sleep(:infinity)
    end

    llm_complete = fn prompt ->
      assert prompt =~ "source_health"
      assert prompt =~ "live source acquisition timed out"
      assert prompt =~ "\\\"status\\\":\\\"unavailable\\\""

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
end
