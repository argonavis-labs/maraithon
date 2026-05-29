defmodule Maraithon.ActionCardsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ActionCards
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  setup do
    user_id = "action-cards-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _gmail} =
      ConnectedAccounts.upsert_manual(user_id, "gmail", %{
        external_account_id: "kent@runner.now"
      })

    %{user_id: user_id}
  end

  test "builds a 10/10 decision card with person, context, evidence, source health, and a prepared move",
       %{user_id: user_id} do
    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "attention_mode" => "act_now",
          "title" => "Reply to Michael Berlingo on Starteryou UGC Campaigns",
          "summary" => "Michael Berlingo is waiting on Starteryou UGC campaign next steps.",
          "next_action" =>
            "Reply with the recommended campaign next step and ask which asset he wants first.",
          "source_item_id" => "gmail-thread-michael-starteryou",
          "dedupe_key" => "action-card:michael-starteryou",
          "metadata" => %{
            "subject" => "Starteryou UGC Campaigns",
            "why_now" => "Michael is waiting and no later sent reply was found.",
            "source_evidence" =>
              "Michael asked for Starteryou UGC campaign next steps and timing.",
            "confidence" => "high",
            "record" => %{
              "person" => "Michael Berlingo",
              "company" => "Starteryou",
              "relationship_context" => "UGC campaign contact"
            },
            "people" => [
              %{
                "display_name" => "Michael Berlingo",
                "company" => "Starteryou",
                "relationship" => "UGC campaign contact",
                "relationship_strength" => 45
              }
            ]
          }
        }
      ])

    card = ActionCards.for_todo(todo, include_disconnected: false)

    assert card["product_score"]["passed"]
    assert card["product_score"]["score"] == 10
    assert card["headline"] =~ "Michael Berlingo"
    assert get_in(card, ["context_pack", "summary"]) =~ "Starteryou"
    assert ActionCards.evidence_excerpt(card) =~ "UGC campaign next steps"
    assert ActionCards.prepared_action_hint(card) =~ "draft the reply"
    refute Enum.any?(ActionCards.context_items(card), &(&1.label == "Confidence"))
    assert "gmail" in get_in(card, ["source_health", "checked_sources"])
    assert card["decision_prompt"] == "Choose the next move with Michael Berlingo."
    refute card["decision_prompt"] =~ "Decide whether"

    rendered = ActionCards.render_telegram_todo(todo, include_disconnected: false)
    assert rendered =~ "Why now:"
    assert rendered =~ "Prepared:"
    refute rendered =~ "Can handle:"
    assert rendered =~ "Checked Gmail."
  end

  test "telegram source verification copy hides raw source health errors", %{user_id: user_id} do
    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "attention_mode" => "act_now",
          "title" => "Reply to finance on the receipt thread",
          "summary" => "Finance needs a corrected receipt before reimbursement can move.",
          "next_action" => "Send the corrected receipt and ask finance to confirm timing.",
          "source_item_id" => "gmail-thread-finance-receipt",
          "dedupe_key" => "action-card:finance-source-health-error"
        }
      ])

    rendered =
      ActionCards.render_telegram_todo(todo,
        include_disconnected: false,
        source_health_snapshots: [
          %{
            "provider" => "gmail",
            "status" => "error",
            "last_error" => "DBConnection.ConnectionError token=secret stacktrace"
          }
        ]
      )

    assert rendered =~ "Could not fully check Gmail before sending this."
    refute rendered =~ "Source gap"
    refute rendered =~ "Checked:"
    refute rendered =~ "DBConnection"
    refute rendered =~ "token=secret"
    refute rendered =~ "stacktrace"
  end

  test "filters model and scoring metadata out of visible card copy", %{user_id: user_id} do
    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "Review investor terms follow-up",
      summary: "The investor asked whether the financing terms changed.",
      next_action: "Reply with the current financing terms and next review window.",
      source_item_id: "gmail-thread-private-investor",
      dedupe_key: "action-card:private-investor",
      priority: 88,
      status: "open",
      metadata: %{
        "subject" => "Financing terms",
        "why_now" => "90% confidence from the model score says this should interrupt.",
        "urgency_reason" => "Model score says this matters immediately.",
        "source_evidence" => "Model score 91% for thread-private-investor.",
        "source_excerpt" => "The model is 91% confident because of thread-private-investor.",
        "confidence_reason" => "Internal scoring threshold passed.",
        "reasoning" => "LLM reasoning selected this todo.",
        "token" => "secret-token"
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    card = ActionCards.for_todo(todo, include_disconnected: false)
    rendered = ActionCards.render_telegram_todo(todo, include_disconnected: false)

    visible_copy =
      [
        card["headline"],
        card["decision_prompt"],
        card["why_now"],
        get_in(card, ["context_pack", "summary"]),
        ActionCards.evidence_excerpt(card),
        rendered
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    assert visible_copy =~ "The investor asked whether the financing terms changed."
    assert card["why_now"] == "Someone appears to be waiting on a reply or commitment from you."
    refute visible_copy =~ "90%"
    refute visible_copy =~ "91%"
    refute visible_copy =~ "confidence"
    refute visible_copy =~ "model"
    refute visible_copy =~ "Model"
    refute visible_copy =~ "score"
    refute visible_copy =~ "thread-private-investor"
    refute visible_copy =~ "secret-token"
    refute visible_copy =~ "LLM"
  end

  test "stale low-priority work becomes a keep-or-dismiss decision", %{user_id: user_id} do
    five_days_ago =
      DateTime.utc_now()
      |> DateTime.add(-5 * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "Confirm Dan Bourke artifact status",
      summary:
        "Dan Bourke is the A-Team video project contact tied to the open video artifact status commitment.",
      next_action:
        "Ask whether the Dan Bourke video artifact follow-up still matters before spending time on it.",
      source_item_id: "gmail-thread-dan-bourke",
      dedupe_key: "action-card:dan-bourke",
      priority: 40,
      status: "open",
      metadata: %{
        "why_now" => "The old follow-up needs an important-or-dismiss decision.",
        "record" => %{
          "person" => "Dan Bourke",
          "company" => "A-Team",
          "relationship_context" => "video project contact",
          "commitment" => "Dan asked for video artifact status and ETA."
        }
      },
      source_occurred_at: five_days_ago,
      inserted_at: five_days_ago,
      updated_at: five_days_ago
    }

    card = ActionCards.for_todo(todo, include_disconnected: false)

    assert card["product_score"]["passed"]
    assert card["attention_mode"] == "stale_check"
    assert card["headline"] =~ "older follow-up"
    assert card["decision_prompt"] =~ "Keep it active if it still matters"
    assert card["decision_prompt"] =~ "stops resurfacing"
    refute card["decision_prompt"] =~ "I would"
    refute card["decision_prompt"] =~ "not treat it as urgent"
    assert card["why_now"] =~ "keep-or-close decision"
    assert card["next_best_action"] =~ "Keep it active only if it still matters"
    assert "important" in card["available_buttons"]
    assert "dismiss" in card["available_buttons"]

    rendered = ActionCards.render_telegram_todo(todo, include_disconnected: false)
    assert rendered =~ "Should this older follow-up"
    assert rendered =~ "Decision: Keep it active if it still matters"
    refute rendered =~ "older todo"
    refute rendered =~ "stale follow-up"
    refute rendered =~ "not treat it as urgent"
    assert rendered =~ "teach Maraithon"
  end

  test "stale low-priority work without a person avoids legacy todo language", %{user_id: user_id} do
    six_days_ago =
      DateTime.utc_now()
      |> DateTime.add(-6 * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "Review the old ops note",
      summary: "The old ops note may no longer require executive attention.",
      next_action: "Confirm whether the ops note still matters.",
      source_item_id: "gmail-thread-old-ops-note",
      dedupe_key: "action-card:old-ops-note",
      priority: 30,
      status: "open",
      metadata: %{},
      source_occurred_at: six_days_ago,
      inserted_at: six_days_ago,
      updated_at: six_days_ago
    }

    card = ActionCards.for_todo(todo, include_disconnected: false)

    assert card["attention_mode"] == "stale_check"
    assert card["headline"] == "Should this older work item stay active?"

    assert card["confidence"]["reason"] ==
             "Based on saved-work context, evidence, and source freshness."

    rendered = ActionCards.render_telegram_todo(todo, include_disconnected: false)
    assert rendered =~ "Should this older work item stay active?"
    refute rendered =~ "older todo"
    refute card["headline"] =~ "older todo"
    refute card["confidence"]["reason"] =~ "todo context"
  end

  test "legacy generic todo copy is personalized before card rendering", %{user_id: user_id} do
    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "User committed to follow-up with Alex Müller; follow-up not yet sent.",
      summary: "User committed to follow-up with Alex Müller; follow-up not yet sent.",
      next_action:
        "Reply now with owner, ETA, and the exact artifact or update you committed to.",
      source_item_id: "gmail-thread-alex-starteryou",
      dedupe_key: "action-card:alex-starteryou",
      priority: 86,
      status: "open",
      metadata: %{
        "subject" => "Starteryou UGC Campaigns",
        "company" => "Starteryou",
        "why_it_matters" => "Alex is waiting on the UGC campaign materials decision.",
        "source_evidence" => "You said you would follow up on Starteryou UGC campaign timing.",
        "confidence" => "high",
        "record" => %{
          "person" => "Alex Müller",
          "relationship_context" => "Starteryou UGC campaign contact",
          "commitment" => "Follow through on \"Starteryou UGC Campaigns\" for Alex Müller"
        }
      }
    }

    card = ActionCards.for_todo(todo, include_disconnected: false)
    rendered = ActionCards.render_telegram_todo(todo, include_disconnected: false)

    assert card["headline"] == "Follow up with Alex Müller about Starteryou UGC Campaigns"
    assert get_in(card, ["context_pack", "summary"]) =~ "Alex Müller"
    assert get_in(card, ["context_pack", "summary"]) =~ "Starteryou"
    assert get_in(card, ["context_pack", "summary"]) =~ "UGC campaign contact"
    assert card["next_best_action"] =~ "Reply to Alex Müller about Starteryou UGC Campaigns"
    assert rendered =~ "You committed to follow up"
    refute rendered =~ "User committed"
    refute rendered =~ "owner, ETA"
    refute rendered =~ "exact artifact or update"
  end
end
