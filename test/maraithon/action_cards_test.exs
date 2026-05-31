defmodule Maraithon.ActionCardsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ActionCards
  alias Maraithon.Agents
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
    assert ActionCards.prepared_action_hint(card) == "Draft the reply for approval."
    refute Enum.any?(ActionCards.context_items(card), &(&1.label == "Confidence"))
    assert "gmail" in get_in(card, ["source_health", "checked_sources"])
    assert card["decision_prompt"] == "Choose the next move with Michael Berlingo."
    refute card["decision_prompt"] =~ "Decide whether"
    assert "helpful" in card["available_buttons"]
    assert "not_helpful" in card["available_buttons"]
    refute "important" in card["available_buttons"]
    refute "keep_active" in card["available_buttons"]

    rendered = ActionCards.render_telegram_todo(todo, include_disconnected: false)
    assert rendered =~ "Why now:"
    assert rendered =~ "Prepared:"
    refute rendered =~ "Can handle:"
    assert rendered =~ "Context used: Gmail."
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

    assert rendered =~ "Gmail context is incomplete; review the source before sending this."
    refute rendered =~ "Source gap"
    refute rendered =~ "Checked:"
    refute rendered =~ "DBConnection"
    refute rendered =~ "token=secret"
    refute rendered =~ "stacktrace"
  end

  test "missing person context copy avoids internal CRM language", %{user_id: user_id} do
    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "Review the finance approval note",
      summary: "Finance needs approval before sending the reimbursement note.",
      next_action: "Review the note and approve the reimbursement reply.",
      source_item_id: "gmail-thread-finance-approval",
      dedupe_key: "action-card:missing-person-context",
      priority: 86,
      status: "open",
      metadata: %{
        "source_evidence" => "Finance needs approval before the reimbursement reply is sent."
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    card = ActionCards.for_todo(todo, include_disconnected: false)
    missing_context = get_in(card, ["context_pack", "missing_context"])

    assert missing_context == "No person has been confirmed for this item yet."

    assert card["decision_prompt"] ==
             "Decide whether to review the note and approve the reimbursement reply."

    refute missing_context =~ "CRM"
    refute card["decision_prompt"] =~ "Handle this now"
  end

  test "infers a clear person from action copy when metadata is missing",
       %{user_id: user_id} do
    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "Send Sarah the investor deck",
      summary: "Sarah asked for the investor deck before the partner meeting.",
      next_action: "Send Sarah the current deck and confirm what else she needs.",
      source_item_id: "gmail-thread-sarah-deck",
      dedupe_key: "action-card:infer-sarah",
      priority: 88,
      status: "open",
      metadata: %{
        "subject" => "Investor deck",
        "source_evidence" => "Sarah asked for the investor deck before the partner meeting."
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    card = ActionCards.for_todo(todo, include_disconnected: false)

    assert %{label: "Person", value: "Sarah"} in ActionCards.context_items(card)
    assert card["decision_prompt"] == "Choose the next move with Sarah."
    assert get_in(card, ["context_pack", "missing_context"]) == nil
    assert get_in(card, ["context_pack", "summary"]) =~ "Sarah asked"
    refute card["decision_prompt"] =~ "Decide whether"
  end

  test "does not infer generic capitalized nouns as people", %{user_id: user_id} do
    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "Send Finance the corrected receipt",
      summary: "The reimbursement thread needs a corrected receipt.",
      next_action: "Send the corrected receipt and ask finance to confirm timing.",
      source_item_id: "gmail-thread-finance-receipt",
      dedupe_key: "action-card:no-finance-person",
      priority: 86,
      status: "open",
      metadata: %{
        "source_evidence" => "Finance asked for a corrected receipt."
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    card = ActionCards.for_todo(todo, include_disconnected: false)

    refute Enum.any?(ActionCards.context_items(card), &(&1.label == "Person"))

    assert get_in(card, ["context_pack", "missing_context"]) ==
             "No person has been confirmed for this item yet."
  end

  test "cards do not surface unknown or unclear state filler", %{user_id: user_id} do
    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "github",
      kind: "general",
      attention_mode: "act_now",
      title: "Review the design note",
      summary: "The design note needs review before this week's planning.",
      next_action: "Review the design note and choose whether it belongs this week.",
      source_item_id: "github-issue-design-note",
      dedupe_key: "action-card:no-state-filler",
      priority: 72,
      status: "open",
      metadata: %{
        "source_evidence" => "The design note asks for input before planning."
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    card = ActionCards.for_todo(todo, include_disconnected: false)
    rendered = ActionCards.render_telegram_todo(todo, include_disconnected: false)

    refute Enum.any?(
             ActionCards.context_items(card),
             &(&1.label in ["State", "Thread state", "Owed", "Responsibility"])
           )

    assert "thread_or_owed_state" in card["product_score"]["missing"]
    refute rendered =~ "State:"
    refute rendered =~ "Unknown"
    refute rendered =~ "Unclear"
  end

  test "open work without timing evidence becomes a keep-or-dismiss decision", %{
    user_id: user_id
  } do
    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "chief_of_staff_morning_briefing",
      kind: "general",
      attention_mode: "act_now",
      title: "Review generated operating note",
      summary: "Maraithon created this work item from its own operating context.",
      next_action: "Review the note and decide whether it belongs in open work.",
      source_item_id: nil,
      dedupe_key: "action-card:generated-source-default-why",
      priority: 72,
      status: "open",
      metadata: %{},
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    card = ActionCards.for_todo(todo, include_disconnected: false)
    rendered = ActionCards.render_telegram_todo(todo, include_disconnected: false)

    assert card["why_now"] ==
             "No deadline or waiting signal is attached; decide whether to keep it active or dismiss it."

    assert rendered =~
             "Why now: No deadline or waiting signal is attached; decide whether to keep it active or dismiss it."

    refute rendered =~ "This is still open and needs a clear next decision"
    refute rendered =~ "this Maraithon item"
    refute rendered =~ "account unknown"
  end

  test "preview cards avoid generic review-item fallback copy", %{user_id: user_id} do
    card =
      ActionCards.for_todo(%{
        "id" => Ecto.UUID.generate(),
        "user_id" => user_id,
        "source" => "manual",
        "kind" => "general",
        "attention_mode" => "act_now",
        "title" => "",
        "summary" => "",
        "next_action" => "",
        "dedupe_key" => "action-card:preview-fallback-copy",
        "metadata" => %{}
      })

    rendered =
      ActionCards.render_telegram_todo(%{
        "id" => Ecto.UUID.generate(),
        "user_id" => user_id,
        "source" => "manual",
        "kind" => "general",
        "attention_mode" => "act_now",
        "title" => "",
        "summary" => "",
        "next_action" => "",
        "dedupe_key" => "action-card:preview-fallback-copy-rendered",
        "metadata" => %{}
      })

    assert card["headline"] == "Review open work"

    assert card["decision_prompt"] ==
             "Choose whether to keep, delegate, or dismiss this work."

    assert rendered =~ "Review open work"
    assert rendered =~ "keep, delegate, or dismiss"
    refute rendered =~ "Review this item"
    refute rendered =~ "Open todo"
  end

  test "waiting state copy uses operator-facing language instead of raw state keys",
       %{user_id: user_id} do
    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "Reply to Michael Berlingo about Starteryou UGC Campaigns",
      summary: "Michael asked for the next Starteryou UGC campaign update.",
      next_action: "Reply to Michael with the campaign update and next timing.",
      source_item_id: "gmail-thread-michael-state",
      dedupe_key: "action-card:waiting-state-copy",
      priority: 88,
      status: "open",
      metadata: %{
        "thread_state" => "waiting_on_kent",
        "source_evidence" => "Michael asked for the next Starteryou UGC campaign update.",
        "record" => %{
          "person" => "Michael Berlingo",
          "company" => "Starteryou",
          "relationship_context" => "UGC campaign contact"
        }
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    card = ActionCards.for_todo(todo, include_disconnected: false)
    rendered = ActionCards.render_telegram_todo(todo, include_disconnected: false)

    assert %{label: "State", value: "Waiting on you"} in ActionCards.context_items(card)
    assert rendered =~ "State: Waiting on you"
    refute rendered =~ "waiting_on_kent"
    refute rendered =~ "Kent"
    refute rendered =~ "Unknown"
    refute rendered =~ "Unclear"
  end

  test "source health copy humanizes local source names" do
    card = %{
      "source_health" => %{
        "checked_sources" => ["voice_memos", "browser_history", "google_calendar"]
      }
    }

    assert ActionCards.source_health_note(card) ==
             "Used Voice Memos, Browser History, Google Calendar."

    refute ActionCards.source_health_note(card) =~ "_"
  end

  test "source health copy distinguishes checked inbox from missing Mac companion" do
    card = %{
      "source_health" => %{
        "checked_sources" => ["gmail", "desktop"],
        "blocking_gaps" => ["desktop: not connected"],
        "setup_suggestion" =>
          "Connect the Maraithon Mac companion app to include iMessage, Apple Notes, files, reminders, and local context securely."
      }
    }

    assert ActionCards.source_health_note(card) ==
             "Used Gmail. Local context from the Mac companion is unavailable. Open the Mac companion app to reconnect it."

    refute ActionCards.source_health_note(card) =~ "Could not fully check Desktop App"
  end

  test "source health only reports sources that back the decision", %{user_id: user_id} do
    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "Reply to finance on the receipt thread",
      summary: "Finance needs a corrected receipt before reimbursement can move.",
      next_action: "Send the corrected receipt and ask finance to confirm timing.",
      source_item_id: "gmail-thread-finance-receipt",
      dedupe_key: "action-card:finance-checked-source",
      priority: 86,
      status: "open",
      metadata: %{
        "source_evidence" => "Finance asked for a corrected receipt."
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    card =
      ActionCards.for_todo(todo,
        include_disconnected: true,
        source_health_snapshots: [
          %{"provider" => "gmail", "status" => "fresh"},
          %{"provider" => "telegram", "status" => "fresh"}
        ]
      )

    assert ActionCards.source_health_note(card) == "Used Gmail."
    refute ActionCards.source_health_note(card) =~ "Telegram"
  end

  test "business inbox cards do not promote the Mac companion when local context is not relevant",
       %{user_id: user_id} do
    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "Reply to Michael Berlingo on Starteryou UGC Campaigns",
      summary: "Michael Berlingo is waiting on Starteryou UGC campaign next steps.",
      next_action:
        "Reply with the recommended campaign next step and ask which asset he wants first.",
      source_item_id: "gmail-thread-michael-starteryou",
      dedupe_key: "action-card:michael-starteryou-source-gap",
      priority: 88,
      status: "open",
      metadata: %{
        "subject" => "Starteryou UGC Campaigns",
        "source_evidence" => "Michael asked for Starteryou UGC campaign next steps and timing.",
        "record" => %{
          "person" => "Michael Berlingo",
          "company" => "Starteryou",
          "relationship_context" => "UGC campaign contact"
        }
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    opts = [
      include_disconnected: true,
      source_health_snapshots: [%{"provider" => "gmail", "status" => "fresh"}]
    ]

    card = ActionCards.for_todo(todo, opts)
    rendered = ActionCards.render_telegram_todo(todo, opts)

    assert ActionCards.source_health_note(card) == "Used Gmail."
    assert get_in(card, ["source_health", "missing_sources"]) == []
    refute rendered =~ "Mac companion"
    refute rendered =~ "Local context"
  end

  test "personal logistics cards surface the Mac companion gap when local context would help",
       %{user_id: user_id} do
    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "Reply to school about Tuesday pickup change",
      summary: "The school asked whether Tuesday pickup should move to 4 PM.",
      next_action: "Confirm the Tuesday pickup plan with the school.",
      source_item_id: "gmail-thread-school-pickup",
      dedupe_key: "action-card:school-pickup-source-gap",
      priority: 92,
      status: "open",
      metadata: %{
        "life_domain" => "family",
        "source_evidence" => "The school asked whether Tuesday pickup should move to 4 PM.",
        "record" => %{
          "person" => "Oak Street School",
          "relationship_context" => "school logistics"
        }
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    opts = [
      include_disconnected: true,
      source_health_snapshots: [%{"provider" => "gmail", "status" => "fresh"}]
    ]

    card = ActionCards.for_todo(todo, opts)

    assert get_in(card, ["source_health", "missing_sources"]) == ["desktop"]

    assert ActionCards.source_health_note(card) ==
             "Used Gmail. Local context from the Mac companion is unavailable. Open the Mac companion app to reconnect it."

    assert ActionCards.render_telegram_todo(todo, opts) =~
             "Local context from the Mac companion is unavailable."
  end

  test "due copy uses the user's Chief of Staff timezone instead of UTC", %{user_id: user_id} do
    {:ok, _agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{"timezone" => "America/Toronto", "timezone_offset_hours" => -5}
      })

    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "Send the board packet",
      summary: "The board packet is due before the afternoon review.",
      next_action: "Send the board packet and confirm the review window.",
      source_item_id: "gmail-thread-board-packet",
      dedupe_key: "action-card:board-packet-due",
      due_at: ~U[2026-05-30 18:30:00Z],
      priority: 90,
      status: "open",
      metadata: %{},
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    card = ActionCards.for_todo(todo, include_disconnected: false)
    rendered = ActionCards.render_telegram_todo(todo, include_disconnected: false)

    assert card["why_now"] == "Due May 30 at 2:30 PM ET."
    assert rendered =~ "Due May 30 at 2:30 PM ET."
    refute rendered =~ "UTC"
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
    assert card["why_now"] == "The investor asked whether the financing terms changed."
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

  test "polishes public metadata before rendering decision cards", %{user_id: user_id} do
    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      source: "gmail",
      kind: "gmail_triage",
      attention_mode: "act_now",
      title: "Approve the finance reply",
      summary: "Finance is waiting on a corrected reimbursement note.",
      next_action: "Send the corrected reimbursement note.",
      source_item_id: "gmail-thread-finance-approval",
      dedupe_key: "action-card:finance-public-metadata-copy",
      priority: 90,
      status: "open",
      metadata: %{
        "why_now" => """
        source_context: The user needs to approve the finance reply.
        telegram_fit_score: 0.94
        The operator's next move is to review the reimbursement note.
        """
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    card = ActionCards.for_todo(todo, include_disconnected: false)
    rendered = ActionCards.render_telegram_todo(todo, include_disconnected: false)

    assert card["why_now"] ==
             "You need to approve the finance reply. Your next move is to review the reimbursement note."

    assert rendered =~ "You need to approve the finance reply."
    refute rendered =~ "source_context"
    refute rendered =~ "telegram_fit_score"
    refute rendered =~ "The user"
    refute rendered =~ "operator"
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
    assert "keep_active" in card["available_buttons"]
    assert "dismiss" in card["available_buttons"]
    refute "important" in card["available_buttons"]

    rendered = ActionCards.render_telegram_todo(todo, include_disconnected: false)
    assert rendered =~ "Should this older follow-up"
    assert rendered =~ "Decision: Keep it active if it still matters"
    refute rendered =~ "older todo"
    refute rendered =~ "stale follow-up"
    refute rendered =~ "not treat it as urgent"

    assert rendered =~
             "This choice helps Maraithon keep older work visible only when it still matters."

    refute rendered =~ "teach Maraithon"
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
             "Based on saved work, evidence, and available context."

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
