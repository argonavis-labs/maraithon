defmodule Maraithon.Crm.PersonDeduperTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Crm.PersonDeduper

  test "merges active people that share a durable email identifier" do
    user_id = "person-deduper-email-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, survivor} =
      Crm.create_person(user_id, %{
        "display_name" => "Charlie Feng",
        "email" => "charlie@runner.now",
        "relationship_strength" => 80,
        "communication_score" => 60
      })

    {:ok, duplicate} =
      Crm.create_person(user_id, %{
        "display_name" => "Charles Feng",
        "email" => "charlie@runner.now",
        "slack_id" => "UCHARLIE"
      })

    assert {:ok, result} = PersonDeduper.run(user_id, max_merges: 5)
    assert result.source == "person_deduper"
    assert result.merged == 1
    assert result.failed == 0

    assert Crm.get_person_for_user(user_id, duplicate.id).merged_into_id == survivor.id

    reloaded = Crm.get_person_for_user(user_id, survivor.id)
    assert "charlie@runner.now" in reloaded.contact_details["emails"]
    assert "UCHARLIE" in reloaded.contact_details["slack_ids"]
  end

  test "only merges shared phone records when the display name also matches" do
    user_id = "person-deduper-phone-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, duncan_one} =
      Crm.create_person(user_id, %{
        "display_name" => "Duncan Lang",
        "phone" => "+1 (905) 235-1303",
        "relationship_strength" => 40
      })

    {:ok, duncan_two} =
      Crm.create_person(user_id, %{
        "display_name" => "Duncan Lang",
        "phone" => "905-235-1303"
      })

    {:ok, other_person} =
      Crm.create_person(user_id, %{
        "display_name" => "Dana Lang",
        "phone" => "905-235-1303"
      })

    assert {:ok, result} = PersonDeduper.run(user_id, max_merges: 5)
    assert result.merged == 1

    assert Crm.get_person_for_user(user_id, duncan_two.id).merged_into_id == duncan_one.id
    assert Crm.get_person_for_user(user_id, other_person.id).status == "active"
  end

  test "does not merge shared identifier clusters when full names conflict" do
    user_id = "person-deduper-conflict-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, laura_niblett} =
      Crm.create_person(user_id, %{
        "display_name" => "Laura Niblett",
        "email" => "laura@example.com",
        "slack_id" => "@laura"
      })

    {:ok, laura} =
      Crm.create_person(user_id, %{
        "display_name" => "Laura",
        "email" => "laura@example.com",
        "slack_id" => "@laura"
      })

    {:ok, laura_makaltses} =
      Crm.create_person(user_id, %{
        "display_name" => "Laura Makaltses",
        "email" => "laura@example.com",
        "slack_id" => "@laura"
      })

    assert {:ok, result} = PersonDeduper.run(user_id, max_merges: 5)
    assert result.merged == 0

    assert Crm.get_person_for_user(user_id, laura_niblett.id).status == "active"
    assert Crm.get_person_for_user(user_id, laura.id).status == "active"
    assert Crm.get_person_for_user(user_id, laura_makaltses.id).status == "active"
  end

  test "merges exact full-name duplicates without shared identifiers" do
    user_id = "person-deduper-name-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, survivor} =
      Crm.create_person(user_id, %{
        "display_name" => "Frank Giannone",
        "relationship_strength" => 80
      })

    {:ok, duplicate} =
      Crm.create_person(user_id, %{
        "display_name" => "Frank Giannone",
        "notes" => "Family context from goal discovery."
      })

    assert {:ok, result} = PersonDeduper.run(user_id, max_merges: 5)
    assert result.merged == 1

    assert Crm.get_person_for_user(user_id, duplicate.id).merged_into_id == survivor.id
  end

  test "does not merge exact single-token names without shared identifiers" do
    user_id = "person-deduper-single-name-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, first} = Crm.create_person(user_id, %{"display_name" => "David"})
    {:ok, second} = Crm.create_person(user_id, %{"display_name" => "David"})

    assert {:ok, result} = PersonDeduper.run(user_id, max_merges: 5)
    assert result.merged == 0

    assert Crm.get_person_for_user(user_id, first.id).status == "active"
    assert Crm.get_person_for_user(user_id, second.id).status == "active"
  end

  test "dry run reports groups without mutating people" do
    user_id = "person-deduper-dry-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, first} =
      Crm.create_person(user_id, %{
        "display_name" => "Jeff McLarty",
        "email" => "jeff@example.com"
      })

    {:ok, second} =
      Crm.create_person(user_id, %{
        "display_name" => "Jeff McLarty",
        "email" => "jeff@example.com"
      })

    assert {:ok, result} = PersonDeduper.run(user_id, dry_run: true)
    assert result.mode == "dry_run"
    assert [%{evidence: evidence}] = result.groups
    assert Enum.any?(evidence, &String.contains?(&1, "Shared email"))

    assert Crm.get_person_for_user(user_id, first.id).status == "active"
    assert Crm.get_person_for_user(user_id, second.id).status == "active"
  end
end
