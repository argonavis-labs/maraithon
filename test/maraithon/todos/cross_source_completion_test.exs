defmodule Maraithon.Todos.CrossSourceCompletionTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ChiefOfStaff.SourceBundle
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

    llm_complete = fn prompt ->
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
               llm_complete: llm_complete
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
