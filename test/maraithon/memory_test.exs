defmodule Maraithon.MemoryTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Memory
  alias Maraithon.Memory.Intelligence

  test "writes, lists, recalls, and forgets durable memories" do
    user_id = "memory-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, memory} =
             Memory.write(user_id, %{
               "kind" => "preference",
               "title" => "School calendar is relevant",
               "content" =>
                 "The user wants school calendar emails surfaced when they affect pickup, forms, or schedule changes.",
               "tags" => ["school", "relevance"],
               "importance" => 88,
               "confidence" => 0.94,
               "dedupe_key" => "school-calendar-relevance"
             })

    assert memory.user_id == user_id
    assert memory.kind == "preference"
    assert memory.tags == ["school", "relevance"]

    assert [listed] = Memory.list_items(user_id, query: "school")
    assert listed.id == memory.id

    llm_complete = fn prompt ->
      assert prompt =~ Intelligence.sentinel()
      assert prompt =~ "School calendar is relevant"

      {:ok,
       Jason.encode!(%{
         "summary" => "School relevance memory applies.",
         "selected" => [
           %{
             "memory_id" => memory.id,
             "relevance" => 0.98,
             "reason" => "The user is asking about school inbox relevance."
           }
         ]
       })}
    end

    assert {:ok, recalled} =
             Memory.recall(user_id, "Should I surface this school email?",
               llm_complete: llm_complete,
               limit: 5
             )

    assert recalled.count == 1
    assert [selected] = recalled.memories
    assert selected.id == memory.id
    assert selected.relevance == 0.98

    assert {:ok, forgotten} = Memory.forget(user_id, memory.id)
    assert forgotten.status == "archived"
    assert Memory.list_items(user_id, query: "school") == []
  end

  test "records relevance feedback as durable memory" do
    user_id = "memory-feedback-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, memory} =
             Memory.record_relevance_feedback(user_id, %{
               "subject" => "Generic VC newsletter",
               "feedback" => "not_relevant",
               "reason" => "It is broad market commentary with no Runner implication.",
               "resource_type" => "gmail_thread",
               "resource_id" => "thread-123"
             })

    assert memory.kind == "relevance_feedback"
    assert memory.polarity == "negative"
    assert "not_relevant" in memory.tags
    assert memory.metadata["feedback"] == "not_relevant"

    llm_complete = fn prompt ->
      assert prompt =~ Intelligence.sentinel()
      assert prompt =~ "Generic VC newsletter"

      {:ok,
       Jason.encode!(%{
         "summary" => "The relevance feedback applies to this newsletter question.",
         "selected" => [
           %{
             "memory_id" => memory.id,
             "relevance" => 0.96,
             "reason" => "This prevents resurfacing a similar broad VC newsletter."
           }
         ]
       })}
    end

    context = Memory.prompt_context(user_id, query: "VC newsletter", llm_complete: llm_complete)

    assert context.count == 1
    assert hd(context.memories).title =~ "Generic VC newsletter"
  end
end
