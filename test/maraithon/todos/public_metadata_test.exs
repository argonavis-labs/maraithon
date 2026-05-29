defmodule Maraithon.Todos.PublicMetadataTest do
  use ExUnit.Case, async: true

  alias Maraithon.Todos.PublicMetadata

  describe "todo/1" do
    test "keeps executive-facing context and removes runtime internals" do
      metadata = %{
        "account" => "kent@example.com",
        "subject" => "Starteryou campaign reply",
        "why_it_matters" => "Michael is waiting on the campaign decision.",
        "thread_id" => "thread-123",
        "source_item_id" => "gmail-456",
        "confidence" => 0.96,
        "model_rationale" => "Model score says this matters.",
        "source_health" => "88% source-backed",
        "token" => "secret-token",
        "record" => %{"person" => "Michael"}
      }

      assert PublicMetadata.todo(metadata) == %{
               "account" => "kent@example.com",
               "subject" => "Starteryou campaign reply",
               "why_it_matters" => "Michael is waiting on the campaign decision."
             }
    end
  end

  describe "person/1" do
    test "keeps mobile person presentation flags and removes raw ids" do
      metadata = %{
        "relationship_preset_label" => "Investor",
        "todo_policy" => "default",
        "person_id" => "person-123",
        "model_score" => 0.82
      }

      assert PublicMetadata.person(metadata) == %{
               "relationship_preset_label" => "Investor",
               "todo_policy" => "default"
             }
    end
  end
end
