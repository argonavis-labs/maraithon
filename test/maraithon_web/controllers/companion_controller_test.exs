defmodule MaraithonWeb.CompanionControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Companion.Devices
  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.LocalFiles.LocalFile
  alias Maraithon.LocalMessages
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.LocalNotes.LocalNote
  alias Maraithon.LocalReminders.LocalReminder
  alias Maraithon.LocalVoiceMemos.LocalVoiceMemo
  alias Maraithon.Repo

  import Ecto.Query

  defp pair_device(email \\ nil) do
    email = email || "companion-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    device_id = Ecto.UUID.generate()

    {:ok, %{device: device, token: token}} =
      Devices.register(user.id, device_id, device_name: "Kent's Mac")

    %{user: user, device: device, token: token}
  end

  defp sample_message(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "p:1",
        "guid" => guid,
        "service" => "iMessage",
        "is_from_me" => false,
        "sender_handle" => "+14165550199",
        "chat_handles" => ["+14165550199"],
        "chat_style" => "im",
        "text" => "Coffee tomorrow?",
        "sent_at" => "2026-05-10T13:14:22Z",
        "has_attachments" => false,
        "attachments" => []
      },
      overrides
    )
  end

  defp message_count(user_id, device_id) do
    Repo.aggregate(
      from(message in LocalMessage,
        where: message.user_id == ^user_id and message.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  defp note_count(user_id, device_id) do
    Repo.aggregate(
      from(note in LocalNote,
        where: note.user_id == ^user_id and note.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  defp voice_memo_count(user_id, device_id) do
    Repo.aggregate(
      from(memo in LocalVoiceMemo,
        where: memo.user_id == ^user_id and memo.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  defp reminder_count(user_id, device_id) do
    Repo.aggregate(
      from(reminder in LocalReminder,
        where: reminder.user_id == ^user_id and reminder.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  defp sample_reminder(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "r:1",
        "guid" => guid,
        "title" => "Buy milk",
        "list_name" => "Personal",
        "priority" => 0,
        "due_at" => "2026-05-12T10:00:00Z",
        "is_completed" => false,
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp sample_note(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "n:1",
        "guid" => guid,
        "title" => "Grocery list",
        "snippet" => "Milk, eggs, bread",
        "folder" => "Personal",
        "is_pinned" => false,
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp sample_voice_memo(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "v:1",
        "guid" => guid,
        "title" => "Standup recap",
        "snippet" => "transcription excerpt",
        "duration_seconds" => 64,
        "file_size_bytes" => 102_400,
        "created_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp file_count(user_id, device_id) do
    Repo.aggregate(
      from(file in LocalFile,
        where: file.user_id == ^user_id and file.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  defp sample_local_file(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "~/Documents/Projects/notes.md",
        "guid" => guid,
        "path" => "~/Documents/Projects/notes.md",
        "filename" => "notes.md",
        "extension" => "md",
        "mime_type" => "text/markdown",
        "byte_size" => 4823,
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  describe "POST /api/v1/companion/messages" do
    test "401 without bearer token", %{conn: conn} do
      conn = post(conn, "/api/v1/companion/messages", %{messages: []})
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "401 for revoked device", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()
      {:ok, _} = Devices.revoke(user.id, device.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/messages", %{messages: []})

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "200 happy path: inserts messages and reports counts", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/messages", %{
          "source" => "imessage",
          "messages" => [sample_message("g1"), sample_message("g2")]
        })

      body = json_response(conn, 200)
      assert body["accepted"] == 2
      assert body["duplicate"] == 0
      assert message_count(user.id, device.device_id) == 2
    end

    test "dedupes on the second send", %{conn: conn} do
      %{token: token} = pair_device()
      messages = [sample_message("g1"), sample_message("g2")]

      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/messages", %{"messages" => messages})

      assert json_response(conn1, 200)["accepted"] == 2

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/messages", %{"messages" => messages})

      body = json_response(conn2, 200)
      assert body["accepted"] == 0
      assert body["duplicate"] == 2
    end

    test "400 when messages is missing", %{conn: conn} do
      %{token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/messages", %{})

      assert json_response(conn, 400)["error"] =~ "messages"
    end
  end

  describe "GET /api/v1/companion/whoami" do
    test "returns email + device metadata", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/companion/whoami")

      body = json_response(conn, 200)
      assert body["email"] == user.email
      assert body["device_name"] == device.device_name
      assert body["device_id"] == device.device_id
    end

    test "401 without token", %{conn: conn} do
      conn = get(conn, "/api/v1/companion/whoami")
      assert json_response(conn, 401)
    end
  end

  describe "DELETE /api/v1/companion/devices/:id/messages" do
    test "purges all messages for the device", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      {:ok, _} =
        LocalMessages.ingest_batch(user.id, device.device_id, [
          sample_message("g1"),
          sample_message("g2")
        ])

      assert message_count(user.id, device.device_id) == 2

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/api/v1/companion/devices/#{device.id}/messages")

      body = json_response(conn, 200)
      assert body["deleted"] == 2
      assert message_count(user.id, device.device_id) == 0
    end
  end

  describe "POST /api/v1/companion/notes" do
    test "401 without bearer token", %{conn: conn} do
      conn = post(conn, "/api/v1/companion/notes", %{notes: []})
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "200 happy path: inserts notes and reports counts", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/notes", %{
          "source" => "notes",
          "notes" => [sample_note("n1"), sample_note("n2")]
        })

      body = json_response(conn, 200)
      assert body["accepted"] == 2
      assert body["duplicate"] == 0
      assert body["invalid"] == 0
      assert note_count(user.id, device.device_id) == 2
    end

    test "dedupes on the second send", %{conn: conn} do
      %{token: token} = pair_device()
      notes = [sample_note("n1"), sample_note("n2")]

      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/notes", %{"notes" => notes})

      assert json_response(conn1, 200)["accepted"] == 2

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/notes", %{"notes" => notes})

      body = json_response(conn2, 200)
      assert body["accepted"] == 0
      assert body["duplicate"] == 2
    end

    test "400 when notes array is missing", %{conn: conn} do
      %{token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/notes", %{})

      assert json_response(conn, 400)["error"] =~ "notes"
    end

    test "persists body and body_format end-to-end", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()
      body = "Line one.\nLine two."

      note =
        sample_note("nb1", %{
          "body" => body,
          "body_format" => "plain"
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/notes", %{"notes" => [note]})

      assert json_response(conn, 200)["accepted"] == 1

      stored =
        Repo.one(
          from n in LocalNote,
            where: n.user_id == ^user.id and n.device_id == ^device.device_id
        )

      assert stored.body == body
      assert stored.body_format == "plain"
    end
  end

  describe "POST /api/v1/companion/voice-memos" do
    test "401 without bearer token", %{conn: conn} do
      conn = post(conn, "/api/v1/companion/voice-memos", %{voice_memos: []})
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "200 happy path: inserts voice memos and reports counts", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/voice-memos", %{
          "source" => "voice_memos",
          "voice_memos" => [sample_voice_memo("v1"), sample_voice_memo("v2")]
        })

      body = json_response(conn, 200)
      assert body["accepted"] == 2
      assert body["duplicate"] == 0
      assert body["invalid"] == 0
      assert voice_memo_count(user.id, device.device_id) == 2
    end

    test "dedupes on the second send", %{conn: conn} do
      %{token: token} = pair_device()
      memos = [sample_voice_memo("v1"), sample_voice_memo("v2")]

      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/voice-memos", %{"voice_memos" => memos})

      assert json_response(conn1, 200)["accepted"] == 2

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/voice-memos", %{"voice_memos" => memos})

      body = json_response(conn2, 200)
      assert body["accepted"] == 0
      assert body["duplicate"] == 2
    end

    test "400 when voice_memos array is missing", %{conn: conn} do
      %{token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/voice-memos", %{})

      assert json_response(conn, 400)["error"] =~ "voice_memos"
    end

    test "ingests base64 audio + transcript fields end-to-end", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      raw = :crypto.strong_rand_bytes(1024)
      b64 = Base.encode64(raw)

      memo =
        sample_voice_memo("v-audio", %{
          "audio_bytes" => b64,
          "audio_mime" => "audio/m4a",
          "transcript" => "this is the on-device transcript",
          "transcript_engine" => "sf_speech",
          "transcript_lang" => "en-US"
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/voice-memos", %{"voice_memos" => [memo]})

      body = json_response(conn, 200)
      assert body["accepted"] == 1

      [stored] =
        Repo.all(
          from m in LocalVoiceMemo,
            where: m.user_id == ^user.id and m.device_id == ^device.device_id
        )

      assert stored.audio_bytes == raw
      assert stored.transcript == "this is the on-device transcript"
      assert stored.transcript_engine == "sf_speech"
      assert stored.audio_truncated == false
    end
  end

  describe "POST /api/v1/companion/reminders" do
    test "401 without bearer token", %{conn: conn} do
      conn = post(conn, "/api/v1/companion/reminders", %{reminders: []})
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "200 happy path: inserts reminders and reports counts", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/reminders", %{
          "source" => "reminders",
          "reminders" => [sample_reminder("r1"), sample_reminder("r2")]
        })

      body = json_response(conn, 200)
      assert body["accepted"] == 2
      assert body["invalid"] == 0
      assert reminder_count(user.id, device.device_id) == 2
    end

    test "upsert on the second send (no duplicate row)", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()
      payload = [sample_reminder("r1"), sample_reminder("r2")]

      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/reminders", %{"reminders" => payload})

      assert json_response(conn1, 200)["accepted"] == 2

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/reminders", %{"reminders" => payload})

      assert json_response(conn2, 200)["invalid"] == 0
      # Whether the second send reports under accepted or duplicate is an
      # implementation detail of `on_conflict :replace`; what matters is
      # that the row count stays at 2.
      assert reminder_count(user.id, device.device_id) == 2
    end

    test "re-send updates mutable fields end-to-end", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      r1 = sample_reminder("r-flip", %{"title" => "Pay rent", "is_completed" => false})

      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/reminders", %{"reminders" => [r1]})

      assert json_response(conn1, 200)

      r1_done =
        sample_reminder("r-flip", %{
          "title" => "Pay rent",
          "is_completed" => true,
          "completed_at" => "2026-05-10T14:00:00Z"
        })

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/reminders", %{"reminders" => [r1_done]})

      assert json_response(conn2, 200)

      [stored] =
        Repo.all(
          from r in LocalReminder,
            where: r.user_id == ^user.id and r.device_id == ^device.device_id
        )

      assert stored.is_completed == true
      assert %DateTime{} = stored.completed_at
    end

    test "400 when reminders array is missing", %{conn: conn} do
      %{token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/reminders", %{})

      assert json_response(conn, 400)["error"] =~ "reminders"
    end
  end

  describe "POST /api/v1/companion/calendar-events" do
    defp sample_calendar_event(guid, overrides \\ %{}) do
      Map.merge(
        %{
          "local_id" => "evt:#{guid}",
          "guid" => guid,
          "calendar_name" => "Home",
          "calendar_color" => "#ff8800",
          "title" => "Coffee with Charlie",
          "notes" => "Q3 plan",
          "location" => "Java Hut",
          "start_at" => "2026-05-12T15:00:00Z",
          "end_at" => "2026-05-12T15:30:00Z",
          "is_all_day" => false,
          "is_recurring" => false,
          "organizer_email" => "kent@example.com",
          "attendees_count" => 2,
          "attendee_emails" => ["charlie@example.com", "kent@example.com"],
          "created_at" => "2026-05-09T08:00:00Z",
          "modified_at" => "2026-05-10T13:14:22Z"
        },
        overrides
      )
    end

    defp calendar_event_count(user_id, device_id) do
      Repo.aggregate(
        from(event in LocalEvent,
          where: event.user_id == ^user_id and event.device_id == ^device_id
        ),
        :count,
        :id
      )
    end

    test "401 without bearer token", %{conn: conn} do
      conn = post(conn, "/api/v1/companion/calendar-events", %{calendar_events: []})
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "200 happy path: inserts events and reports counts", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/calendar-events", %{
          "source" => "calendar",
          "calendar_events" => [
            sample_calendar_event("c1"),
            sample_calendar_event("c2", %{"title" => "Standup"})
          ]
        })

      body = json_response(conn, 200)
      assert body["accepted"] == 2
      assert body["duplicate"] == 0
      assert body["invalid"] == 0
      assert calendar_event_count(user.id, device.device_id) == 2
    end

    test "dedupes on the second send", %{conn: conn} do
      %{token: token} = pair_device()
      events = [sample_calendar_event("c1"), sample_calendar_event("c2")]

      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/calendar-events", %{"calendar_events" => events})

      assert json_response(conn1, 200)["accepted"] == 2

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/calendar-events", %{"calendar_events" => events})

      body = json_response(conn2, 200)
      assert body["accepted"] == 0
      assert body["duplicate"] == 2
    end

    test "400 when calendar_events array is missing", %{conn: conn} do
      %{token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/calendar-events", %{})

      assert json_response(conn, 400)["error"] =~ "calendar_events"
    end
  end

  describe "POST /api/v1/companion/files" do
    test "401 without bearer token", %{conn: conn} do
      conn = post(conn, "/api/v1/companion/files", %{files: []})
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "200 happy path: inserts files and reports counts", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/files", %{
          "source" => "files",
          "files" => [sample_local_file("f1"), sample_local_file("f2")]
        })

      body = json_response(conn, 200)
      assert body["accepted"] == 2
      assert body["duplicate"] == 0
      assert body["invalid"] == 0
      assert file_count(user.id, device.device_id) == 2
    end

    test "dedupes on the second send", %{conn: conn} do
      %{token: token} = pair_device()
      files = [sample_local_file("f1"), sample_local_file("f2")]

      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/files", %{"files" => files})

      assert json_response(conn1, 200)["accepted"] == 2

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/files", %{"files" => files})

      body = json_response(conn2, 200)
      assert body["accepted"] == 0
      assert body["duplicate"] == 2
    end

    test "400 when files array is missing", %{conn: conn} do
      %{token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/files", %{})

      assert json_response(conn, 400)["error"] =~ "files"
    end

    test "ingests base64 text_content end-to-end", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      body = "PDF body content extracted into plain text."
      b64 = Base.encode64(body)

      file =
        sample_local_file("f-pdf", %{
          "filename" => "spec.pdf",
          "extension" => "pdf",
          "mime_type" => "application/pdf",
          "text_content_base64" => b64
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/files", %{"files" => [file]})

      response = json_response(conn, 200)
      assert response["accepted"] == 1

      [stored] =
        Repo.all(
          from f in LocalFile,
            where: f.user_id == ^user.id and f.device_id == ^device.device_id
        )

      assert stored.text_content == body
      assert stored.text_truncated == false
      assert stored.extension == "pdf"
    end

    test "400 when batch exceeds the 200-row cap", %{conn: conn} do
      %{token: token} = pair_device()

      files =
        for i <- 1..201 do
          sample_local_file("f-#{i}")
        end

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/files", %{"files" => files})

      assert json_response(conn, 400)["error"] =~ "200"
    end
  end
end
