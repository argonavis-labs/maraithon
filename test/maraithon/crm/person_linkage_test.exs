defmodule Maraithon.Crm.PersonLinkageTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Crm.PersonLink
  alias Maraithon.Todos

  setup do
    user_id = "person-linkage-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  describe "merge_people/4 repoints todo counterparty FKs (SPEC 04 R7)" do
    test "a todo FK'd to the merged-away person moves to the survivor", %{user_id: user_id} do
      {:ok, survivor} = Crm.create_person(user_id, %{"display_name" => "Dan Bourke"})
      {:ok, duplicate} = Crm.create_person(user_id, %{"display_name" => "Danny Bourke Slack"})

      {:ok, [todo]} =
        Todos.upsert_many(user_id, [
          %{
            "source" => "slack",
            "title" => "Send Dan the summary",
            "summary" => "Owed reply.",
            "next_action" => "Reply.",
            "direction" => "owed_by_me",
            "counterparty_label" => "Danny",
            "counterparty_person_id" => duplicate.id,
            "dedupe_key" => "slack:general:merge-repoint"
          }
        ])

      assert todo.counterparty_person_id == duplicate.id

      before_merge = Todos.list_owed_by_me(user_id)
      assert length(before_merge) == 1

      assert {:ok, result} = Crm.merge_people(user_id, survivor.id, duplicate.id)
      assert result.repointed_todo_count == 1

      repointed = Todos.get_for_user(user_id, todo.id)
      assert repointed.counterparty_person_id == survivor.id

      # The row still round-trips through the owed queries unchanged in count,
      # and the person filter now finds it under the survivor.
      after_merge = Todos.list_owed_by_me(user_id)
      assert length(after_merge) == length(before_merge)
      assert [%{id: repointed_id}] = Todos.list_owed_by_me(user_id, person_id: survivor.id)
      assert repointed_id == todo.id
      assert Todos.list_owed_by_me(user_id, person_id: duplicate.id) == []
    end
  end

  describe "merge_people/4 repoints person-edge targets (SPEC 04 R16)" do
    test "an incoming proxy edge targeting the merged-away person moves to the survivor", %{
      user_id: user_id
    } do
      {:ok, mom} = Crm.create_person(user_id, %{"display_name" => "Marla Maharaj"})
      {:ok, emma} = Crm.create_person(user_id, %{"display_name" => "Emma Fenwick"})
      {:ok, emma_dup} = Crm.create_person(user_id, %{"display_name" => "Emma F School"})

      {:ok, _link} =
        Crm.attach_resource(user_id, mom.id, %{
          "resource_type" => "person",
          "resource_id" => emma_dup.id,
          "role" => "parent_of"
        })

      assert {:ok, result} = Crm.merge_people(user_id, emma.id, emma_dup.id)
      assert result.repointed_person_edge_count == 1

      [link] = Crm.list_links_for_person(user_id, mom.id, resource_type: "person")
      assert link.resource_id == emma.id
      assert link.role == "parent_of"
    end

    test "a duplicate edge collapses into the survivor's existing edge", %{user_id: user_id} do
      {:ok, mom} = Crm.create_person(user_id, %{"display_name" => "Marla Maharaj"})
      {:ok, emma} = Crm.create_person(user_id, %{"display_name" => "Emma Fenwick"})
      {:ok, emma_dup} = Crm.create_person(user_id, %{"display_name" => "Emma F School"})

      {:ok, _kept} =
        Crm.attach_resource(user_id, mom.id, %{
          "resource_type" => "person",
          "resource_id" => emma.id,
          "role" => "parent_of"
        })

      {:ok, _duplicate} =
        Crm.attach_resource(user_id, mom.id, %{
          "resource_type" => "person",
          "resource_id" => emma_dup.id,
          "role" => "parent_of"
        })

      assert {:ok, result} = Crm.merge_people(user_id, emma.id, emma_dup.id)
      assert result.collapsed_person_edge_count == 1

      links = Crm.list_links_for_person(user_id, mom.id, resource_type: "person")
      assert [%PersonLink{resource_id: resource_id}] = links
      assert resource_id == emma.id
    end
  end

  describe "relationship_context/2 proxy network (SPEC 04 R15)" do
    test "querying the subject surfaces the proxy via the incoming edge", %{user_id: user_id} do
      {:ok, mom} = Crm.create_person(user_id, %{"display_name" => "Marla Maharaj"})
      {:ok, emma} = Crm.create_person(user_id, %{"display_name" => "Emma Fenwick"})

      {:ok, _link} =
        Crm.attach_resource(user_id, mom.id, %{
          "resource_type" => "person",
          "resource_id" => emma.id,
          "role" => "parent_of",
          "relationship_note" => "Handles Emma's school logistics."
        })

      # Asking about Emma: the edge is stored under mom's person_id, so only
      # the incoming query can surface it.
      assert {:ok, context} = Crm.relationship_context(user_id, %{"person_id" => emma.id})

      assert [entry] = context.related_people
      assert entry.direction == "incoming"
      assert entry.role == "parent_of"
      assert entry.person_id == mom.id
      assert entry.display_name == "Marla Maharaj"

      # Asking about mom: the same edge is outgoing, resolved to Emma.
      assert {:ok, mom_context} = Crm.relationship_context(user_id, %{"person_id" => mom.id})
      assert [mom_entry] = mom_context.related_people
      assert mom_entry.direction == "outgoing"
      assert mom_entry.person_id == emma.id
      assert mom_entry.display_name == "Emma Fenwick"

      serialized = Maraithon.Tools.PersonHelpers.serialize_relationship_context(context)
      assert [%{direction: "incoming"}] = serialized.related_people
    end
  end

  describe "relationship_context/2 possible_duplicate pointer (SPEC 04 R11)" do
    test "a pending merge suggestion marker surfaces the other record", %{user_id: user_id} do
      {:ok, dan} = Crm.create_person(user_id, %{"display_name" => "Dan Bourke"})

      {:ok, other} =
        Crm.create_person(user_id, %{
          "display_name" => "Dan",
          "metadata" => %{}
        })

      {:ok, dan} =
        Crm.update_person(dan, %{
          "metadata" => %{
            "merge_suggestion" => %{
              "other_person_id" => other.id,
              "other_display_name" => other.display_name,
              "evidence" => "Same Slack threads about the GTM launch.",
              "status" => "pending"
            }
          }
        })

      assert {:ok, context} = Crm.relationship_context(user_id, %{"person_id" => dan.id})

      assert %{person_id: person_id, display_name: "Dan", evidence: evidence} =
               context.possible_duplicate

      assert person_id == other.id
      assert evidence =~ "GTM launch"

      serialized = Maraithon.Tools.PersonHelpers.serialize_relationship_context(context)
      assert serialized.possible_duplicate.person_id == other.id
    end

    test "no marker or a merged-away other record yields no pointer", %{user_id: user_id} do
      {:ok, plain} = Crm.create_person(user_id, %{"display_name" => "Priya Patel"})

      assert {:ok, context} = Crm.relationship_context(user_id, %{"person_id" => plain.id})
      assert is_nil(context.possible_duplicate)

      serialized = Maraithon.Tools.PersonHelpers.serialize_relationship_context(context)
      refute Map.has_key?(serialized, :possible_duplicate)
    end
  end

  describe "person-edge dedupe and TOCTOU constraint (SPEC 04 R12 invariants)" do
    test "re-attaching the same person edge updates the existing row", %{user_id: user_id} do
      {:ok, mom} = Crm.create_person(user_id, %{"display_name" => "Marla Maharaj"})
      {:ok, emma} = Crm.create_person(user_id, %{"display_name" => "Emma Fenwick"})

      {:ok, first} =
        Crm.attach_resource(user_id, mom.id, %{
          "resource_type" => "person",
          "resource_id" => emma.id,
          "role" => "proxy_for"
        })

      {:ok, second} =
        Crm.attach_resource(user_id, mom.id, %{
          "resource_type" => "person",
          "resource_id" => emma.id,
          "role" => "parent_of"
        })

      assert second.id == first.id
      assert second.role == "parent_of"
      assert length(Crm.list_links_for_person(user_id, mom.id, resource_type: "person")) == 1
    end

    test "a losing insert race hits the composite unique constraint as a changeset error", %{
      user_id: user_id
    } do
      {:ok, mom} = Crm.create_person(user_id, %{"display_name" => "Marla Maharaj"})
      {:ok, emma} = Crm.create_person(user_id, %{"display_name" => "Emma Fenwick"})

      {:ok, _existing} =
        Crm.attach_resource(user_id, mom.id, %{
          "resource_type" => "person",
          "resource_id" => emma.id
        })

      # Simulate the concurrent-window loser: it passed the pre-check before
      # the winner's row landed, so it inserts directly. The composite unique
      # index must turn this into a friendly changeset error on the correct
      # constraint name, not an uncaught constraint-violation exception.
      # NB Postgres truncates index names to 63 chars, so the real index is
      # `..._resource_id_in`, not the untruncated `..._resource_id_index`.
      assert {:error, changeset} =
               %PersonLink{user_id: user_id, person_id: mom.id}
               |> PersonLink.changeset(%{
                 "resource_type" => "person",
                 "resource_id" => emma.id
               })
               |> Repo.insert()

      assert {"has already been taken", opts} = changeset.errors[:resource_id]

      assert Keyword.get(opts, :constraint_name) ==
               "crm_person_links_user_id_person_id_resource_type_resource_id_in"
    end
  end
end
