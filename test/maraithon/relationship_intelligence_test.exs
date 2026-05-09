defmodule Maraithon.RelationshipIntelligenceTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Memory
  alias Maraithon.RelationshipIntelligence

  test "learns CRM people, relationship memories, and source links from model output" do
    user_id = "relationship-intel-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    observation = %{
      "source" => "gmail",
      "resource_type" => "gmail_thread",
      "resource_id" => "thread-school-4m",
      "title" => "4M Weekly Newsletter May 11-15",
      "from" => "Marla Maharaj <teacher@example.com>",
      "to" => user_id,
      "body_excerpt" => "Hi 4M families. Emma's field trip permission form is due Friday."
    }

    llm_complete = fn params ->
      prompt = get_in(params, ["messages", Access.at(0), "content"])
      assert prompt =~ "RELATIONSHIP_INTELLIGENCE_JSON_V1"
      assert prompt =~ "Emma's field trip permission form"
      assert prompt =~ "existing_people"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Learned school relationship context.",
             "people" => [
               %{
                 "person_ref" => "marla",
                 "display_name" => "Marla Maharaj",
                 "email" => "teacher@example.com",
                 "preferred_communication_method" => "gmail",
                 "relationship" => "School contact for Emma",
                 "communication_frequency" => "recurring school updates",
                 "relationship_strength" => 72,
                 "affinity_score" => 64,
                 "interaction_count_delta" => 1,
                 "last_interaction_at" => "2026-05-09T12:00:00Z",
                 "notes" => "Sends school logistics for Emma's class.",
                 "importance" => 82,
                 "confidence" => 0.88
               }
             ],
             "memories" => [
               %{
                 "kind" => "relationship",
                 "title" => "4M newsletters are school logistics for Emma",
                 "content" =>
                   "4M Weekly Newsletter emails are school logistics for Emma unless the body says otherwise.",
                 "tags" => ["emma", "school"],
                 "importance" => 88,
                 "confidence" => 0.9,
                 "dedupe_key" => "relationship-intel:emma-4m-school"
               }
             ],
             "links" => [
               %{
                 "person_ref" => "marla",
                 "resource_type" => "gmail_thread",
                 "resource_id" => "thread-school-4m",
                 "resource_source" => "gmail",
                 "title" => "4M Weekly Newsletter May 11-15",
                 "relationship_note" => "School update from Emma's teacher."
               }
             ]
           })
       }}
    end

    assert {:ok, result} =
             RelationshipIntelligence.learn_from_observations(user_id, [observation],
               source: "test",
               llm_complete: llm_complete
             )

    assert result.people_count == 1
    assert result.memory_count == 1
    assert result.link_count == 1

    assert [person] = Crm.list_people(user_id, query: "Marla")
    assert person.relationship == "School contact for Emma"
    assert person.contact_details["emails"] == ["teacher@example.com"]
    assert person.relationship_strength == 72
    assert person.affinity_score == 64
    assert person.interaction_count == 1

    assert [memory] = Memory.list_items(user_id, query: "4M newsletters", limit: 5)
    assert memory.kind == "relationship"

    assert {:ok, relationship} = Crm.relationship_context(user_id, %{person_id: person.id})
    assert [link] = relationship.links
    assert link.resource_type == "gmail_thread"
    assert link.resource_id == "thread-school-4m"
  end
end
