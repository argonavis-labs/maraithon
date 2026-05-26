defmodule Maraithon.Todos.UserFacingCopyTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Repo
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo
  alias Maraithon.Todos.UserFacingCopy

  test "polishes generic model commitment copy into direct contextual copy" do
    attrs =
      UserFacingCopy.polish_attrs(%{
        "source" => "gmail",
        "title" => "User committed to follow-up with Alex Müller; follow-up not yet sent.",
        "summary" => "User committed to follow-up with Alex Müller; follow-up not yet sent.",
        "next_action" =>
          "Reply now with owner, ETA, and the exact artifact or update you committed to.",
        "action_plan" =>
          "Draft as Kent: reply to Alex Müller with the direct answer, owner, next step, and ETA.",
        "metadata" => %{
          "subject" => "Starteryou UGC Campaigns",
          "to" => "Alex Müller <alex@starteryou.example>",
          "company" => "Starteryou",
          "why_it_matters" => "Alex is waiting on the UGC campaign materials decision",
          "record" => %{
            "person" => "Alex Müller",
            "commitment" => "Follow through on \"Starteryou UGC Campaigns\" for Alex Müller"
          }
        }
      })

    assert attrs["title"] == "Follow up with Alex Müller about Starteryou UGC Campaigns"

    assert attrs["summary"] ==
             "You committed to follow up with Alex Müller (Starteryou) about Starteryou UGC Campaigns. Context: Alex is waiting on the UGC campaign materials decision. I found no later reply or delivery that clearly closes the loop."

    assert attrs["next_action"] ==
             "Reply to Alex Müller about Starteryou UGC Campaigns with the promised update, current status, and the next timing you can safely commit to."

    assert attrs["action_plan"] ==
             "Draft as Kent: reply to Alex Müller about Starteryou UGC Campaigns with the actual promise, current status, and timing you can safely stand behind."

    refute attrs["summary"] =~ "User"
  end

  test "falls back to source-thread confirmation when exact ask is missing" do
    attrs =
      UserFacingCopy.polish_attrs(%{
        "title" => "User committed to follow-up with Alex Müller; follow-up not yet sent.",
        "summary" => "User committed to follow-up with Alex Müller; follow-up not yet sent.",
        "next_action" => "Send the promised follow-through now.",
        "metadata" => %{
          "to" => "Alex Müller <alex@example.com>",
          "record" => %{"person" => "Alex Müller"}
        }
      })

    assert attrs["title"] == "Clarify the follow-up with Alex Müller"
    assert attrs["summary"] =~ "You committed to follow up with Alex Müller."

    assert attrs["next_action"] ==
             "Open the source thread for Alex Müller, confirm what they need and what you promised, then reply with the next step and timing."
  end

  test "recovers company and topic from email domain and evidence when metadata is thin" do
    attrs =
      UserFacingCopy.polish_attrs(%{
        "title" => "User committed to follow-up with Alex Müller; follow-up not yet sent.",
        "summary" => "No later reply or follow-through was found in the conversation.",
        "next_action" =>
          "Reply now with owner, ETA, and the exact artifact or update you committed to.",
        "metadata" => %{
          "from" => "Alex Müller <alex@mail.starteryou.com>",
          "record" => %{
            "person" => "Alex Müller",
            "evidence" => [
              %{"quote" => "Can you send the UGC campaign creator shortlist by Friday?"}
            ]
          }
        }
      })

    assert attrs["summary"] =~ "Alex Müller (Starteryou)"
    assert attrs["summary"] =~ "UGC campaign creator shortlist by Friday"
    assert attrs["next_action"] =~ "Reply to Alex Müller about UGC campaign creator shortlist"
  end

  test "rewrites no-later-reply summaries and owner ETA boilerplate" do
    attrs =
      UserFacingCopy.polish_attrs(%{
        "source" => "gmail",
        "title" => "Reply to Michael Berlingo on \"Starteryou UGC Campaigns\".",
        "summary" => "No later reply or follow-through was found in the conversation.",
        "next_action" =>
          "Reply now with owner, ETA, and the exact artifact or update you committed to.",
        "metadata" => %{
          "from" => "Michael Berlingo <michael@example.com>",
          "subject" => "Starteryou UGC Campaigns",
          "why_it_matters" => "Michael is waiting on the UGC campaign next-step decision",
          "record" => %{
            "person" => "Michael Berlingo",
            "company" => "Starteryou",
            "relationship_context" => "UGC campaign contact"
          }
        }
      })

    assert attrs["title"] == "Reply to Michael Berlingo on \"Starteryou UGC Campaigns\"."

    assert attrs["summary"] ==
             "You committed to follow up with Michael Berlingo (Starteryou; UGC campaign contact) about Starteryou UGC Campaigns. Context: Michael is waiting on the UGC campaign next-step decision. I found no later reply or delivery that clearly closes the loop."

    assert attrs["next_action"] ==
             "Reply to Michael Berlingo about Starteryou UGC Campaigns with the promised update, current status, and the next timing you can safely commit to."

    refute attrs["summary"] =~ "No later reply"
    refute attrs["next_action"] =~ "owner, ETA"
  end

  test "todo upsert applies copy polish before persistence" do
    user_id = "copy-polish-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, [todo]} =
             Todos.upsert_many(user_id, [
               %{
                 "source" => "gmail",
                 "title" =>
                   "User committed to follow-up with Alex Müller; follow-up not yet sent.",
                 "summary" =>
                   "User committed to follow-up with Alex Müller; follow-up not yet sent.",
                 "next_action" =>
                   "Reply now with owner, ETA, and the exact artifact or update you committed to.",
                 "dedupe_key" => "gmail:alex-muller:starteryou",
                 "metadata" => %{
                   "subject" => "Starteryou UGC Campaigns",
                   "company" => "Starteryou",
                   "record" => %{"person" => "Alex Müller"}
                 }
               }
             ])

    assert todo.title == "Follow up with Alex Müller about Starteryou UGC Campaigns"
    assert todo.summary =~ "You committed to follow up with Alex Müller (Starteryou)"
    assert todo.next_action =~ "Reply to Alex Müller about Starteryou UGC Campaigns"
  end

  test "todo reads polish legacy persisted copy without a migration" do
    user_id = "legacy-copy-polish-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    legacy =
      Repo.insert!(%Todo{
        user_id: user_id,
        owner_user_id: user_id,
        source: "gmail",
        kind: "gmail_triage",
        attention_mode: "act_now",
        title: "User committed to follow-up with Alex Müller; follow-up not yet sent.",
        summary: "User committed to follow-up with Alex Müller; follow-up not yet sent.",
        next_action:
          "Reply now with owner, ETA, and the exact artifact or update you committed to.",
        dedupe_key: "legacy:gmail:alex-muller:starteryou",
        status: "open",
        metadata: %{
          "subject" => "Starteryou UGC Campaigns",
          "company" => "Starteryou",
          "record" => %{"person" => "Alex Müller"}
        }
      })

    read_back = Todos.get_for_user(user_id, legacy.id)
    [listed] = Todos.list_for_user(user_id, query: "Alex", limit: 5)

    assert read_back.title == "Follow up with Alex Müller about Starteryou UGC Campaigns"
    assert read_back.next_action =~ "Reply to Alex Müller about Starteryou UGC Campaigns"
    assert listed.title == read_back.title
    refute read_back.summary =~ "User committed"
  end
end
