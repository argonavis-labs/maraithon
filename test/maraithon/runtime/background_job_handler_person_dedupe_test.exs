defmodule Maraithon.Runtime.BackgroundJobHandlerPersonDedupeTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobHandler

  test "executes the person_dedupe job" do
    user_id = "person-dedupe-handler-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, survivor} =
      Crm.create_person(user_id, %{
        "display_name" => "Jeff McLarty",
        "email" => "jeff@example.com",
        "relationship_strength" => 80
      })

    {:ok, duplicate} =
      Crm.create_person(user_id, %{
        "display_name" => "Jeff McLarty",
        "email" => "jeff@example.com"
      })

    job = %BackgroundJob{
      user_id: user_id,
      job_type: "person_dedupe",
      queue: "relationships",
      payload: %{"people_limit" => 50, "group_limit" => 10, "max_merges" => 5}
    }

    assert {:ok, result} = BackgroundJobHandler.execute(job)
    assert result.source == "person_deduper"
    assert result.merged == 1
    assert Crm.get_person_for_user(user_id, duplicate.id).merged_into_id == survivor.id
  end
end
