defmodule Maraithon.LocalEmbeddingsTest do
  @moduledoc """
  Tests for the shared `Maraithon.LocalEmbeddings` write + semantic_search
  helpers. The mocked embedder (deterministic by trigrams + length) gives
  us repeatable similarity orderings without needing an OpenAI key.
  """

  use Maraithon.DataCase, async: false

  alias Maraithon.LLM.Embeddings
  alias Maraithon.LocalEmbeddings
  alias Maraithon.LocalNotes
  alias Maraithon.LocalNotes.LocalNote

  setup do
    # Force the deterministic mock provider for repeatable orderings.
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

  defp user_id, do: "le-#{System.unique_integer([:positive])}@example.com"
  defp device_id, do: Ecto.UUID.generate()

  defp ingest_note(user_id, device_id, title, body) do
    {:ok, _} =
      LocalNotes.ingest_batch(user_id, device_id, [
        %{
          "guid" => "n-#{System.unique_integer([:positive])}",
          "title" => title,
          "snippet" => title,
          "body" => body,
          "body_format" => "plain",
          "modified_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      ])

    Repo.one!(
      from n in LocalNote,
        where: n.user_id == ^user_id and n.device_id == ^device_id,
        order_by: [desc: n.inserted_at],
        limit: 1
    )
  end

  describe "source_hash/1" do
    test "is stable for the same text and changes when text changes" do
      assert LocalEmbeddings.source_hash("hello world") ==
               LocalEmbeddings.source_hash("hello world")

      refute LocalEmbeddings.source_hash("a") == LocalEmbeddings.source_hash("b")
    end

    test "nil / empty input returns nil" do
      assert LocalEmbeddings.source_hash(nil) == nil
      assert LocalEmbeddings.source_hash("") == nil
    end
  end

  describe "refresh/4" do
    test "empty text short-circuits to {:ok, :empty}" do
      uid = user_id()
      did = device_id()
      note = ingest_note(uid, did, "noop", "noop")

      assert {:ok, :empty} = LocalEmbeddings.refresh("local_notes", note.id, "  ")
    end

    test "missing record returns {:ok, :not_found}" do
      assert {:ok, :not_found} =
               LocalEmbeddings.refresh("local_notes", Ecto.UUID.generate(), "anything")
    end

    test "stores an embedding and records the source hash" do
      uid = user_id()
      did = device_id()
      note = ingest_note(uid, did, "title", "body")

      assert {:ok, :stored} =
               LocalEmbeddings.refresh("local_notes", note.id, "wedding plans")

      %{rows: [[hash, refreshed_at]]} =
        Repo.query!(
          "SELECT embedding_source_hash, embedding_refreshed_at FROM local_notes WHERE id = $1",
          [Ecto.UUID.dump!(note.id)]
        )

      assert is_binary(hash)
      assert refreshed_at
    end

    test "second refresh with the same text reports :unchanged" do
      uid = user_id()
      did = device_id()
      note = ingest_note(uid, did, "title", "body")

      assert {:ok, :stored} =
               LocalEmbeddings.refresh("local_notes", note.id, "wedding plans")

      assert {:ok, :unchanged} =
               LocalEmbeddings.refresh("local_notes", note.id, "wedding plans")
    end

    test "force: true recomputes even when the hash matches" do
      uid = user_id()
      did = device_id()
      note = ingest_note(uid, did, "title", "body")

      assert {:ok, :stored} =
               LocalEmbeddings.refresh("local_notes", note.id, "wedding plans")

      assert {:ok, :stored} =
               LocalEmbeddings.refresh("local_notes", note.id, "wedding plans", force: true)
    end
  end

  describe "semantic_search/4" do
    test "returns rows ordered by cosine similarity" do
      uid = user_id()
      did = device_id()
      target = ingest_note(uid, did, "wedding plans", "the wedding venue and seating chart")
      unrelated = ingest_note(uid, did, "groceries", "milk eggs bread")

      assert {:ok, :stored} =
               LocalEmbeddings.refresh("local_notes", target.id, "wedding plans")

      assert {:ok, :stored} =
               LocalEmbeddings.refresh("local_notes", unrelated.id, "groceries")

      {:ok, query_vec} = Embeddings.embed("wedding")

      [{first_id, _sim} | _] =
        LocalEmbeddings.semantic_search("local_notes", uid, query_vec, limit: 5)

      assert first_id == target.id
    end

    test "respects min_similarity" do
      uid = user_id()
      did = device_id()
      note = ingest_note(uid, did, "wedding plans", "wedding plans body")

      assert {:ok, :stored} =
               LocalEmbeddings.refresh("local_notes", note.id, "wedding plans")

      {:ok, query_vec} = Embeddings.embed("xyz totally unrelated")

      results =
        LocalEmbeddings.semantic_search("local_notes", uid, query_vec,
          limit: 5,
          min_similarity: 0.99
        )

      assert results == []
    end

    test "scopes by user_id (no cross-user leak)" do
      uid_a = user_id()
      uid_b = user_id()
      did = device_id()
      note_a = ingest_note(uid_a, did, "wedding plans", "body")

      assert {:ok, :stored} =
               LocalEmbeddings.refresh("local_notes", note_a.id, "wedding plans")

      {:ok, query_vec} = Embeddings.embed("wedding")
      results = LocalEmbeddings.semantic_search("local_notes", uid_b, query_vec, limit: 5)

      assert results == []
    end
  end

  describe "embedding_storage_available?/1" do
    test "returns true for migrated tables in the shared schema" do
      assert LocalEmbeddings.embedding_storage_available?("local_notes")
      assert LocalEmbeddings.embedding_storage_available?("local_messages")
      assert LocalEmbeddings.embedding_storage_available?("local_voice_memos")
      assert LocalEmbeddings.embedding_storage_available?("local_calendar_events")
      assert LocalEmbeddings.embedding_storage_available?("local_reminders")
      assert LocalEmbeddings.embedding_storage_available?("local_files")
    end

    test "returns false for an unmigrated/unknown table" do
      refute LocalEmbeddings.embedding_storage_available?("totally_made_up")
    end
  end
end
