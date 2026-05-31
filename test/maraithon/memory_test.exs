defmodule Maraithon.MemoryTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Memory
  alias Maraithon.Memory.Event
  alias Maraithon.Memory.Intelligence

  test "prompt context empty state avoids internal durable-memory language" do
    context =
      Memory.prompt_context("memory-empty-#{System.unique_integer([:positive])}@example.com")

    assert context.summary == "No relevant long-term memories matched this context."
    assert context.memories == []
    assert context.count == 0
    refute context.summary =~ "durable"
  end

  test "prompt context without a user uses product-safe empty copy" do
    context = Memory.prompt_context(nil)

    assert context.summary == "No relevant long-term memories matched this context."
    assert context.memories == []
    assert context.count == 0
    refute context.summary =~ "saved yet"
  end

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

  test "encrypts memory content at rest and validates structured evidence" do
    user_id = "memory-encrypted-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, memory} =
             Memory.write(user_id, %{
               "kind" => "preference",
               "title" => "Sensitive preference",
               "content" => "Sensitive school pickup details should be handled carefully.",
               "summary" => "Sensitive pickup detail.",
               "metadata" => %{
                 "evidence" => %{
                   "quote" => "Please treat pickup details carefully.",
                   "source" => "telegram:turn-1"
                 }
               }
             })

    assert memory.content =~ "Sensitive school pickup"
    assert memory.metadata["evidence"]["source"] == "telegram:turn-1"

    {:ok, raw_id} = Ecto.UUID.dump(memory.id)

    %{rows: [[raw_content, raw_summary, raw_metadata]]} =
      Repo.query!(
        "SELECT content, summary, metadata FROM memory_items WHERE id = $1",
        [raw_id]
      )

    assert is_binary(raw_content)
    assert is_binary(raw_summary)
    assert is_binary(raw_metadata)
    assert :binary.match(raw_content, "Sensitive school pickup") == :nomatch
    assert :binary.match(raw_metadata, "telegram:turn-1") == :nomatch

    assert {:error, changeset} =
             Memory.write(user_id, %{
               "title" => "Bad evidence",
               "content" => "This should fail because evidence is incomplete.",
               "metadata" => %{"evidence" => %{"quote" => "missing source"}}
             })

    assert "evidence must be a map or list of maps with quote and source" in errors_on(changeset).metadata
  end

  test "supersedes contradicting memories atomically and excludes the old row from active recall" do
    user_id = "memory-supersede-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, old} =
             Memory.write(user_id, %{
               "kind" => "preference",
               "title" => "Charlie channel",
               "content" => "Charlie prefers Slack.",
               "dedupe_key" => "charlie-channel",
               "importance" => 90
             })

    assert {:ok, new} =
             Memory.write(user_id, %{
               "kind" => "preference",
               "title" => "Charlie channel",
               "content" => "Charlie now prefers email.",
               "dedupe_key" => "charlie-channel",
               "supersedes_id" => old.id,
               "importance" => 90
             })

    old = Memory.get_item_for_user(user_id, old.id)
    assert old.status == "superseded"
    assert old.superseded_by_id == new.id
    assert new.supersedes_id == old.id

    new_id = new.id
    assert [%{id: ^new_id}] = Memory.list_items(user_id, query: "Charlie")

    llm_complete = fn prompt ->
      assert prompt =~ "Charlie now prefers email"
      refute prompt =~ "Charlie prefers Slack"

      {:ok,
       Jason.encode!(%{
         "summary" => "The newer Charlie preference applies.",
         "selected" => [
           %{
             "memory_id" => new.id,
             "relevance" => 0.99,
             "reason" => "Newer superseding memory."
           }
         ]
       })}
    end

    assert {:ok, recalled} =
             Memory.recall(user_id, "How should I reach Charlie?", llm_complete: llm_complete)

    assert [selected] = recalled.memories
    assert selected.id == new.id

    assert Repo.exists?(
             from event in Event,
               where:
                 event.user_id == ^user_id and event.memory_id == ^old.id and
                   event.event_type == "superseded"
           )
  end

  test "records relevance feedback as durable memory" do
    user_id = "memory-feedback-#{Ecto.UUID.generate()}@example.com"
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

    assert memory.content ==
             "Marked Generic VC newsletter as not relevant. Reason: It is broad market commentary with no Runner implication."

    refute memory.content =~ "The user"
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

  test "injects relevant memories into model params before a turn" do
    user_id = "memory-inject-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, _memory} =
             Memory.write(user_id, %{
               "kind" => "preference",
               "title" => "Charlie channel",
               "content" => "Charlie prefers Slack for quick coordination.",
               "importance" => 90,
               "confidence" => 0.95
             })

    params = %{
      "messages" => [
        %{"role" => "system", "content" => "Base assistant instructions."},
        %{"role" => "user", "content" => "How should I reach Charlie?"}
      ]
    }

    injected = Memory.inject_llm_params(params, user_id, query: "Charlie")
    [%{"role" => "system", "content" => system_prompt} | _rest] = injected["messages"]

    assert system_prompt =~ "## Relevant memories"
    assert system_prompt =~ "Charlie channel"
    assert system_prompt =~ "Charlie prefers Slack for quick coordination."
    assert system_prompt =~ "Use memory tools"
  end
end
