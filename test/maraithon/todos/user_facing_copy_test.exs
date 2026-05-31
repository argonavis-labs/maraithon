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
          "Draft in your voice: reply to Alex Müller with the direct answer, owner, next step, and ETA.",
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
             "You committed to follow up with Alex Müller (Starteryou) about Starteryou UGC Campaigns. Context: Alex is waiting on the UGC campaign materials decision. No later reply or delivery is recorded."

    assert attrs["next_action"] ==
             "Reply to Alex Müller about Starteryou UGC Campaigns with the promised update, current status, and the next timing you can safely commit to."

    assert attrs["action_plan"] ==
             "Draft in your voice: reply to Alex Müller about Starteryou UGC Campaigns with the actual promise, current status, and timing you can safely stand behind."

    refute attrs["summary"] =~ "User"
    refute attrs["action_plan"] =~ "Kent"
    refute attrs["summary"] =~ "I found"
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
             "You committed to follow up with Michael Berlingo (Starteryou; UGC campaign contact) about Starteryou UGC Campaigns. Context: Michael is waiting on the UGC campaign next-step decision. No later reply or delivery is recorded."

    assert attrs["next_action"] ==
             "Reply to Michael Berlingo about Starteryou UGC Campaigns with the promised update, current status, and the next timing you can safely commit to."

    refute attrs["summary"] =~ "No later reply or follow-through was found"
    refute attrs["summary"] =~ "I found"
    refute attrs["next_action"] =~ "owner, ETA"
  end

  test "preserves explicit thread context when evidence copy is already contextual" do
    attrs =
      UserFacingCopy.polish_attrs(%{
        "title" => "Reply to Michael Berlingo on \"Starteryou UGC Campaigns\".",
        "summary" =>
          "Thread: Starteryou UGC Campaigns. Michael Berlingo is tied to this open thread; no later reply or delivery is recorded.",
        "metadata" => %{
          "from" => "Michael Berlingo <michael@example.com>",
          "subject" => "Starteryou UGC Campaigns",
          "record" => %{"person" => "Michael Berlingo"}
        }
      })

    assert attrs["summary"] ==
             "Thread: Starteryou UGC Campaigns. Michael Berlingo is tied to this open thread; no later reply or delivery is recorded."
  end

  test "strips internal source labels from todo-facing copy" do
    attrs =
      UserFacingCopy.polish_attrs(%{
        "source" => "chief_of_staff_morning_briefing",
        "title" => "Agora getdelegates API errors were flagged",
        "summary" =>
          "Datadog and Sentry surfaced elevated getdelegates API errors for Agora.\nFrom: Chief_of_staff_morning_briefing",
        "notes" =>
          "Source: chief_of_staff_morning_briefing\nPriority: high\nQuote: Elevated getdelegates API errors need owner confirmation.",
        "next_action" =>
          "Ask the engineering owner whether the issue is resolved and whether customers were affected."
      })

    assert attrs["summary"] ==
             "Datadog and Sentry surfaced elevated getdelegates API errors for Agora."

    assert attrs["notes"] == "Quote: Elevated getdelegates API errors need owner confirmation."
    refute attrs["summary"] =~ "From:"
    refute attrs["notes"] =~ "Source:"
    refute attrs["notes"] =~ "Priority:"
    refute attrs["summary"] =~ "chief_of_staff"
    refute attrs["notes"] =~ "chief_of_staff"
  end

  test "naturalizes inline assistant source labels that cannot be dropped" do
    attrs =
      UserFacingCopy.polish_attrs(%{
        "summary" =>
          "This came from chief_of_staff_commitment_tracker after checking the follow-up thread."
      })

    assert attrs["summary"] ==
             "This came from the open work review after checking the follow-up thread."
  end

  test "rewrites model role labels into direct operator-facing copy" do
    assert UserFacingCopy.polish_text(
             "The operator's queue needs operator attention because User should review it."
           ) ==
             "Your queue needs your attention because you should review it."

    assert UserFacingCopy.polish_text("This needs Kent's attention before 3 PM.") ==
             "This needs your attention before 3 PM."
  end

  test "does not rewrite Kent possessives inside named resources" do
    text = "Delete the \"Kent's Gmail agent\" automation."

    assert UserFacingCopy.polish_text(text) == text
    assert UserFacingCopy.open_work_language(text) == text
  end

  test "does not rewrite product user terminology into broken you-language" do
    assert UserFacingCopy.polish_text("Investigate why the user interface flashes after reload.") ==
             "Investigate why the user interface flashes after reload."

    assert UserFacingCopy.polish_text(
             "Keep the user experience stable while updating the user's account settings."
           ) ==
             "Keep the user experience stable while updating the user's account settings."

    assert UserFacingCopy.polish_text("The user should still approve the finance reply.") ==
             "You should still approve the finance reply."

    assert UserFacingCopy.polish_text("Track user response rates during onboarding.") ==
             "Track user response rates during onboarding."
  end

  test "rewrites generic user response and decision copy into direct action copy" do
    assert UserFacingCopy.polish_text("This Gmail thread still needs a user response.") ==
             "This Gmail thread still needs your reply."

    assert UserFacingCopy.polish_text(
             "Rippling needs a user response before onboarding can continue."
           ) ==
             "Rippling needs your reply before onboarding can continue."

    assert UserFacingCopy.polish_text("The billing account needs a user decision.") ==
             "The billing account needs your decision."
  end

  test "rewrites owner ETA and no later reply boilerplate" do
    assert UserFacingCopy.polish_text("Decide whether to send the campaign owner and ETA.") ==
             "Send the campaign update with a clear owner and timing."

    assert UserFacingCopy.polish_text("Michael is waiting and no later reply was found.") ==
             "Michael is waiting; no later reply is recorded."

    assert UserFacingCopy.polish_text(
             "Reply now with owner, ETA, and the exact artifact or update you committed to."
           ) ==
             "Reply with the promised update, current status, and timing you can stand behind."
  end

  test "uses open work language for todo-facing copy" do
    assert UserFacingCopy.polish_text("Here is the full open todo list.") ==
             "Here is the full open work."

    assert UserFacingCopy.polish_text("Added that to your todo list.") ==
             "Added that to your open work."

    assert UserFacingCopy.polish_text("You want this tracked as an ongoing todo.") ==
             "You want this tracked as an ongoing work item."
  end

  test "rewrites internal loop language into executive-facing follow-through copy" do
    assert UserFacingCopy.polish_text("This is the highest-priority open loop.") ==
             "This is the highest-priority open follow-up."

    assert UserFacingCopy.polish_text("Reply in-thread and close the loop.") ==
             "Reply in-thread and send the follow-through."

    assert UserFacingCopy.polish_text("These are mostly reply loops.") ==
             "These are mostly reply threads."
  end

  test "strips model confidence prose while keeping the action copy" do
    assert UserFacingCopy.polish_text("""
           90% confidence this matters.
           Reasoning: model saw a stale executive reply.
           Model score says this is urgent.
           Send Sam the board packet status and next review date.
           """) == "Send Sam the board packet status and next review date."

    assert UserFacingCopy.open_work_language("""
           model_name: gpt-test
           confidence_score: 0.94
           Here is the open todo list.
           """) == "Here is the open work."

    assert UserFacingCopy.polish_text("Track user response rates during onboarding.") ==
             "Track user response rates during onboarding."
  end

  test "strips safe assistant labels without losing useful action copy" do
    labelled = """
    source_context: The user needs to approve the finance reply.
    why_now: Sarah needs the answer before today's cutoff.
    next_action: reply with the approved timing before 3 PM.
    """

    assert UserFacingCopy.polish_text(labelled) ==
             "You need to approve the finance reply. Sarah needs the answer before today's cutoff. Reply with the approved timing before 3 PM."

    assert UserFacingCopy.open_work_language(labelled) ==
             "You need to approve the finance reply.\nSarah needs the answer before today's cutoff.\nReply with the approved timing before 3 PM."

    refute UserFacingCopy.open_work_language(labelled) =~ "source_context"
    refute UserFacingCopy.open_work_language(labelled) =~ "next_action"
    refute UserFacingCopy.open_work_language(labelled) =~ "The user"
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
