defmodule Maraithon.Todos.PublicPayloadTest do
  use ExUnit.Case, async: true

  alias Maraithon.Todos.{PublicPayload, Todo}

  describe "todo/1" do
    test "keeps client-facing fields and removes prompt/runtime fields" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      naive_now = DateTime.to_naive(now)

      todo = %Todo{
        id: Ecto.UUID.generate(),
        user_id: "owner@example.com",
        source: "gmail",
        kind: "gmail_triage",
        attention_mode: "act_now",
        title: "Reply to investor terms",
        summary: "The investor asked whether the financing terms changed.",
        next_action: "Reply with the current terms and review window.",
        owner_user_id: "owner@example.com",
        priority: 90,
        status: "open",
        due_at: naive_now,
        source_item_id: "gmail-thread-private-1",
        dedupe_key: "gmail:private-thread-1",
        inserted_at: now,
        updated_at: now,
        metadata: %{
          "subject" => "Financing terms",
          "thread_id" => "thread-private-1",
          "model_rationale" => "Model score says this matters.",
          "token" => "secret-token"
        }
      }

      payload = PublicPayload.todo(todo)

      assert payload["id"] == todo.id
      assert payload["title"] == "Reply to investor terms"
      assert payload["metadata"] == %{"subject" => "Financing terms"}
      assert payload["inserted_at"] == DateTime.to_iso8601(now)
      assert payload["due_at"] == DateTime.to_iso8601(now)
      refute Map.has_key?(payload, "owner_user_id")
      refute Map.has_key?(payload, "source_item_id")
      refute Map.has_key?(payload, "dedupe_key")
      refute inspect(payload) =~ "thread-private-1"
      refute inspect(payload) =~ "Model score"
      refute inspect(payload) =~ "secret-token"
    end

    test "polishes map payload copy before it reaches clients" do
      payload =
        PublicPayload.todo(%{
          "id" => Ecto.UUID.generate(),
          "source" => "gmail",
          "kind" => "gmail_triage",
          "attention_mode" => "act_now",
          "status" => "open",
          "title" => "User committed to follow-up with Alex Müller; follow-up not yet sent.",
          "summary" => "This thread still needs a reply from the user.",
          "next_action" =>
            "Reply now with owner, ETA, and the exact artifact or update you committed to.",
          "priority" => 90,
          "metadata" => %{
            "subject" => "Starteryou UGC Campaigns",
            "source_evidence" =>
              "You said you would follow up on Starteryou UGC campaign timing.",
            "record" => %{
              "person" => "Alex Müller",
              "relationship_context" => "Starteryou UGC campaign contact",
              "commitment" => "Follow through on \"Starteryou UGC Campaigns\" for Alex Müller"
            }
          }
        })

      assert payload["title"] == "Follow up with Alex Müller about Starteryou UGC Campaigns"
      assert payload["summary"] == "This thread is waiting on your reply."
      assert payload["next_action"] =~ "Reply to Alex Müller about Starteryou UGC Campaigns"
      assert payload["metadata"] == %{"subject" => "Starteryou UGC Campaigns"}

      visible = inspect(payload)
      refute visible =~ "User committed"
      refute visible =~ "the user"
      refute visible =~ "owner, ETA"
      refute visible =~ "exact artifact or update"
    end
  end
end
