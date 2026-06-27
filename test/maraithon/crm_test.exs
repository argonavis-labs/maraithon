defmodule Maraithon.CrmTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Crm.{PersonMerge, Serializer}
  alias Maraithon.Goals
  alias Maraithon.Goals.GoalLink
  alias Maraithon.Repo
  alias Maraithon.Todos

  test "upserts people by contact details and normalizes relationship fields" do
    user_id = "crm-person-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, person} =
             Crm.upsert_person(user_id, %{
               "firstName" => "Charlie",
               "lastName" => "Smith",
               "email" => "charlie@example.com",
               "slack_id" => "U123",
               "preferred_communication_method" => "slack",
               "relationship" => "Runner teammate",
               "communication_frequency" => "weekly"
             })

    assert person.display_name == "Charlie Smith"
    assert person.contact_details["emails"] == ["charlie@example.com"]
    assert person.contact_details["slack_ids"] == ["U123"]

    assert {:ok, updated} =
             Crm.upsert_person(user_id, %{
               "email" => "charlie@example.com",
               "relationship" => "Runner GTM teammate",
               "notes" => "Prefers short Slack pings before calls."
             })

    assert updated.id == person.id
    assert updated.display_name == "Charlie Smith"
    assert updated.relationship == "Runner GTM teammate"
    assert updated.notes =~ "Slack pings"
    assert updated.contact_details["emails"] == ["charlie@example.com"]
    assert updated.contact_details["slack_ids"] == ["U123"]

    assert [listed] = Crm.list_people(user_id, query: "charlie")
    assert listed.id == person.id
  end

  test "upserts people by exact specific display name when identifiers differ" do
    user_id = "crm-person-name-dedupe-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, person} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Jeff McLarty",
        "slack_id" => "Jeff McLarty",
        "relationship" => "GM at Agora"
      })

    assert {:ok, updated} =
             Crm.upsert_person(user_id, %{
               "display_name" => "Jeff McLarty",
               "email" => "jeff@voteagora.com",
               "relationship" => "Colleague or team member"
             })

    assert updated.id == person.id
    assert updated.contact_details["slack_ids"] == ["Jeff McLarty"]
    assert updated.contact_details["emails"] == ["jeff@voteagora.com"]

    assert [listed] = Crm.list_people(user_id, query: "Jeff McLarty", limit: 5)
    assert listed.id == person.id
  end

  test "does not collapse ambiguous first-name records when identifiers differ" do
    user_id = "crm-person-ambiguous-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, first} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Jeff",
        "email" => "first-jeff@example.com"
      })

    {:ok, second} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Jeff",
        "phone" => "+1 905 555 1212"
      })

    refute second.id == first.id

    assert user_id
           |> Crm.list_people(query: "Jeff", limit: 5)
           |> Enum.count(&(&1.display_name == "Jeff")) == 2
  end

  test "upserts first-name-only source rows into a unique specific existing person" do
    user_id = "crm-person-first-name-specific-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, person} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Jeff McLarty",
        "email" => "jeff@voteagora.com"
      })

    assert {:ok, updated} =
             Crm.upsert_person(user_id, %{
               "display_name" => "Jeff",
               "slack_id" => "UJEFF"
             })

    assert updated.id == person.id
    assert updated.display_name == "Jeff McLarty"
    assert updated.contact_details["emails"] == ["jeff@voteagora.com"]
    assert updated.contact_details["slack_ids"] == ["UJEFF"]

    assert [listed] = Crm.list_people(user_id, query: "Jeff", limit: 5)
    assert listed.id == person.id
  end

  test "finds people by phone contact across formatting differences" do
    user_id = "crm-phone-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, person} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Charlie Smith",
        "phone" => "+1 (416) 526-1454"
      })

    assert %Crm.Person{id: id} = Crm.find_person_by_contact(user_id, "14165261454")
    assert id == person.id

    assert %Crm.Person{id: id} =
             Crm.find_person_by_contact(user_id, "4165261454", contact_kind: :phone)

    assert id == person.id
  end

  test "lists family context and preserves family metadata in prompt summaries" do
    user_id = "crm-family-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _work_person} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Dana Lee",
        "relationship" => "Customer sponsor",
        "relationship_strength" => 99
      })

    {:ok, child} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Jack Fenwick",
        "relationship" => "Child",
        "metadata" => %{
          "relationship_domain" => "family",
          "relationship_preset" => "child",
          "family_member" => true,
          "family_role" => "child",
          "todo_policy" => "family_logistics_only"
        }
      })

    assert [family_person] = Crm.list_family_context(user_id, limit: 5)
    assert family_person.id == child.id

    assert [serialized] = Crm.summarize_for_prompt(user_id, 1)
    assert serialized.display_name == "Jack Fenwick"
    assert serialized.metadata["relationship_domain"] == "family"
    assert serialized.metadata["relationship_preset"] == "child"
    assert serialized.metadata["todo_policy"] == "family_logistics_only"
  end

  test "grows relationship metrics from repeated model-backed observations" do
    user_id = "crm-metrics-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, person} =
             Crm.upsert_person(user_id, %{
               "display_name" => "Charlie Jones",
               "email" => "charlie@example.com",
               "relationship_strength" => 40,
               "affinity_score" => 35,
               "interaction_count_delta" => 2,
               "last_interaction_at" => "2026-05-08T14:00:00Z"
             })

    assert person.interaction_count == 2
    assert person.relationship_strength == 40
    assert person.affinity_score == 35

    assert {:ok, updated} =
             Crm.upsert_person(user_id, %{
               "email" => "charlie@example.com",
               "relationship_strength_delta" => 8,
               "affinity_delta" => 5,
               "interaction_count_delta" => 1,
               "last_interaction_at" => "2026-05-09T14:00:00Z"
             })

    assert updated.id == person.id
    assert updated.interaction_count == 3
    assert updated.relationship_strength == 48
    assert updated.affinity_score == 40
    assert DateTime.compare(updated.last_interaction_at, ~U[2026-05-09 14:00:00Z]) == :eq
  end

  test "links a person to todos and returns relationship context" do
    user_id = "crm-link-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, person} =
      Crm.upsert_person(user_id, %{
        "first_name" => "Justin",
        "last_name" => "Dean",
        "email" => "justin@example.com",
        "relationship" => "Investor",
        "preferred_communication_method" => "email",
        "communication_frequency" => "monthly"
      })

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "general",
          "title" => "Reply to Justin",
          "summary" => "Justin is waiting for a financing update.",
          "next_action" => "Send the promised update.",
          "dedupe_key" => "crm-link:justin-reply"
        }
      ])

    assert {:ok, link} =
             Crm.attach_resource(user_id, person.id, %{
               "resource_type" => "todo",
               "resource_id" => todo.id,
               "resource_source" => "gmail",
               "role" => "owed_to",
               "source_account" => "justin@example.com",
               "source_ref" => "gmail-message-1",
               "evidence_quote" => "Justin is waiting for a financing update.",
               "model_rationale" => "The todo is owed to Justin.",
               "confidence" => 0.91,
               "title" => todo.title,
               "relationship_note" => "This is follow-up work owed to Justin."
             })

    assert link.person_id == person.id
    assert link.source_system == "gmail"
    assert link.role == "owed_to"
    assert link.source_ref == "gmail-message-1"
    assert link.evidence_quote =~ "financing update"

    assert {:ok, context} = Crm.relationship_context(user_id, %{"query" => "Justin"})
    assert context.person.id == person.id
    assert context.open_todo_count == 1
    assert [%{id: todo_id}] = context.todos
    assert todo_id == todo.id

    [batched_context] = Crm.relationship_contexts(user_id, [person], link_limit: 5)
    assert batched_context.person.id == person.id
    assert batched_context.open_todo_count == 1
    assert [%{id: ^todo_id}] = batched_context.todos
  end

  test "merge_people audits, hides the merged row, repoints links, and collapses duplicates" do
    user_id = "crm-merge-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, survivor} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Charlie Smith",
        "email" => "charlie@example.com",
        "relationship_strength" => 50,
        "affinity_score" => 20
      })

    {:ok, duplicate} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Charles Smith",
        "slack_id" => "UCHARLIE",
        "relationship" => "Runner teammate",
        "interaction_count_delta" => 3,
        "relationship_strength" => 40,
        "affinity_score" => 60
      })

    {:ok, [shared_todo, unique_todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "title" => "Reply to Charlie",
          "summary" => "Shared follow-up.",
          "next_action" => "Reply.",
          "dedupe_key" => "crm-merge:shared"
        },
        %{
          "source" => "slack",
          "title" => "Send Charlie deck",
          "summary" => "Unique follow-up.",
          "next_action" => "Send deck.",
          "dedupe_key" => "crm-merge:unique"
        }
      ])

    {:ok, _survivor_link} =
      Crm.attach_resource(user_id, survivor.id, %{
        "todo_id" => shared_todo.id,
        "resource_source" => "gmail",
        "relationship_note" => "Existing survivor note"
      })

    {:ok, _duplicate_shared_link} =
      Crm.attach_resource(user_id, duplicate.id, %{
        "todo_id" => shared_todo.id,
        "resource_source" => "slack",
        "relationship_note" => "Duplicate evidence note",
        "evidence_quote" => "Charlie asked for a reply.",
        "confidence" => 0.8
      })

    {:ok, _duplicate_unique_link} =
      Crm.attach_resource(user_id, duplicate.id, %{
        "todo_id" => unique_todo.id,
        "resource_source" => "slack",
        "role" => "participant"
      })

    {:ok, shared_goal} =
      Goals.create_goal(user_id, %{
        "category" => "work",
        "title" => "Launch Runner",
        "desired_outcome" => "Keep the launch team aligned.",
        "priority" => 80
      })

    {:ok, unique_goal} =
      Goals.create_goal(user_id, %{
        "category" => "work",
        "title" => "Close customer feedback",
        "desired_outcome" => "Get Charlie's customer context into the plan.",
        "priority" => 70
      })

    {:ok, _survivor_goal_link} =
      Goals.link_resource(user_id, shared_goal.id, %{
        "resource_type" => "person",
        "resource_id" => survivor.id,
        "relationship" => "supports",
        "source" => "agent",
        "confidence" => 0.4
      })

    {:ok, _duplicate_shared_goal_link} =
      Goals.link_resource(user_id, shared_goal.id, %{
        "resource_type" => "person",
        "resource_id" => duplicate.id,
        "relationship" => "supports",
        "source" => "agent",
        "confidence" => 0.8
      })

    {:ok, _duplicate_unique_goal_link} =
      Goals.link_resource(user_id, unique_goal.id, %{
        "resource_type" => "person",
        "resource_id" => duplicate.id,
        "relationship" => "supports",
        "source" => "agent",
        "confidence" => 0.7
      })

    assert {:ok, result} =
             Crm.merge_people(user_id, survivor.id, duplicate.id, %{
               "evidence" => "Same person across Gmail and Slack.",
               "model_rationale" => "Names and context match.",
               "performed_by" => "test"
             })

    assert result.repointed_link_count == 1
    assert result.collapsed_link_count == 1
    assert result.repointed_goal_link_count == 1
    assert result.collapsed_goal_link_count == 1
    assert result.audit.evidence =~ "Same person"

    reloaded_survivor = Crm.get_person_for_user(user_id, survivor.id)
    assert reloaded_survivor.status == "active"
    assert reloaded_survivor.contact_details["emails"] == ["charlie@example.com"]
    assert reloaded_survivor.contact_details["slack_ids"] == ["UCHARLIE"]
    assert reloaded_survivor.interaction_count == 3
    assert reloaded_survivor.relationship_strength == 50
    assert reloaded_survivor.affinity_score == 60

    reloaded_duplicate = Crm.get_person_for_user(user_id, duplicate.id)
    assert reloaded_duplicate.status == "merged"
    assert reloaded_duplicate.merged_into_id == survivor.id
    assert reloaded_duplicate.merged_at

    assert [listed] = Crm.list_people(user_id, query: "Charlie", limit: 5)
    assert listed.id == survivor.id
    assert [merged] = Crm.list_people(user_id, status: "merged")
    assert merged.id == duplicate.id

    links = Crm.list_links_for_person(user_id, survivor.id, limit: 10)
    assert length(links) == 2
    assert Enum.any?(links, &(&1.resource_id == unique_todo.id and &1.role == "participant"))

    shared_link = Enum.find(links, &(&1.resource_id == shared_todo.id))
    assert shared_link.relationship_note =~ "Existing survivor note"
    assert shared_link.relationship_note =~ "Duplicate evidence note"
    assert shared_link.evidence_quote =~ "asked for a reply"
    assert shared_link.confidence == 0.8

    survivor_goal_links =
      Repo.all(
        from link in GoalLink,
          where:
            link.user_id == ^user_id and link.resource_type == "person" and
              link.resource_id == ^survivor.id
      )

    assert length(survivor_goal_links) == 2

    assert Enum.any?(
             survivor_goal_links,
             &(&1.goal_id == shared_goal.id and &1.confidence == 0.8)
           )

    assert Enum.any?(survivor_goal_links, &(&1.goal_id == unique_goal.id))

    refute Repo.exists?(
             from link in GoalLink,
               where:
                 link.user_id == ^user_id and link.resource_type == "person" and
                   link.resource_id == ^duplicate.id
           )

    assert %PersonMerge{} =
             Repo.get_by(PersonMerge,
               user_id: user_id,
               surviving_person_id: survivor.id,
               merged_person_id: duplicate.id
             )

    assert {:error, :person_already_merged} =
             Crm.merge_people(user_id, survivor.id, duplicate.id, %{})
  end

  test "merge_people rejects self merges and cross-user ownership" do
    user_id = "crm-merge-invalid-#{System.unique_integer([:positive])}@example.com"
    other_user_id = "crm-merge-other-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    {:ok, _other_user} = Accounts.get_or_create_user_by_email(other_user_id)

    {:ok, person} = Crm.upsert_person(user_id, %{"display_name" => "A"})
    {:ok, other_person} = Crm.upsert_person(other_user_id, %{"display_name" => "B"})

    assert {:error, :cannot_merge_person_into_self} =
             Crm.merge_people(user_id, person.id, person.id, %{})

    assert {:error, :person_not_found} =
             Crm.merge_people(user_id, person.id, other_person.id, %{})
  end

  test "telegram card serializer renders compact relationship context" do
    user_id = "crm-card-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, person} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Dana Lee",
        "relationship" => "Customer sponsor",
        "preferred_communication_method" => "slack",
        "last_interaction_at" => "2026-05-19T12:00:00Z"
      })

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "slack",
          "title" => "Send Dana notes",
          "summary" => "Dana asked for notes.",
          "next_action" => "Send notes.",
          "dedupe_key" => "crm-card:dana"
        }
      ])

    {:ok, _link} =
      Crm.attach_resource(user_id, person.id, %{
        "todo_id" => todo.id,
        "resource_source" => "slack"
      })

    assert {:ok, context} = Crm.relationship_context(user_id, %{"person_id" => person.id})
    card = Serializer.telegram_card(context)

    assert card =~ "*Dana Lee*"
    assert card =~ "Relationship: Customer sponsor"
    assert card =~ "Preferred: slack"
    assert card =~ "Open follow-ups: 1"
    assert card =~ "Sources: slack (1)"
    refute card =~ "|"
    assert String.length(card) < 600
  end

  describe "resolve_contact/3" do
    setup do
      user_id = "crm-resolve-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      %{user_id: user_id}
    end

    test "returns the existing person when an email matches", %{user_id: user_id} do
      {:ok, original} =
        Crm.upsert_person(user_id, %{
          "display_name" => "Charlie Smith",
          "email" => "charlie@example.com"
        })

      assert {:ok, found} = Crm.resolve_contact(user_id, %{email: "charlie@example.com"})
      assert found.id == original.id
    end

    test "creates a stub person from an email when none matches", %{user_id: user_id} do
      assert {:ok, person} = Crm.resolve_contact(user_id, %{email: "Dana.Lee@example.com"})

      assert person.user_id == user_id
      assert person.display_name == "Dana Lee"
      assert person.contact_details["emails"] == ["Dana.Lee@example.com"]
      assert person.interaction_count == 0
    end

    test "honours an explicit display_name override", %{user_id: user_id} do
      assert {:ok, person} =
               Crm.resolve_contact(user_id, %{email: "x@y.com"}, display_name: "Custom Name")

      assert person.display_name == "Custom Name"
    end

    test "creates a stub from a slack id", %{user_id: user_id} do
      assert {:ok, person} = Crm.resolve_contact(user_id, %{slack_id: "U7XQ"})
      assert person.contact_details["slack_ids"] == ["U7XQ"]
      assert person.display_name == "U7XQ"
    end

    test "rejects an empty identifier", %{user_id: user_id} do
      assert {:error, :unresolvable_contact} = Crm.resolve_contact(user_id, %{email: ""})
      assert {:error, :unresolvable_contact} = Crm.resolve_contact(user_id, %{})
    end
  end

  describe "fuzzy person lookup" do
    setup do
      user_id = "crm-fuzzy-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, charlie} =
        Crm.upsert_person(user_id, %{
          "first_name" => "Charlie",
          "last_name" => "Smith",
          "display_name" => "Charlie Smith"
        })

      {:ok, _daniel} =
        Crm.upsert_person(user_id, %{
          "first_name" => "Daniel",
          "last_name" => "Bourke",
          "display_name" => "Daniel Bourke"
        })

      {:ok, charles} =
        Crm.upsert_person(user_id, %{
          "first_name" => "Charles",
          "last_name" => "Williams",
          "display_name" => "Charles Williams"
        })

      %{user_id: user_id, charlie: charlie, charles: charles}
    end

    test "list_people query returns the closest match by trigram similarity",
         %{user_id: user_id, charlie: charlie} do
      [first | _] = Crm.list_people(user_id, query: "Charlie", limit: 5)
      assert first.id == charlie.id
    end

    test "list_people query matches a first-name nickname", %{user_id: user_id} do
      results = Crm.list_people(user_id, query: "Dan", limit: 5)
      assert Enum.any?(results, &(&1.display_name == "Daniel Bourke"))
    end

    test "upsert_person matches an existing record by fuzzy display_name",
         %{user_id: user_id, charlie: charlie} do
      {:ok, found} = Crm.upsert_person(user_id, %{"display_name" => "Charlie"})
      assert found.id == charlie.id
    end
  end

  describe "semantic_find_person/3" do
    test "returns the person whose embedding is closest to the query" do
      user_id = "crm-semantic-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, charlie} =
        Crm.upsert_person(user_id, %{
          "display_name" => "Charlie Smith",
          "relationship" => "Runner GTM teammate"
        })

      {:ok, dan} =
        Crm.upsert_person(user_id, %{
          "display_name" => "Daniel Bourke",
          "relationship" => "Australian product founder, ex-Mac AI"
        })

      # Synchronously prime embeddings using the deterministic mock provider.
      assert {:ok, _} =
               Maraithon.Crm.PersonEmbeddings.refresh(charlie, provider: :mock)

      assert {:ok, _} =
               Maraithon.Crm.PersonEmbeddings.refresh(dan, provider: :mock)

      result =
        Crm.semantic_find_person(user_id, "Australian product founder ex-Mac AI",
          provider: :mock,
          threshold: 0.0
        )

      assert result && result.id == dan.id
    end

    test "returns nil when no embeddings are stored" do
      user_id = "crm-semantic-empty-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
      {:ok, _person} = Crm.upsert_person(user_id, %{"display_name" => "Charlie Smith"})

      assert is_nil(Crm.semantic_find_person(user_id, "the runner gtm guy", provider: :mock))
    end
  end

  describe "bump_interaction/3" do
    setup do
      user_id = "crm-bump-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, person} =
        Crm.upsert_person(user_id, %{
          "display_name" => "Charlie",
          "email" => "charlie@example.com"
        })

      %{user_id: user_id, person: person}
    end

    test "increments interaction_count and sets last_interaction_at on first bump",
         %{person: person} do
      occurred_at = DateTime.add(DateTime.utc_now(), -10, :minute)
      assert {:ok, :bumped} = Crm.bump_interaction(person.id, occurred_at, "gmail")

      reloaded = Maraithon.Repo.get!(Maraithon.Crm.Person, person.id)
      assert reloaded.interaction_count == 1
      assert DateTime.compare(reloaded.last_interaction_at, occurred_at) == :eq
    end

    test "second bump increments and only advances last_interaction_at forward",
         %{person: person} do
      first = DateTime.add(DateTime.utc_now(), -2, :hour)
      older = DateTime.add(first, -1, :day)

      assert {:ok, :bumped} = Crm.bump_interaction(person.id, first, "gmail")
      assert {:ok, :bumped} = Crm.bump_interaction(person.id, older, "gmail")

      reloaded = Maraithon.Repo.get!(Maraithon.Crm.Person, person.id)
      assert reloaded.interaction_count == 2
      assert DateTime.compare(reloaded.last_interaction_at, first) == :eq
    end

    test "later occurred_at advances last_interaction_at", %{person: person} do
      first = DateTime.add(DateTime.utc_now(), -2, :hour)
      later = DateTime.add(first, 30, :minute)

      assert {:ok, :bumped} = Crm.bump_interaction(person.id, first, "gmail")
      assert {:ok, :bumped} = Crm.bump_interaction(person.id, later, "slack")

      reloaded = Maraithon.Repo.get!(Maraithon.Crm.Person, person.id)
      assert reloaded.interaction_count == 2
      assert DateTime.compare(reloaded.last_interaction_at, later) == :eq
    end

    test "returns :person_not_found for an unknown id" do
      assert {:error, :person_not_found} =
               Crm.bump_interaction(Ecto.UUID.generate(), DateTime.utc_now(), "gmail")
    end
  end
end
