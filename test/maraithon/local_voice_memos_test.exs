defmodule Maraithon.LocalVoiceMemosTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.LocalVoiceMemos
  alias Maraithon.LocalVoiceMemos.LocalVoiceMemo
  alias Maraithon.Repo

  defp sample_memo(guid, overrides \\ %{}) do
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

  defp memos_for(user_id, device_id) do
    Repo.all(
      from memo in LocalVoiceMemo,
        where: memo.user_id == ^user_id and memo.device_id == ^device_id
    )
  end

  defp memo_count(user_id, device_id) do
    Repo.aggregate(
      from(memo in LocalVoiceMemo,
        where: memo.user_id == ^user_id and memo.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  describe "ingest_batch/3" do
    test "inserts a fresh batch and reports accepted counts" do
      user_id = "vm-ingest-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      memos =
        for i <- 1..3 do
          sample_memo("guid-#{i}", %{"title" => "memo #{i}"})
        end

      {:ok, %{accepted: 3, duplicate: 0, invalid: 0}} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, memos)

      stored = memos_for(user_id, device_id)
      assert length(stored) == 3
      assert Enum.all?(stored, &(&1.user_id == user_id))
      assert Enum.all?(stored, &(&1.device_id == device_id))
      assert Enum.all?(stored, &(&1.title in ["memo 1", "memo 2", "memo 3"]))
    end

    test "dedupes via the unique constraint on re-send" do
      user_id = "vm-dedupe-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      memos = [sample_memo("g-a"), sample_memo("g-b")]

      {:ok, %{accepted: 2, duplicate: 0}} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, memos)

      {:ok, %{accepted: 0, duplicate: 2}} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, memos)

      assert memo_count(user_id, device_id) == 2
    end

    test "applies the default source when omitted" do
      user_id = "vm-source-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g1") |> Map.delete("source")
        ])

      [stored] = memos_for(user_id, device_id)
      assert stored.source == "voice_memos"
    end

    test "tolerates nil titles (Voice Memos with generated names)" do
      user_id = "vm-nil-title-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 1}} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g1", %{"title" => nil})
        ])

      [stored] = memos_for(user_id, device_id)
      assert is_nil(stored.title)
    end
  end

  describe "recent_for_user/2" do
    test "returns memos newest created first" do
      user_id = "vm-recent-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g1", %{
            "created_at" => "2026-05-10T10:00:00Z",
            "title" => "older"
          }),
          sample_memo("g2", %{
            "created_at" => "2026-05-10T12:00:00Z",
            "title" => "newer"
          })
        ])

      [first, second] = LocalVoiceMemos.recent_for_user(user_id)
      assert first.title == "newer"
      assert second.title == "older"
    end
  end

  describe "search/3" do
    test "matches substring on title and snippet" do
      user_id = "vm-search-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g1", %{
            "title" => "Morning rant",
            "snippet" => "talking about coffee"
          }),
          sample_memo("g2", %{
            "title" => "Standup",
            "snippet" => "team blockers"
          })
        ])

      results = LocalVoiceMemos.search(user_id, "blockers")
      assert length(results) == 1
      assert hd(results).title == "Standup"

      results_case = LocalVoiceMemos.search(user_id, "MORNING")
      assert length(results_case) == 1
    end
  end

  describe "purge_device/2" do
    test "removes all rows for the (user, device) pair" do
      user_id = "vm-purge-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalVoiceMemos.ingest_batch(user_id, device_id, [
          sample_memo("g1"),
          sample_memo("g2")
        ])

      assert memo_count(user_id, device_id) == 2

      {:ok, %{deleted: 2}} = LocalVoiceMemos.purge_device(user_id, device_id)

      assert memo_count(user_id, device_id) == 0
    end
  end
end
