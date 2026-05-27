defmodule Maraithon.Proactive.LocalPatternsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Insights
  alias Maraithon.LocalCalendar
  alias Maraithon.LocalFiles
  alias Maraithon.LocalMessages
  alias Maraithon.LocalNotes
  alias Maraithon.LocalReminders
  alias Maraithon.LocalVoiceMemos
  alias Maraithon.Proactive.LocalPatterns
  alias Maraithon.Crm.Person
  alias Maraithon.Repo
  alias Maraithon.Todos

  defp unique_user! do
    user_id = "lp-#{Ecto.UUID.generate()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    user_id
  end

  defp system_agent!(user_id) do
    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{"system" => "test_local_patterns"}
      })

    agent
  end

  defp seconds_ago(now, n), do: DateTime.add(now, -n, :second)

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(DateTime.truncate(dt, :second))

  defp emit_and_fetch(detector, user_id, agent_id, now) do
    LocalPatterns.run_detector(detector, user_id, agent_id, now)
    Insights.list_open_for_user(user_id, limit: 50)
  end

  describe "cold_thread detector" do
    test "emits when a regular thread has gone quiet for 14+ days" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()
      chat_key = "+14165550199"

      # 10 messages spread across days 16..25 ago — quiet for ~16 days
      # but high cadence in the 30-day window.
      messages =
        for i <- 0..9 do
          %{
            "guid" => "cold-#{i}",
            "local_id" => "p:#{i}",
            "sender_handle" => chat_key,
            "chat_handles" => [chat_key],
            "chat_display_name" => "Charlie",
            "is_from_me" => rem(i, 2) == 0,
            "text" => "msg #{i}",
            "sent_at" => iso(seconds_ago(now, (16 + i) * 86_400))
          }
        end

      {:ok, _} = LocalMessages.ingest_batch(user_id, device_id, messages)

      open = emit_and_fetch(:cold_thread, user_id, agent.id, now)
      assert [insight] = open
      assert insight.category == "important_fyi"
      assert insight.title == "Check in with Charlie"
      assert insight.summary =~ "Why this matters:"
      assert insight.summary =~ "you usually text Charlie regularly"
      assert insight.summary =~ "Last message from them:"
      assert insight.metadata["detector"] == "cold_thread"
      assert insight.metadata["chat_key"] == chat_key
      assert insight.metadata["message_count_30d"] >= 8
      assert insight.metadata["days_quiet"] >= 14
      assert insight.metadata["last_meaningful_message"] == "msg 1"
    end

    test "uses the last incoming message as context when the user has not replied" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()
      chat_key = "+14165550222"

      {:ok, _person} =
        %Person{user_id: user_id}
        |> Person.changeset(%{
          "display_name" => "Alex",
          "phone" => chat_key,
          "relationship" => "demo lead"
        })
        |> Repo.insert()

      messages = [
        %{
          "guid" => "reply-context-0",
          "sender_handle" => chat_key,
          "chat_handles" => [chat_key],
          "chat_display_name" => chat_key,
          "is_from_me" => true,
          "text" => "I'll send a few demo times shortly.",
          "sent_at" => iso(seconds_ago(now, 21 * 86_400))
        },
        %{
          "guid" => "reply-context-1",
          "sender_handle" => chat_key,
          "chat_handles" => [chat_key],
          "chat_display_name" => chat_key,
          "is_from_me" => false,
          "text" => "Are you still interested in the demo?",
          "sent_at" => iso(seconds_ago(now, 3 * 86_400))
        }
        | for i <- 2..8 do
            %{
              "guid" => "reply-context-#{i}",
              "sender_handle" => chat_key,
              "chat_handles" => [chat_key],
              "chat_display_name" => chat_key,
              "is_from_me" => false,
              "text" => "earlier cadence #{i}",
              "sent_at" => iso(seconds_ago(now, (22 + i) * 86_400))
            }
          end
      ]

      {:ok, _} = LocalMessages.ingest_batch(user_id, device_id, messages)

      open = emit_and_fetch(:cold_thread, user_id, agent.id, now)
      assert [insight] = open
      assert insight.title == "Reply to Alex"
      assert insight.summary =~ "Alex is marked demo lead"

      assert insight.summary =~
               "Last message from them: \"Are you still interested in the demo?\""

      assert insight.recommended_action == "Reply to Alex in the same thread."
      assert insight.metadata["chat_display_name"] == "Alex"
      assert insight.metadata["pending_reply"] == true

      assert insight.metadata["last_meaningful_message"] ==
               "Are you still interested in the demo?"

      [todo] = Todos.list_open_for_user(user_id)
      assert todo.title == "Reply to Alex"
      assert todo.notes =~ "Last message from them: \"Are you still interested in the demo?\""
    end

    test "does not emit for raw phone-only threads without a matched person" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()
      chat_key = "+14165550333"

      messages =
        for i <- 0..9 do
          %{
            "guid" => "raw-phone-#{i}",
            "sender_handle" => chat_key,
            "chat_handles" => [chat_key],
            "chat_display_name" => chat_key,
            "is_from_me" => rem(i, 2) == 0,
            "text" => "raw phone cadence #{i}",
            "sent_at" => iso(seconds_ago(now, (16 + i) * 86_400))
          }
        end

      {:ok, _} = LocalMessages.ingest_batch(user_id, device_id, messages)

      open = emit_and_fetch(:cold_thread, user_id, agent.id, now)
      assert open == []
    end

    test "does not emit when the thread is still active" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      messages =
        for i <- 0..9 do
          %{
            "guid" => "warm-#{i}",
            "local_id" => "p:#{i}",
            "sender_handle" => "+14165550111",
            "chat_handles" => ["+14165550111"],
            "is_from_me" => rem(i, 2) == 0,
            "text" => "msg #{i}",
            # latest 2 days ago — not cold
            "sent_at" => iso(seconds_ago(now, (2 + i) * 86_400))
          }
        end

      {:ok, _} = LocalMessages.ingest_batch(user_id, device_id, messages)

      open = emit_and_fetch(:cold_thread, user_id, agent.id, now)
      assert open == []
    end

    test "does not emit for low-cadence quiet threads" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      # Only 3 messages in last 30d — below the 8-msg cadence floor.
      messages =
        for i <- 0..2 do
          %{
            "guid" => "sparse-#{i}",
            "sender_handle" => "+14165550133",
            "chat_handles" => ["+14165550133"],
            "is_from_me" => false,
            "text" => "msg #{i}",
            "sent_at" => iso(seconds_ago(now, (16 + i) * 86_400))
          }
        end

      {:ok, _} = LocalMessages.ingest_batch(user_id, device_id, messages)

      open = emit_and_fetch(:cold_thread, user_id, agent.id, now)
      assert open == []
    end
  end

  describe "dropped_commitment detector" do
    test "emits for an overdue reminder whose title matches a recent message" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          %{
            "guid" => "msg-deck-1",
            "sender_handle" => "alex@example.com",
            "chat_handles" => ["alex@example.com"],
            "chat_display_name" => "Alex",
            "is_from_me" => false,
            "text" => "hey can you send the investor deck when you get a chance",
            "sent_at" => iso(seconds_ago(now, 2 * 86_400))
          }
        ])

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          %{
            "guid" => "rem-1",
            "title" => "Send investor deck to Alex",
            "due_at" => iso(seconds_ago(now, 1 * 86_400)),
            "is_completed" => false,
            "list_name" => "Work"
          }
        ])

      open = emit_and_fetch(:dropped_commitment, user_id, agent.id, now)
      assert [insight] = open
      assert insight.category == "commitment_unresolved"
      assert insight.metadata["detector"] == "dropped_commitment"
      assert insight.metadata["reminder_guid"] == "rem-1"
      assert insight.metadata["days_overdue"] >= 0
    end

    test "does not emit when the reminder doesn't match any message" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          %{
            "guid" => "unrelated",
            "sender_handle" => "bob@example.com",
            "chat_handles" => ["bob@example.com"],
            "is_from_me" => false,
            "text" => "see you Saturday at the cafe",
            "sent_at" => iso(seconds_ago(now, 2 * 86_400))
          }
        ])

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          %{
            "guid" => "rem-x",
            "title" => "Renew passport before trip",
            "due_at" => iso(seconds_ago(now, 1 * 86_400)),
            "is_completed" => false
          }
        ])

      open = emit_and_fetch(:dropped_commitment, user_id, agent.id, now)
      assert open == []
    end

    test "does not emit for reminders that aren't overdue yet" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          %{
            "guid" => "msg-deck-future",
            "sender_handle" => "alex@example.com",
            "chat_handles" => ["alex@example.com"],
            "is_from_me" => false,
            "text" => "send investor deck please",
            "sent_at" => iso(seconds_ago(now, 1 * 86_400))
          }
        ])

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          %{
            "guid" => "rem-future",
            "title" => "Send investor deck",
            # Due 2 days from now — not overdue
            "due_at" => iso(DateTime.add(now, 2 * 86_400, :second)),
            "is_completed" => false
          }
        ])

      open = emit_and_fetch(:dropped_commitment, user_id, agent.id, now)
      assert open == []
    end
  end

  describe "untranscribed_memo detector" do
    test "emits for a recent memo with no transcript" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          %{
            "guid" => "memo-1",
            "title" => "Thoughts on Q3 priorities",
            "duration_seconds" => 75,
            "created_at" => iso(seconds_ago(now, 6 * 3_600)),
            "transcript" => nil
          }
        ])

      open = emit_and_fetch(:untranscribed_memo, user_id, agent.id, now)
      assert [insight] = open
      assert insight.metadata["detector"] == "untranscribed_memo"
      assert insight.metadata["memo_guid"] == "memo-1"
    end

    test "does not emit when the memo already has a transcript" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          %{
            "guid" => "memo-2",
            "title" => "Thoughts on Q3 priorities",
            "duration_seconds" => 75,
            "created_at" => iso(seconds_ago(now, 6 * 3_600)),
            "transcript" => "Today I was thinking about Q3 priorities..."
          }
        ])

      open = emit_and_fetch(:untranscribed_memo, user_id, agent.id, now)
      assert open == []
    end
  end

  describe "note_follow_up detector" do
    test "emits for a recently edited note that contains a TODO marker" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          %{
            "guid" => "note-1",
            "title" => "Pitch outline",
            "snippet" => "Need to remember to follow up on hiring",
            "body" => "* TODO: send Slack to Charlie about hiring",
            "modified_at" => iso(seconds_ago(now, 4 * 3_600)),
            "created_at" => iso(seconds_ago(now, 10 * 3_600))
          }
        ])

      open = emit_and_fetch(:note_follow_up, user_id, agent.id, now)
      assert [insight] = open
      assert insight.metadata["detector"] == "note_follow_up"
      assert insight.metadata["note_guid"] == "note-1"
    end

    test "does not emit when the note has no follow-up marker" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalNotes.ingest_batch(user_id, device_id, [
          %{
            "guid" => "note-2",
            "title" => "Sushi list",
            "snippet" => "favorite places",
            "body" => "1. Akira. 2. Ten Sushi.",
            "modified_at" => iso(seconds_ago(now, 4 * 3_600))
          }
        ])

      open = emit_and_fetch(:note_follow_up, user_id, agent.id, now)
      assert open == []
    end
  end

  describe "calendar_conflict detector" do
    test "emits when two upcoming events overlap" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      first_start = DateTime.add(now, 2 * 86_400, :second)
      first_end = DateTime.add(first_start, 3_600, :second)
      second_start = DateTime.add(first_start, 1_800, :second)
      second_end = DateTime.add(second_start, 3_600, :second)

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          %{
            "guid" => "ev-1",
            "title" => "Board call",
            "start_at" => iso(first_start),
            "end_at" => iso(first_end),
            "attendee_emails" => ["a@example.com"]
          },
          %{
            "guid" => "ev-2",
            "title" => "1:1 with Sam",
            "start_at" => iso(second_start),
            "end_at" => iso(second_end),
            "attendee_emails" => ["sam@example.com"]
          }
        ])

      open = emit_and_fetch(:calendar_conflict, user_id, agent.id, now)
      assert [insight] = open
      assert insight.category == "event_important"
      assert insight.metadata["detector"] == "calendar_conflict"
      titles = [insight.metadata["first_title"], insight.metadata["second_title"]]
      assert "Board call" in titles
      assert "1:1 with Sam" in titles
    end

    test "does not emit when events don't overlap" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      first_start = DateTime.add(now, 2 * 86_400, :second)
      first_end = DateTime.add(first_start, 3_600, :second)
      second_start = DateTime.add(first_end, 3_600, :second)
      second_end = DateTime.add(second_start, 3_600, :second)

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          %{
            "guid" => "ev-3",
            "title" => "Lunch",
            "start_at" => iso(first_start),
            "end_at" => iso(first_end)
          },
          %{
            "guid" => "ev-4",
            "title" => "Walk",
            "start_at" => iso(second_start),
            "end_at" => iso(second_end)
          }
        ])

      open = emit_and_fetch(:calendar_conflict, user_id, agent.id, now)
      assert open == []
    end
  end

  describe "file_mention detector" do
    test "emits when a recent ~/Documents file is mentioned in iMessage" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          %{
            "guid" => "file-1",
            "path" => "~/Documents/work/series_b_deck_v3.pdf",
            "filename" => "series_b_deck_v3.pdf",
            "extension" => "pdf",
            "created_at" => iso(seconds_ago(now, 8 * 3_600)),
            "modified_at" => iso(seconds_ago(now, 8 * 3_600))
          }
        ])

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          %{
            "guid" => "msg-file-1",
            "sender_handle" => "carol@example.com",
            "chat_handles" => ["carol@example.com"],
            "chat_display_name" => "Carol",
            "is_from_me" => true,
            "text" => "Just finished series_b_deck_v3 — sending shortly",
            "sent_at" => iso(seconds_ago(now, 4 * 3_600))
          }
        ])

      open = emit_and_fetch(:file_mention, user_id, agent.id, now)
      assert [insight] = open
      assert insight.category == "commitment_unresolved"
      assert insight.metadata["detector"] == "file_mention"
      assert insight.metadata["file_guid"] == "file-1"
      assert insight.metadata["person"] == "Carol"
    end

    test "does not emit when the file is outside ~/Documents" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          %{
            "guid" => "file-2",
            "path" => "~/Downloads/random_thing.pdf",
            "filename" => "random_thing.pdf",
            "extension" => "pdf",
            "created_at" => iso(seconds_ago(now, 8 * 3_600))
          }
        ])

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          %{
            "guid" => "msg-file-2",
            "sender_handle" => "carol@example.com",
            "chat_handles" => ["carol@example.com"],
            "is_from_me" => true,
            "text" => "Sharing random_thing.pdf",
            "sent_at" => iso(seconds_ago(now, 4 * 3_600))
          }
        ])

      open = emit_and_fetch(:file_mention, user_id, agent.id, now)
      assert open == []
    end

    test "does not emit when no message references the filename" do
      user_id = unique_user!()
      agent = system_agent!(user_id)
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalFiles.ingest_batch(user_id, device_id, [
          %{
            "guid" => "file-3",
            "path" => "~/Documents/personal/budget_2026.xlsx",
            "filename" => "budget_2026.xlsx",
            "extension" => "xlsx",
            "created_at" => iso(seconds_ago(now, 8 * 3_600))
          }
        ])

      {:ok, _} =
        LocalMessages.ingest_batch(user_id, device_id, [
          %{
            "guid" => "msg-file-3",
            "sender_handle" => "dave@example.com",
            "chat_handles" => ["dave@example.com"],
            "is_from_me" => false,
            "text" => "lunch tomorrow?",
            "sent_at" => iso(seconds_ago(now, 4 * 3_600))
          }
        ])

      open = emit_and_fetch(:file_mention, user_id, agent.id, now)
      assert open == []
    end
  end

  describe "run_for_user/2" do
    test "creates and reuses the same system agent across runs" do
      user_id = unique_user!()
      now = DateTime.utc_now()

      {:ok, summary_1} = LocalPatterns.run_for_user(user_id, now: now)

      assert Map.keys(summary_1) |> Enum.sort() ==
               [
                 :calendar_conflict,
                 :cold_thread,
                 :dropped_commitment,
                 :file_mention,
                 :note_follow_up,
                 :untranscribed_memo
               ]

      agents_after_first =
        Agents.list_agents(user_id: user_id)
        |> Enum.filter(&(get_in(&1.config, ["system"]) == "proactive_local_patterns"))

      assert length(agents_after_first) == 1

      {:ok, _summary_2} = LocalPatterns.run_for_user(user_id, now: now)

      agents_after_second =
        Agents.list_agents(user_id: user_id)
        |> Enum.filter(&(get_in(&1.config, ["system"]) == "proactive_local_patterns"))

      assert length(agents_after_second) == 1
    end

    test "is idempotent within a day — same dedupe key, same row" do
      user_id = unique_user!()
      now = DateTime.utc_now()
      device_id = Ecto.UUID.generate()

      # Plant data that triggers untranscribed_memo, simplest detector.
      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          %{
            "guid" => "idemp-memo",
            "title" => "Idempotency check",
            "created_at" => iso(seconds_ago(now, 3_600)),
            "transcript" => nil
          }
        ])

      {:ok, _} = LocalPatterns.run_for_user(user_id, now: now)
      first_open = Insights.list_open_for_user(user_id, limit: 50)
      assert length(first_open) == 1
      first_id = hd(first_open).id

      {:ok, _} = LocalPatterns.run_for_user(user_id, now: now)
      second_open = Insights.list_open_for_user(user_id, limit: 50)
      assert length(second_open) == 1
      assert hd(second_open).id == first_id
    end
  end
end
