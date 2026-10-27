defmodule Maraithon.Delegations.SourcesTest do
  use ExUnit.Case, async: true
  alias Maraithon.Delegations.Sources

  setup do
    %{
      message: %{
        message_id: "aabb11",
        thread_id: "abcdef",
        from: "Kent <kent.fenwick@gmail.com>",
        to: "Kent <kent@runner.now>",
        cc: "",
        subject: "[Maraithon eval] A question",
        internet_message_id: "<kent-pair-1@example.invalid>",
        text_body: "The answer is indigo.",
        labels: ["INBOX"],
        internal_date: ~U[2026-09-15 14:00:00Z]
      }
    }
  end

  test "keeps real source IDs, participants and text in chronological order", %{message: m} do
    next = %{
      m
      | message_id: "aabb22",
        text_body: "Confirmed",
        internal_date: DateTime.add(m.internal_date, 60)
    }

    assert {:ok, snapshot} = Sources.snapshot([next, m], 42, "abcdef")
    assert snapshot["account_id"] == 42
    assert snapshot["complete"]
    assert Enum.map(snapshot["messages"], & &1["message_id"]) == ["aabb11", "aabb22"]
    assert hd(snapshot["messages"])["text_body"] == "The answer is indigo."
  end

  test "drafts never become evidence of a commitment", %{message: m} do
    draft = %{m | message_id: "aa33", labels: ["DRAFT"], text_body: "I promise to do it."}
    assert {:ok, snapshot} = Sources.snapshot([m, draft], 42, "abcdef")
    assert length(snapshot["messages"]) == 1
    assert {:error, :source_gap} = Sources.snapshot([draft], 42, "abcdef")
  end

  test "missing bodies, ambiguous senders and cross-thread messages block decisions", %{
    message: m
  } do
    for changed <- [
          %{m | text_body: nil},
          %{m | internet_message_id: nil},
          %{m | from: ""},
          %{m | from: "a@example.invalid, b@example.invalid"},
          %{m | thread_id: "other"},
          %{m | internal_date: nil}
        ] do
      assert {:error, :source_gap} = Sources.snapshot([changed], 42, "abcdef")
    end

    assert {:error, :source_gap} = Sources.snapshot([], 42, "abcdef")
  end

  test "duplicate IDs and oversized recent evidence are held without silently truncating", %{
    message: m
  } do
    assert {:error, :source_gap} = Sources.snapshot([m, m], 42, "abcdef")

    assert {:error, :source_gap} =
             Sources.snapshot([%{m | text_body: String.duplicate("a", 240_001)}], 42, "abcdef")
  end

  test "long threads retain a complete fingerprint with only six recent bodies", %{message: m} do
    messages =
      for n <- 1..180,
          do: %{
            m
            | message_id: Integer.to_string(n, 16),
              internal_date: DateTime.add(m.internal_date, n * 86_400),
              text_body: String.duplicate("old history ", 3_000)
          }

    messages =
      Enum.map(Enum.with_index(messages), fn {message, n} ->
        if n >= 174, do: %{message | text_body: "Recent answer #{n}"}, else: message
      end)

    assert {:ok, snapshot} = Sources.snapshot(messages, 42, "abcdef")
    assert snapshot["message_count"] == 180
    assert length(snapshot["messages"]) == 6
    assert byte_size(Jason.encode!(snapshot)) < 8_000
    assert List.last(snapshot["messages"])["text_body"] == "Recent answer 179"

    assert {:ok, shortened} = Sources.snapshot(tl(messages), 42, "abcdef")
    refute snapshot["fingerprint"] == shortened["fingerprint"]
    assert snapshot["messages"] == shortened["messages"]
  end
end
