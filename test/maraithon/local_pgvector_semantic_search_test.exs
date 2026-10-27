defmodule Maraithon.LocalPgvectorSemanticSearchTest do
  @moduledoc """
  Per-context tests for the new vector-argument clauses of
  `semantic_search/3` on each `Maraithon.Local*` module. We use the
  deterministic mock embedder so the ordering is repeatable.
  """

  use Maraithon.DataCase, async: false

  alias Maraithon.LLM.Embeddings
  alias Maraithon.LocalCalendar
  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.LocalEmbeddings
  alias Maraithon.LocalFiles
  alias Maraithon.LocalFiles.LocalFile
  alias Maraithon.LocalMessages
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.LocalNotes
  alias Maraithon.LocalNotes.LocalNote
  alias Maraithon.LocalReminders
  alias Maraithon.LocalReminders.LocalReminder
  alias Maraithon.LocalVoiceMemos
  alias Maraithon.LocalVoiceMemos.LocalVoiceMemo

  setup do
    previous = Application.get_env(:maraithon, Maraithon.LLM.Embeddings)
    Application.put_env(:maraithon, Maraithon.LLM.Embeddings, provider: :mock)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:maraithon, Maraithon.LLM.Embeddings)
        value -> Application.put_env(:maraithon, Maraithon.LLM.Embeddings, value)
      end
    end)

    LocalEmbeddings.reset_storage_cache!()
    :ok
  end

  defp user_id, do: "ss-#{System.unique_integer([:positive])}@example.com"
  defp device_id, do: Ecto.UUID.generate()

  defp store_embedding(table, id, text) do
    assert {:ok, :stored} = LocalEmbeddings.refresh(table, id, text, force: true)
  end

  defp query_vec(text) do
    {:ok, vec} = Embeddings.embed(text)
    vec
  end

  describe "LocalMessages.semantic_search/3 (vector)" do
    test "orders messages by cosine similarity to query embedding" do
      uid = user_id()
      did = device_id()

      {:ok, _} =
        LocalMessages.ingest_batch(uid, did, [
          %{
            "guid" => "m1",
            "text" => "Let's talk about the wedding venue this weekend",
            "sender_handle" => "+1",
            "chat_handles" => ["+1"],
            "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          },
          %{
            "guid" => "m2",
            "text" => "Quick grocery list: milk eggs bread",
            "sender_handle" => "+1",
            "chat_handles" => ["+1"],
            "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ])

      [target, unrelated] =
        Repo.all(from m in LocalMessage, where: m.user_id == ^uid, order_by: m.guid)

      store_embedding("local_messages", target.id, target.text)
      store_embedding("local_messages", unrelated.id, unrelated.text)

      [{first, _} | _] = LocalMessages.semantic_search(uid, query_vec("wedding"), limit: 5)
      assert first.id == target.id
    end

    test "returns [] when no rows have embeddings" do
      uid = user_id()
      did = device_id()

      {:ok, _} =
        LocalMessages.ingest_batch(uid, did, [
          %{
            "guid" => "m1",
            "text" => "Hello",
            "sender_handle" => "+1",
            "chat_handles" => ["+1"],
            "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ])

      # No call to store_embedding, so no rows have embeddings.
      assert LocalMessages.semantic_search(uid, query_vec("wedding"), limit: 5) == []
    end
  end

  describe "LocalNotes.semantic_search/3 (vector)" do
    test "title-similar note ranks ahead of unrelated note" do
      uid = user_id()
      did = device_id()

      {:ok, _} =
        LocalNotes.ingest_batch(uid, did, [
          %{
            "guid" => "n-wed",
            "title" => "wedding plans",
            "body" => "seating chart and venue",
            "modified_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          },
          %{
            "guid" => "n-other",
            "title" => "grocery list",
            "body" => "milk eggs bread",
            "modified_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ])

      target = LocalNotes.get_by_guid(uid, "n-wed")
      other = LocalNotes.get_by_guid(uid, "n-other")
      store_embedding("local_notes", target.id, "wedding plans seating venue")
      store_embedding("local_notes", other.id, "grocery list milk eggs bread")

      [{first, _} | _] = LocalNotes.semantic_search(uid, query_vec("wedding"), limit: 5)
      assert first.guid == "n-wed"
    end
  end

  describe "LocalVoiceMemos.semantic_search/3 (vector)" do
    test "transcript match wins over unrelated memo" do
      uid = user_id()
      did = device_id()
      created_at = DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(uid, did, [
          %{
            "guid" => "vm-wed",
            "title" => "wedding speech",
            "transcript" => "wedding speech notes for the reception",
            "created_at" => created_at
          },
          %{
            "guid" => "vm-other",
            "title" => "random thought",
            "transcript" => "thinking about lunch options",
            "created_at" => created_at
          }
        ])

      target = LocalVoiceMemos.get_by_guid(uid, "vm-wed")
      other = LocalVoiceMemos.get_by_guid(uid, "vm-other")
      store_embedding("local_voice_memos", target.id, "wedding speech reception")
      store_embedding("local_voice_memos", other.id, "lunch options")

      [{first, _} | _] = LocalVoiceMemos.semantic_search(uid, query_vec("wedding"), limit: 5)
      assert first.guid == "vm-wed"
    end
  end

  describe "LocalCalendar.semantic_search/3 (vector)" do
    test "title/notes match wins over unrelated event" do
      uid = user_id()
      did = device_id()
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok, _} =
        LocalCalendar.ingest_batch(uid, did, [
          %{
            "guid" => "evt-wed",
            "title" => "wedding tasting",
            "notes" => "menu tasting at the venue",
            "location" => "venue",
            "start_at" => now,
            "end_at" => now
          },
          %{
            "guid" => "evt-other",
            "title" => "dentist appointment",
            "notes" => "cleaning",
            "location" => "office",
            "start_at" => now,
            "end_at" => now
          }
        ])

      target = LocalCalendar.get_by_guid(uid, "evt-wed")
      other = LocalCalendar.get_by_guid(uid, "evt-other")
      store_embedding("local_calendar_events", target.id, "wedding tasting venue")
      store_embedding("local_calendar_events", other.id, "dentist cleaning")

      [{first, _} | _] = LocalCalendar.semantic_search(uid, query_vec("wedding"), limit: 5)
      assert first.guid == "evt-wed"
    end
  end

  describe "LocalReminders.semantic_search/3 (vector)" do
    test "title match wins over unrelated reminder" do
      uid = user_id()
      did = device_id()
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok, _} =
        LocalReminders.ingest_batch(uid, did, [
          %{
            "guid" => "r-wed",
            "title" => "wedding venue deposit",
            "notes" => "pay before friday",
            "modified_at" => now,
            "created_at" => now
          },
          %{
            "guid" => "r-other",
            "title" => "pickup laundry",
            "notes" => "from cleaners",
            "modified_at" => now,
            "created_at" => now
          }
        ])

      target = LocalReminders.get_by_guid(uid, "r-wed")
      other = LocalReminders.get_by_guid(uid, "r-other")
      store_embedding("local_reminders", target.id, "wedding venue deposit")
      store_embedding("local_reminders", other.id, "pickup laundry cleaners")

      [{first, _} | _] = LocalReminders.semantic_search(uid, query_vec("wedding"), limit: 5)
      assert first.guid == "r-wed"
    end
  end

  describe "LocalFiles.semantic_search/3 (vector)" do
    test "filename + text_content match wins over unrelated file" do
      uid = user_id()
      did = device_id()
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok, _} =
        LocalFiles.ingest_batch(uid, did, [
          %{
            "guid" => "f-wed",
            "filename" => "wedding-plans.md",
            "path" => "~/Documents/wedding-plans.md",
            "extension" => "md",
            "text_content" => "Wedding plans seating chart venue notes",
            "modified_at" => now,
            "created_at" => now
          },
          %{
            "guid" => "f-other",
            "filename" => "grocery-list.txt",
            "path" => "~/Desktop/grocery-list.txt",
            "extension" => "txt",
            "text_content" => "milk eggs bread",
            "modified_at" => now,
            "created_at" => now
          }
        ])

      target = LocalFiles.get_by_guid(uid, "f-wed")
      other = LocalFiles.get_by_guid(uid, "f-other")
      store_embedding("local_files", target.id, "wedding plans seating venue")
      store_embedding("local_files", other.id, "grocery list milk eggs bread")

      [{first, _} | _] = LocalFiles.semantic_search(uid, query_vec("wedding"), limit: 5)
      assert first.guid == "f-wed"
    end

    test "returns [] when no rows have embeddings" do
      uid = user_id()
      did = device_id()

      {:ok, _} =
        LocalFiles.ingest_batch(uid, did, [
          %{
            "guid" => "f-nope",
            "filename" => "a.txt",
            "path" => "~/Documents/a.txt",
            "extension" => "txt",
            "text_content" => "Hello",
            "modified_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ])

      assert LocalFiles.semantic_search(uid, query_vec("anything"), limit: 5) == []
    end
  end

  describe "ingest_batch/3 enqueues embed jobs" do
    test "local_messages.ingest_batch enqueues a job per inserted row" do
      uid = ensure_user()
      did = device_id()

      pending_before =
        Repo.aggregate(
          from(j in Maraithon.Runtime.BackgroundJob,
            where: j.job_type == "local_messages_embed" and j.user_id == ^uid
          ),
          :count,
          :id
        )

      {:ok, _} =
        LocalMessages.ingest_batch(uid, did, [
          %{
            "guid" => "mb-1",
            "text" => "hi",
            "sender_handle" => "+1",
            "chat_handles" => ["+1"],
            "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ])

      pending_after =
        Repo.aggregate(
          from(j in Maraithon.Runtime.BackgroundJob,
            where: j.job_type == "local_messages_embed" and j.user_id == ^uid
          ),
          :count,
          :id
        )

      assert pending_after == pending_before + 1
    end

    test "local_notes.ingest_batch enqueues a job per inserted row" do
      uid = ensure_user()
      did = device_id()

      before_count =
        Repo.aggregate(
          from(j in Maraithon.Runtime.BackgroundJob,
            where: j.job_type == "local_notes_embed" and j.user_id == ^uid
          ),
          :count,
          :id
        )

      {:ok, _} =
        LocalNotes.ingest_batch(uid, did, [
          %{
            "guid" => "nb-1",
            "title" => "a note",
            "body" => "body",
            "modified_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ])

      after_count =
        Repo.aggregate(
          from(j in Maraithon.Runtime.BackgroundJob,
            where: j.job_type == "local_notes_embed" and j.user_id == ^uid
          ),
          :count,
          :id
        )

      assert after_count == before_count + 1
    end

    test "duplicate ingest does not enqueue a second job" do
      uid = ensure_user()
      did = device_id()

      payload = %{
        "guid" => "dup-1",
        "title" => "dup",
        "body" => "body",
        "modified_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      {:ok, _} = LocalNotes.ingest_batch(uid, did, [payload])

      before_count =
        Repo.aggregate(
          from(j in Maraithon.Runtime.BackgroundJob,
            where: j.job_type == "local_notes_embed" and j.user_id == ^uid
          ),
          :count,
          :id
        )

      # Same guid: dedupe on unique constraint, returning 0 inserted rows.
      {:ok, %{accepted: 0, duplicate: 1}} = LocalNotes.ingest_batch(uid, did, [payload])

      after_count =
        Repo.aggregate(
          from(j in Maraithon.Runtime.BackgroundJob,
            where: j.job_type == "local_notes_embed" and j.user_id == ^uid
          ),
          :count,
          :id
        )

      assert after_count == before_count
    end
  end

  defp ensure_user do
    email = user_id()
    {:ok, _user} = Maraithon.Accounts.get_or_create_user_by_email(email)
    email
  end

  describe "EmbedJob.run/1" do
    test "local_notes embed job stores the embedding" do
      uid = user_id()
      did = device_id()
      note = ingest_local_note(uid, did, "title", "body")

      assert {:ok, %{status: :stored}} =
               Maraithon.LocalNotes.EmbedJob.run(note.id)

      %{rows: [[hash]]} =
        Repo.query!("SELECT embedding_source_hash FROM local_notes WHERE id = $1", [
          Ecto.UUID.dump!(note.id)
        ])

      assert is_binary(hash)
    end

    test "missing record reports {:ok, %{status: :missing}}" do
      assert {:ok, %{status: "missing"}} =
               Maraithon.LocalNotes.EmbedJob.run(Ecto.UUID.generate())
    end

    test "local_voice_memos embed_job picks transcript over title" do
      uid = user_id()
      did = device_id()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(uid, did, [
          %{
            "guid" => "vm-source",
            "title" => "fallback title",
            "transcript" => "preferred transcript body",
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ])

      memo = LocalVoiceMemos.get_by_guid(uid, "vm-source")

      assert Maraithon.LocalVoiceMemos.EmbedJob.source_text(memo) ==
               "preferred transcript body"
    end

    test "local_voice_memos embed_job falls back to title when transcript is missing" do
      memo = %LocalVoiceMemo{title: "only-title"}
      assert Maraithon.LocalVoiceMemos.EmbedJob.source_text(memo) == "only-title"
    end

    test "local_voice_memos embed_job returns nil when both fields are blank" do
      memo = %LocalVoiceMemo{}
      assert Maraithon.LocalVoiceMemos.EmbedJob.source_text(memo) == nil
    end

    test "local_messages embed_job ignores blank text" do
      assert Maraithon.LocalMessages.EmbedJob.source_text(%LocalMessage{}) == nil
    end

    test "local_calendar_events embed_job joins title + notes + location" do
      event = %LocalEvent{title: "wedding tasting", notes: "menu", location: "venue"}

      text = Maraithon.LocalCalendar.EmbedJob.source_text(event)
      assert text =~ "wedding tasting"
      assert text =~ "menu"
      assert text =~ "venue"
    end

    test "local_reminders embed_job joins title + notes" do
      reminder = %LocalReminder{title: "venue deposit", notes: "due friday"}
      text = Maraithon.LocalReminders.EmbedJob.source_text(reminder)
      assert text =~ "venue deposit"
      assert text =~ "due friday"
    end

    test "local_files embed_job joins filename + path + text_content (truncated)" do
      file = %LocalFile{
        filename: "wedding-plans.md",
        path: "~/Documents/wedding-plans.md",
        text_content: String.duplicate("a", 10_000)
      }

      text = Maraithon.LocalFiles.EmbedJob.source_text(file)
      assert text =~ "wedding-plans.md"
      assert text =~ "~/Documents/wedding-plans.md"
      # Cap is 4000 chars on text portion; combined string stays well under
      # the OpenAI 8K-token soft cap.
      assert String.length(text) < 5_000
    end
  end

  defp ingest_local_note(uid, did, title, body) do
    {:ok, _} =
      LocalNotes.ingest_batch(uid, did, [
        %{
          "guid" => "n-" <> Integer.to_string(System.unique_integer([:positive])),
          "title" => title,
          "body" => body,
          "snippet" => title,
          "modified_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      ])

    Repo.one!(
      from n in LocalNote,
        where: n.user_id == ^uid and n.device_id == ^did,
        order_by: [desc: n.inserted_at],
        limit: 1
    )
  end
end
