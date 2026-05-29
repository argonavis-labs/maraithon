defmodule Maraithon.Crm.InsightsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Crm.Insights
  alias Maraithon.Crm.Observation

  setup do
    user_id = "crm-insights-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  test "returns duplicate suggestions for exact display-name duplicates", %{user_id: user_id} do
    {:ok, _first} =
      Crm.create_person(user_id, %{
        "display_name" => "Christina Giannone",
        "email" => "christina@example.com"
      })

    {:ok, _second} =
      Crm.create_person(user_id, %{
        "display_name" => "Christina Giannone",
        "email" => "cgiannone@example.com"
      })

    result = Insights.list_for_user(user_id)

    assert Enum.any?(result.duplicate_suggestions, fn suggestion ->
             suggestion.title == "Possible duplicate: Christina Giannone" and
               Enum.any?(suggestion.evidence, &(&1.label == "Exact name match"))
           end)
  end

  test "returns duplicate suggestions for overlapping contact details", %{user_id: user_id} do
    {:ok, _first} =
      Crm.create_person(user_id, %{
        "display_name" => "Marina Giannone",
        "email" => "marina@example.com"
      })

    {:ok, _second} =
      Crm.create_person(user_id, %{
        "display_name" => "Marina G",
        "email" => "marina@example.com"
      })

    result = Insights.list_for_user(user_id)

    assert Enum.any?(result.duplicate_suggestions, fn suggestion ->
             suggestion.summary =~ "Marina Giannone" and
               Enum.any?(suggestion.evidence, &(&1.label == "Shared email"))
           end)
  end

  test "returns relationship suggestions from person notes", %{user_id: user_id} do
    {:ok, _person} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Christina Giannone",
        "first_name" => "Christina",
        "notes" => "Christina is my wife and helps coordinate family plans."
      })

    result = Insights.list_for_user(user_id)

    assert [suggestion] = result.relationship_suggestions
    assert suggestion.title == "Review relationship: Christina Giannone as your wife"
    assert suggestion.summary =~ "Confirm before updating Christina Giannone's People profile."
    refute suggestion.summary =~ "CRM"
    refute suggestion.title =~ "I think"
    assert suggestion.relationship == "wife"
    assert Enum.any?(suggestion.evidence, &(&1.source == "Person notes"))
  end

  test "returns relationship suggestions from relationship observations", %{user_id: user_id} do
    {:ok, emma} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Emma Fenwick",
        "first_name" => "Emma"
      })

    {:ok, _observation} =
      %Observation{}
      |> Observation.changeset(%{
        "user_id" => user_id,
        "source" => "gmail",
        "source_item_id" => "relationship-emma-1",
        "occurred_at" => DateTime.utc_now(),
        "direction" => "inbound",
        "subject" => "Emma is your daughter",
        "excerpt" => "Reminder that Emma is your daughter and has school pickup today.",
        "resolved_person_ids" => [emma.id]
      })
      |> Repo.insert()

    result = Insights.list_for_user(user_id)

    assert [suggestion] = result.relationship_suggestions
    assert suggestion.title == "Review relationship: Emma Fenwick as your daughter"
    assert suggestion.summary =~ "source evidence"
    refute suggestion.title =~ "I think"
    assert suggestion.relationship == "daughter"
    assert Enum.any?(suggestion.evidence, &(&1.source == "Relationship observation"))
  end

  test "does not suggest relationships when the person already has one", %{user_id: user_id} do
    {:ok, _person} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Jack Fenwick",
        "first_name" => "Jack",
        "relationship" => "son",
        "notes" => "Jack is your son."
      })

    result = Insights.list_for_user(user_id)

    refute Enum.any?(result.relationship_suggestions, &(&1.relationship == "son"))
  end
end
