defmodule Maraithon.Memory.RecallTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Memory
  alias Maraithon.Memory.Recall

  test "ranks subject matches above decayed equivalent memories" do
    user_id = "memory-recall-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    now = DateTime.utc_now()

    {:ok, decayed} =
      Memory.write(user_id, %{
        "kind" => "preference",
        "title" => "Charlie stale channel",
        "content" => "Charlie prefers Slack for quick updates.",
        "importance" => 80,
        "confidence" => 0.9,
        "decay_at" => DateTime.add(now, -60, :second),
        "metadata" => %{"person_id" => "charlie"}
      })

    {:ok, fresh} =
      Memory.write(user_id, %{
        "kind" => "preference",
        "title" => "Charlie current channel",
        "content" => "Charlie prefers email for quick updates.",
        "importance" => 80,
        "confidence" => 0.9,
        "decay_at" => DateTime.add(now, 86_400, :second),
        "metadata" => %{"person_id" => "charlie"}
      })

    assert {:ok, [first, second], metadata} =
             Recall.recall(user_id,
               query: "Charlie quick updates",
               person_id: "charlie",
               limit: 2,
               now: now
             )

    assert first.id == fresh.id
    assert second.id == decayed.id
    assert metadata.used_tokens > 0
  end

  test "enforces token budget while returning usable smaller memories" do
    user_id = "memory-recall-budget-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, long} =
      Memory.write(user_id, %{
        "title" => "Long launch context",
        "content" => String.duplicate("Launch context with many details. ", 80),
        "importance" => 100,
        "confidence" => 1.0
      })

    {:ok, short} =
      Memory.write(user_id, %{
        "title" => "Short launch context",
        "content" => "Launch needs a short operator note.",
        "importance" => 80,
        "confidence" => 0.9
      })

    assert {:ok, memories, metadata} =
             Recall.recall(user_id, query: "launch context", limit: 5, max_tokens: 80)

    ids = Enum.map(memories, & &1.id)
    assert short.id in ids
    refute long.id in ids
    assert metadata.dropped >= 1
  end
end
