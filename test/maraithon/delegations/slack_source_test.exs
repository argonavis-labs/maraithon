defmodule Maraithon.Delegations.SlackSourceTest do
  use ExUnit.Case, async: true
  alias Maraithon.Delegations.SlackSource
  @root "1789500000.000001"
  @reply "1789500001.000002"

  test "complete thread evidence preserves authors, ordering and edit revisions" do
    root = %{"ts" => @root, "user" => "UOWN", "text" => "What colour?"}
    reply = %{"ts" => @reply, "thread_ts" => @root, "user" => "UCHARLIE", "text" => "Indigo"}
    assert {:ok, original} = SlackSource.snapshot([reply, root], 1, "C123", @root)
    assert Enum.map(original["messages"], & &1["message_id"]) == [@root, @reply]
    assert List.last(original["messages"])["from"] == "UCHARLIE"
    edited = Map.merge(reply, %{"text" => "Violet", "edited" => %{"ts" => "1789500002.000003"}})
    assert {:ok, changed} = SlackSource.snapshot([root, edited], 1, "C123", @root)

    refute List.last(original["messages"])["revision"] ==
             List.last(changed["messages"])["revision"]

    assert original["complete"]
    assert SlackSource.time(@reply) == ~U[2026-09-15 19:20:01.000002Z]
  end

  test "partial, malformed, cross-thread and oversized reads never become complete evidence" do
    root = %{"ts" => @root, "user" => "UOWN", "text" => "What colour?"}

    for messages <- [
          [],
          [root, root],
          [%{root | "user" => nil}],
          [%{root | "text" => nil}],
          [
            root,
            %{
              "ts" => @reply,
              "thread_ts" => "1789500100.000001",
              "user" => "UOTHER",
              "text" => "Other thread"
            }
          ],
          [root, %{"ts" => @reply, "user" => "UOTHER", "text" => "Unbound message"}],
          [%{root | "text" => String.duplicate("x", 240_001)}]
        ] do
      assert {:error, :source_gap} = SlackSource.snapshot(messages, 1, "C123", @root)
    end
  end
end
