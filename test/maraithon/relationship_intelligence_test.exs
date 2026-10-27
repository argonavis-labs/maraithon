defmodule Maraithon.RelationshipIntelligenceTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Memory
  alias Maraithon.RelationshipIntelligence

  test "builds bounded chat-tier params for relationship learning" do
    user_id = "relationship-intel-params-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    long_body = String.duplicate("Detailed relationship context that should be compacted. ", 80)

    observations =
      for index <- 1..25 do
        %{
          "source" => "gmail",
          "resource_type" => "gmail_thread",
          "resource_id" => "thread-#{index}",
          "title" => "Relationship thread #{index}",
          "summary" => "Summary #{index}",
          "body_excerpt" => long_body,
          "from" => "Person #{index} <person#{index}@example.com>",
          "to" => user_id
        }
      end

    assert {:ok, params} = RelationshipIntelligence.llm_params(user_id, observations)

    assert params["model"] == Maraithon.LLM.chat_model()
    assert params["max_tokens"] == 6_000
    assert params["reasoning_effort"] == "none"

    prompt = get_in(params, ["messages", Access.at(0), "content"])
    assert prompt =~ "Return at most 8 people, 6 memories, and 12 links"
    assert prompt =~ "Keep every string field to one short sentence"
    assert prompt =~ "thread-16"
    refute prompt =~ "thread-17"
    assert prompt =~ "[truncated]"
    assert byte_size(prompt) < 45_000
  end

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

    # Post-review fix: `persist_person/3` used `Map.update("metadata", %{},
    # fun)`, whose default branch inserts the bare default and skips `fun`
    # entirely when "metadata" is absent (the common case) — silently
    # dropping the RI provenance stamp. Same bug class as the person_id
    # stamp above, fixed the same way.
    assert person.metadata["relationship_intelligence"]["source"] == "test"
    assert person.metadata["relationship_intelligence"]["confidence"] == 0.88

    assert [memory] = Memory.list_items(user_id, query: "4M newsletters", limit: 5)
    assert memory.kind == "relationship"

    assert {:ok, relationship} = Crm.relationship_context(user_id, %{person_id: person.id})
    assert [link] = relationship.links
    assert link.resource_type == "gmail_thread"
    assert link.resource_id == "thread-school-4m"
  end

  # SPEC 07 review finding 2: relationship memories must stamp
  # metadata.person_id when the model returns a person_ref, so the memory
  # can be recalled scoped to that person (Recall.score's subject_match_score
  # reads metadata["person_id"] against the person_id filter).
  test "stamps metadata.person_id on relationship memories that reference a person_ref" do
    user_id = "relationship-intel-person-ref-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    observation = %{
      "source" => "gmail",
      "resource_type" => "gmail_thread",
      "resource_id" => "thread-marla-checkin",
      "title" => "Check-in from Marla",
      "from" => "Marla Maharaj <teacher@example.com>",
      "to" => user_id,
      "body_excerpt" => "Just checking in about Emma's progress this term."
    }

    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => "Learned a person-scoped memory.",
             "people" => [
               %{
                 "person_ref" => "marla",
                 "display_name" => "Marla Maharaj",
                 "email" => "teacher@example.com",
                 "relationship" => "School contact for Emma",
                 "importance" => 82,
                 "confidence" => 0.88
               }
             ],
             "memories" => [
               %{
                 "kind" => "relationship",
                 "title" => "Marla prefers concise updates",
                 "content" => "Marla prefers short, concise email replies about Emma.",
                 "tags" => ["emma", "school"],
                 "importance" => 80,
                 "confidence" => 0.9,
                 "dedupe_key" => "relationship-intel:marla-prefers-concise",
                 "person_ref" => "marla"
               },
               %{
                 "kind" => "relationship",
                 "title" => "General school logistics note",
                 "content" => "School logistics emails are not urgent unless flagged.",
                 "tags" => ["school"],
                 "importance" => 60,
                 "confidence" => 0.9,
                 "dedupe_key" => "relationship-intel:general-school-logistics"
               }
             ],
             "links" => []
           })
       }}
    end

    assert {:ok, result} =
             RelationshipIntelligence.learn_from_observations(user_id, [observation],
               source: "test",
               llm_complete: llm_complete
             )

    assert result.memory_count == 2
    assert [person] = Crm.list_people(user_id, query: "Marla")

    scoped_memory =
      Enum.find(Memory.list_items(user_id, limit: 10), &(&1.title =~ "concise updates"))

    unscoped_memory =
      Enum.find(Memory.list_items(user_id, limit: 10), &(&1.title =~ "General school logistics"))

    assert scoped_memory.metadata["person_id"] == person.id
    assert is_nil(unscoped_memory.metadata["person_id"])
  end

  # SPEC 04 R12-R14: person<->person proxy edges.

  test "a person-type link resolves resource_id through the person_index" do
    user_id = "relationship-intel-proxy-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, result} =
             RelationshipIntelligence.persist_from_response(
               user_id,
               Jason.encode!(%{
                 "summary" => "Marla is Emma's mom and handles her logistics.",
                 "people" => [
                   %{
                     "person_ref" => "marla",
                     "display_name" => "Marla Maharaj",
                     "relationship" => "Emma's mom",
                     "confidence" => 0.9
                   },
                   %{
                     "person_ref" => "emma",
                     "display_name" => "Emma Fenwick",
                     "relationship" => "Kent's daughter",
                     "confidence" => 0.9
                   }
                 ],
                 "memories" => [],
                 "links" => [
                   %{
                     "person_ref" => "marla",
                     "resource_type" => "person",
                     "resource_id" => "emma",
                     "role" => "parent_of",
                     "summary" => "Marla repeatedly emails about Emma's school logistics.",
                     "relationship_note" => "Proxy for Emma's school items."
                   }
                 ]
               })
             )

    assert result.link_count == 1

    people = Crm.list_people(user_id)
    marla = Enum.find(people, &(&1.display_name == "Marla Maharaj"))
    emma = Enum.find(people, &(&1.display_name == "Emma Fenwick"))
    assert marla && emma

    assert [link] = Crm.list_links_for_person(user_id, marla.id, resource_type: "person")
    # Resolved through the person_index to the persisted person's id — not
    # stored as the raw "emma" ref string.
    assert link.resource_id == emma.id
    assert link.role == "parent_of"
  end

  test "a person-type link to a never-persisted person skips with person_resource_not_found" do
    user_id = "relationship-intel-dangling-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, result} =
             RelationshipIntelligence.persist_from_response(
               user_id,
               Jason.encode!(%{
                 "summary" => "Proxy edge to an unknown person.",
                 "people" => [
                   %{
                     "person_ref" => "marla",
                     "display_name" => "Marla Maharaj",
                     "confidence" => 0.9
                   }
                 ],
                 "memories" => [],
                 "links" => [
                   %{
                     "person_ref" => "marla",
                     "resource_type" => "person",
                     "resource_id" => "some unknown coach",
                     "role" => "proxy_for"
                   }
                 ]
               })
             )

    assert result.link_count == 0
    assert Enum.any?(result.errors, &(&1.reason =~ "person_resource_not_found"))

    assert [marla] = Crm.list_people(user_id, query: "Marla")
    assert Crm.list_links_for_person(user_id, marla.id, resource_type: "person") == []
  end

  test "a person-type link is rejected when either endpoint matches a self handle" do
    user_id = "relationship-intel-self-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    # The user's account email is always one of their own handles; the model
    # ignoring the prompt rule and emitting a person for it must be blocked
    # at the edge-persistence layer, not just in the prompt.
    assert {:ok, result} =
             RelationshipIntelligence.persist_from_response(
               user_id,
               Jason.encode!(%{
                 "summary" => "Self edge that must be rejected.",
                 "people" => [
                   %{
                     "person_ref" => "self",
                     "display_name" => "Kent Fenwick",
                     "contact_details" => %{"emails" => [user_id]},
                     "confidence" => 0.9
                   },
                   %{
                     "person_ref" => "marla",
                     "display_name" => "Marla Maharaj",
                     "confidence" => 0.9
                   }
                 ],
                 "memories" => [],
                 "links" => [
                   %{
                     "person_ref" => "self",
                     "resource_type" => "person",
                     "resource_id" => "marla",
                     "role" => "spouse_of"
                   },
                   %{
                     "person_ref" => "marla",
                     "resource_type" => "person",
                     "resource_id" => "self",
                     "role" => "spouse_of"
                   }
                 ]
               })
             )

    assert result.link_count == 0
    assert Enum.count(result.errors, &(&1.reason =~ "self_person_link_rejected")) == 2
  end
end
