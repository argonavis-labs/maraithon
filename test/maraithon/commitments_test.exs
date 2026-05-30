defmodule Maraithon.CommitmentsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Commitments

  setup do
    user_id = "commitments-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  test "upserts and buckets open commitments for a morning brief", %{user_id: user_id} do
    now = ~U[2026-05-07 14:00:00Z]

    {:ok, overdue} =
      Commitments.upsert(user_id, %{
        "source" => "omnifocus",
        "source_id" => "of-1",
        "title" => "Send Sarah the deck",
        "owed_to" => "Sarah",
        "project" => "Runner",
        "due_at" => "2026-05-06T18:00:00Z",
        "priority" => 95,
        "evidence" => ["Captured from commitment tracker"]
      })

    {:ok, _updated} =
      Commitments.upsert(user_id, %{
        "source" => "omnifocus",
        "source_id" => "of-1",
        "title" => "Send Sarah the final deck",
        "owed_to" => "Sarah",
        "project" => "Runner",
        "due_at" => "2026-05-06T18:00:00Z",
        "priority" => 96
      })

    assert [%{id: id, title: "Send Sarah the final deck"}] =
             Commitments.list_open_for_user(user_id)

    assert id == overdue.id

    bucket =
      Commitments.bucket_for_brief(user_id,
        now: now,
        timezone_offset_hours: -4,
        timezone_label: "ET"
      )

    assert bucket["source"] == "commitments"
    assert bucket["active_count"] == 1

    assert [
             %{
               "title" => "Send Sarah the final deck",
               "owed_to" => "Sarah",
               "display_due" => "May 6, 2026 at 2:00 PM ET"
             }
           ] = bucket["overdue"]

    assert bucket["due_today"] == []
  end
end
