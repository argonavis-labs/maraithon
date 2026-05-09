defmodule Maraithon.Tools.MemoryToolsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Tools

  test "memory tools write, recall, list, record feedback, and forget memories" do
    user_id = "memory-tools-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, written} =
             Tools.execute("write_memory", %{
               "user_id" => user_id,
               "memory" => %{
                 "kind" => "instruction",
                 "title" => "Prefer actionable school notices",
                 "content" => "Surface school notices when they affect pickup or required forms.",
                 "tags" => ["school", "relevance"],
                 "importance" => 90,
                 "dedupe_key" => "memory-tools:school"
               }
             })

    assert written.source == "maraithon_memory"
    memory = written.memory
    assert memory.title == "Prefer actionable school notices"

    assert {:ok, recalled} =
             Tools.execute("recall_memory", %{
               "user_id" => user_id,
               "query" => "school pickup notice",
               "limit" => 5
             })

    assert recalled.source == "maraithon_memory"
    assert recalled.count == 1
    assert hd(recalled.memories).id == memory.id

    assert {:ok, feedback} =
             Tools.execute("record_memory_feedback", %{
               "user_id" => user_id,
               "subject" => "Generic market newsletter",
               "feedback" => "not_relevant",
               "reason" => "No current customer or Runner implication."
             })

    assert feedback.memory.kind == "relevance_feedback"
    assert feedback.memory.polarity == "negative"

    assert {:ok, listed} =
             Tools.execute("list_memories", %{
               "user_id" => user_id,
               "status" => "active"
             })

    assert listed.count == 2

    assert {:ok, forgotten} =
             Tools.execute("forget_memory", %{
               "user_id" => user_id,
               "memory_id" => memory.id
             })

    assert forgotten.forgotten == true
    assert forgotten.memory.status == "archived"
  end
end
