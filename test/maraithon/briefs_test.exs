defmodule Maraithon.BriefsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.DeliveryErrorCopy
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.BriefTodoReview
  alias Maraithon.TelegramAssistant.ProactiveCandidate
  alias Maraithon.TelegramAssistant.TodoActions
  alias Maraithon.TelegramConversations
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  setup do
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])
    original_insights = Application.get_env(:maraithon, :insights, [])

    Application.put_env(:maraithon, :briefs,
      telegram_module: Maraithon.TestSupport.CapturingTelegram
    )

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_full_chat_enabled: true,
        telegram_unified_push_enabled: false,
        proactive_delivery_planner_enabled: false
      )
    )

    Application.put_env(:maraithon, :insights,
      telegram_module: Maraithon.TestSupport.CapturingTelegram
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :briefs)
      Application.delete_env(:maraithon, :failing_telegram)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
      Application.put_env(:maraithon, :insights, original_insights)
    end)

    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    Repo.delete_all(Brief)

    user_id = "briefs-user@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "777123",
        metadata: %{"username" => "briefs"}
      })

    %{user_id: user_id, agent: agent}
  end

  test "dispatches pending briefs to Telegram", %{user_id: user_id, agent: agent} do
    scheduled_for = DateTime.utc_now()

    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning brief: 2 loops worth watching",
               "summary" => "Two high-signal loops look open this morning.",
               "body" => "- [Gmail] Send the deck\n- [Slack] Post owners and next steps",
               "scheduled_for" => scheduled_for,
               "dedupe_key" => "brief:morning:test"
             })

    result = Briefs.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    [message] = Agent.get(:capturing_telegram_recorder, & &1)

    updated = Repo.get!(Brief, brief.id)
    assert updated.status == "sent"
    assert updated.provider_message_id == message.message_id

    assert message.type == :send
    assert message.chat_id == "777123"
    assert message.text =~ "Morning brief"
    refute message.text =~ "Scheduled for"
    assert get_in(message.opts, [:reply_markup, "inline_keyboard"]) != nil
  end

  test "empty briefing fallback copy uses review-ready language", %{
    user_id: user_id,
    agent: agent
  } do
    assert {:ok, %Brief{} = default_brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning brief fallback copy",
               "body" => "No decision needs your attention right now.",
               "status" => "sent",
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:morning:default-copy"
             })

    assert default_brief.summary == "No priority follow-up is ready to review."
    refute default_brief.summary =~ "yet"

    assert {:ok, %Brief{}} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning brief legacy fallback copy",
               "summary" =>
                 "No clear follow-up needs your attention from the connected sources yet.",
               "body" => "No decision needs your attention right now.",
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:morning:legacy-default-copy"
             })

    result = Briefs.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    [message] = sent_messages()
    assert message.text =~ "No priority follow-up is ready to review."
    refute message.text =~ "connected sources yet"
    refute message.text =~ "No clear follow-up"
  end

  test "fallback delivery failures store product-safe copy", %{
    user_id: user_id,
    agent: agent
  } do
    Application.put_env(:maraithon, :briefs,
      telegram_module: Maraithon.TestSupport.FailingTelegram
    )

    Application.put_env(:maraithon, :failing_telegram,
      reason: {:telegram_error, 500, "RuntimeError token=secret stacktrace %{chat_id: 777123}"}
    )

    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning brief delivery failure",
               "summary" => "A brief should fail with safe copy.",
               "body" => "Keep the failure message suitable for product surfaces.",
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:morning:fallback-delivery-failure"
             })

    result = Briefs.dispatch_telegram_batch(batch_size: 10)
    assert result.failed == 1

    updated = Repo.get!(Brief, brief.id)
    assert updated.status == "failed"

    assert updated.error_message ==
             "Telegram is temporarily unavailable. Wait a minute before sending another delivery."

    refute String.contains?(String.downcase(updated.error_message), "try again")
    refute updated.error_message =~ "token"
    refute updated.error_message =~ "stacktrace"
    refute updated.error_message =~ "chat_id"
  end

  test "unified delivery stores terminal missing-chat copy and does not retry it", %{
    user_id: user_id,
    agent: agent
  } do
    assistant_config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(assistant_config,
        telegram_full_chat_enabled: true,
        telegram_unified_push_enabled: true,
        proactive_delivery_planner_enabled: false
      )
    )

    assert {:ok, _account} = ConnectedAccounts.mark_disconnected(user_id, "telegram")

    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning brief missing chat",
               "summary" => "A brief cannot send without a linked Telegram chat.",
               "body" => "The failure should tell the user what to fix.",
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:morning:unified-missing-chat"
             })

    result = Briefs.dispatch_telegram_batch(batch_size: 10)
    assert result.failed == 1

    updated = Repo.get!(Brief, brief.id)
    assert updated.status == "failed"
    assert updated.error_message == DeliveryErrorCopy.storage_message(:missing_chat_id)
    assert DeliveryErrorCopy.terminal?(updated.error_message)
    refute Enum.any?(Briefs.list_pending(10), &(&1.id == updated.id))
  end

  test "checked fallback briefs keep executive action buttons", %{
    user_id: user_id,
    agent: agent
  } do
    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning briefing - 2026-05-29",
               "summary" => "Start with 2 open follow-ups; anything absent here is unknown.",
               "body" => "## Active Follow-Ups\n- **Reply to board deck thread**",
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:morning:checked-fallback-buttons",
               "error_message" => "llm_call_failed: {:incomplete_response, :max_output_tokens}",
               "metadata" => %{"generation_mode" => "source_fallback"}
             })

    payload = Briefs.telegram_payload(brief)
    buttons = payload.reply_markup["inline_keyboard"] |> List.flatten()

    assert Enum.any?(buttons, &(&1["text"] == "Open Maraithon"))
    refute payload.text =~ "llm_call_failed"
    refute payload.text =~ "max_output_tokens"
  end

  test "commitment tracker cadence renders as open work review", %{
    user_id: user_id,
    agent: agent
  } do
    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "commitment_tracker",
               "title" => "Open work review - 2026-05-09",
               "summary" => "One checked follow-up should be saved.",
               "body" => "Today's move: send Priya the revised investor pack.",
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:commitment-tracker:public-label"
             })

    payload = Briefs.telegram_payload(brief)

    assert payload.text =~ "<b>Open work review</b>"
    refute payload.text =~ "Commitment tracker"
  end

  test "telegram payload strips diagnostics and credentials from delivered brief copy", %{
    user_id: user_id,
    agent: agent
  } do
    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning brief confidence_score=0.91",
               "summary" => "source_health: %{gmail: connected} Authorization: Bearer abc123",
               "body" => """
               Lead with the CFO ask.
               confidence_score: 0.91
               source_health: {"gmail": "connected"}
               model_name: gpt-5.4
               Authorization: Bearer abc123
               Next action: Send the revised answer today.
               """,
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:morning:public-copy-boundary"
             })

    payload = Briefs.telegram_payload(brief)
    lower_text = String.downcase(payload.text)

    assert payload.text =~ "Chief of staff brief"
    assert payload.text =~ "Maraithon kept only review-ready next steps."
    assert payload.text =~ "Lead with the CFO ask."
    assert payload.text =~ "Send the revised answer today."

    refute payload.text =~ "I kept"
    refute payload.text =~ "Next action:"
    refute lower_text =~ "confidence"
    refute lower_text =~ "score"
    refute lower_text =~ "source_health"
    refute lower_text =~ "model_name"
    refute lower_text =~ "authorization"
    refute lower_text =~ "bearer"
    refute lower_text =~ "token"
    refute payload.text =~ "abc123"
  end

  test "telegram payload strips model confidence prose from delivered brief copy", %{
    user_id: user_id,
    agent: agent
  } do
    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "90% confidence: morning follow-up",
               "summary" => "Model score says finance needs an immediate nudge.",
               "body" => """
               90% confidence this matters.
               Reasoning: model saw an owed reply.
               Why now: The receiving window closes before tomorrow's dispatch.
               Next: Reply with the signed shipment timing before noon.
               """,
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:morning:model-confidence-prose"
             })

    payload = Briefs.telegram_payload(brief)
    lower_text = String.downcase(payload.text)

    assert payload.text =~ "Chief of staff brief"
    assert payload.text =~ "Maraithon kept only review-ready next steps."
    assert payload.text =~ "The receiving window closes before tomorrow's dispatch."
    assert payload.text =~ "Next: Reply with the signed shipment timing before noon."

    refute payload.text =~ "Why now:"
    refute lower_text =~ "90%"
    refute lower_text =~ "confidence"
    refute lower_text =~ "model"
    refute lower_text =~ "reasoning"
    refute lower_text =~ "score"
  end

  test "telegram payload hides legacy generation failure copy", %{
    user_id: user_id,
    agent: agent
  } do
    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning briefing generation failed",
               "summary" => "The configured model did not produce a valid brief.",
               "body" => """
               Morning briefing model synthesis failed.
               Try the checked source view instead.
               """,
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:morning:legacy-generation-failure",
               "error_message" =>
                 "Morning briefing model synthesis failed: {:rate_limited, 60000}",
               "metadata" => %{"generation_mode" => "error"}
             })

    payload = Briefs.telegram_payload(brief)
    lower_text = String.downcase(payload.text)

    assert payload.text =~ "Chief of staff brief"
    assert payload.text =~ "Maraithon kept only review-ready next steps."
    assert payload.text =~ "No verified recommendation was safe to send yet."
    refute lower_text =~ "generation failed"
    refute lower_text =~ "configured model"
    refute lower_text =~ "model synthesis"
    refute lower_text =~ "checked source view"
    refute lower_text =~ "rate_limited"
  end

  test "unified proactive brief candidates hide legacy generation failure metadata", %{
    user_id: user_id,
    agent: agent
  } do
    assistant_config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(assistant_config,
        telegram_full_chat_enabled: true,
        telegram_unified_push_enabled: true,
        proactive_delivery_planner_enabled: true
      )
    )

    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning briefing generation failed",
               "summary" => "The configured model did not produce a valid brief.",
               "body" => """
               Morning briefing model synthesis failed.
               Try the checked source view instead.
               """,
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:morning:legacy-generation-failure-candidate",
               "error_message" =>
                 "Morning briefing model synthesis failed: {:rate_limited, 60000}",
               "metadata" => %{"generation_mode" => "error"}
             })

    result = Briefs.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    candidate =
      Repo.get_by!(ProactiveCandidate, user_id: user_id, dedupe_key: "brief:#{brief.id}")

    assert candidate.title == "Chief of staff brief"
    assert candidate.why_now == "Maraithon kept only review-ready next steps."
    assert candidate.body =~ "No verified recommendation was safe to send yet."

    visible_candidate = inspect(candidate)
    refute visible_candidate =~ "generation failed"
    refute visible_candidate =~ "configured model"
    refute visible_candidate =~ "model synthesis"
    refute visible_candidate =~ "checked source view"
    refute visible_candidate =~ "rate_limited"
  end

  test "telegram payload uses a decision-safe fallback when all brief copy is unsafe", %{
    user_id: user_id,
    agent: agent
  } do
    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "api_key=sk-test",
               "summary" => "Authorization: Bearer abc123",
               "body" => """
               source_health: {"gmail": "connected"}
               model_name: gpt-5.4
               confidence_score: 0.91
               """,
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:morning:unsafe-fallback"
             })

    payload = Briefs.telegram_payload(brief)
    lower_text = String.downcase(payload.text)

    assert payload.text =~ "Chief of staff brief"
    assert payload.text =~ "Maraithon kept only review-ready next steps."

    assert payload.text =~
             "No verified recommendation was safe to send yet."

    refute payload.text =~ "I could not"
    refute payload.text =~ "Check connected sources"
    refute lower_text =~ "diagnostics"
    refute String.contains?(lower_text, "source-backed")
    refute lower_text =~ "authorization"
    refute lower_text =~ "bearer"
    refute lower_text =~ "source_health"
    refute lower_text =~ "model_name"
    refute lower_text =~ "confidence"
    refute lower_text =~ "api_key"
    refute payload.text =~ "Open Maraithon to review"
  end

  test "telegram payload externalizes task-app terms in delivered brief copy", %{
    user_id: user_id,
    agent: agent
  } do
    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning brief: 2 todos",
               "summary" => "Two todos need a decision.",
               "body" => """
               Review the todo list before checking CRM context.
               Next action: Decide which todo stays open.
               """,
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:morning:product-terms",
               "metadata" => %{"agent_behavior" => "founder_followthrough_agent"}
             })

    payload = Briefs.telegram_payload(brief)
    lower_text = String.downcase(payload.text)
    buttons = payload.reply_markup["inline_keyboard"] |> List.flatten()

    assert payload.text =~ "Morning brief: 2 work items"
    assert payload.text =~ "Two work items need a decision."
    assert payload.text =~ "Review the open work before checking relationship context."
    assert payload.text =~ "Decide which work item stays open."
    refute lower_text =~ ~r/\btodos?\b/
    refute lower_text =~ "todo list"
    refute lower_text =~ "crm context"
    assert Enum.any?(buttons, &(&1["text"] == "Adjust Briefing"))
    refute Enum.any?(buttons, &(&1["text"] == "Tune Agent"))
  end

  test "telegram payload speaks directly instead of exposing model role labels", %{
    user_id: user_id,
    agent: agent
  } do
    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning brief for the operator",
               "summary" => "The user needs to approve the finance reply.",
               "body" => """
               The operator's next move is to review the todo list.
               User should confirm the invoice status.
               This needs operator attention before noon.
               """,
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:morning:direct-user-copy"
             })

    payload = Briefs.telegram_payload(brief)
    lower_text = String.downcase(payload.text)

    assert payload.text =~ "Morning brief for you"
    assert payload.text =~ "You need to approve the finance reply."
    assert payload.text =~ "Your next move is to review the open work."
    assert payload.text =~ "You should confirm the invoice status."
    assert payload.text =~ "This needs your attention before noon."

    refute lower_text =~ "the user"
    refute lower_text =~ "the operator"
    refute lower_text =~ "operator attention"
    refute lower_text =~ "todo list"
  end

  test "terminal missing-chat failures are not retried", %{user_id: user_id, agent: agent} do
    scheduled_for = DateTime.utc_now()

    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning brief with no chat",
               "summary" => "This failed because no Telegram chat was available.",
               "body" => "No retry should happen for a terminal chat routing failure.",
               "scheduled_for" => scheduled_for,
               "dedupe_key" => "brief:morning:missing-chat",
               "status" => "failed",
               "error_message" => ":missing_chat_id"
             })

    refute brief in Briefs.list_pending(10)
  end

  test "check-in todo digests group new and older items for delivery", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [new_todo, older_todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("briefs-check-in:new", "Reply to finance about the receipt",
          source_occurred_at: "2026-04-02T14:00:00Z"
        ),
        todo_attrs("briefs-check-in:older", "Confirm the shipment ETA",
          source_occurred_at: "2026-03-31T18:00:00Z"
        )
      ])

    scheduled_for = ~U[2026-04-02 16:30:00Z]

    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "check_in",
               "title" => "Check-in: 2 items ready for a decision",
               "summary" => "Two open communication loops are ready for a decision.",
               "body" => "Superseded by todo delivery.",
               "scheduled_for" => scheduled_for,
               "dedupe_key" => "brief:check-in:todo-style",
               "metadata" => %{
                 "linked_todo_ids" => [new_todo.id, older_todo.id],
                 "timezone_offset_hours" => "-4"
               }
             })

    [first_todo, second_todo] = Briefs.todo_digest_todos(brief)

    assert first_todo.id == new_todo.id
    assert second_todo.id == older_todo.id

    intro = Briefs.todo_digest_intro_text(brief, [first_todo, second_todo])
    assert intro =~ "1 new today"
    assert intro =~ "1 carried over from earlier"

    assert String.starts_with?(intro, "Best next move: Reply to finance about the receipt.")
    assert intro =~ "Best next move: Reply to finance about the receipt."
    assert intro =~ "Open work: 1 new today. 1 carried over from earlier."
    assert intro =~ "Then decide the rest"
    assert intro =~ "mark done, snooze, keep active, or dismiss each one"
    refute intro =~ "Hey"
    refute intro =~ "here's the open work"
    refute intro =~ "stale"
    refute intro =~ "not important"
    refute intro =~ "Tap "
    assert is_nil(Briefs.todo_digest_prefix_text(brief, first_todo))
    assert is_nil(Briefs.todo_digest_prefix_text(brief, second_todo))
  end

  test "check-in todo digest for one item avoids phantom rest copy", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("briefs-check-in:single", "Reply to finance about the receipt",
          source_occurred_at: "2026-04-02T14:00:00Z"
        )
      ])

    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "check_in",
               "title" => "Check-in: 1 item ready for a decision",
               "summary" => "One open communication loop is ready for a decision.",
               "body" => "Superseded by todo delivery.",
               "scheduled_for" => ~U[2026-04-02 16:30:00Z],
               "dedupe_key" => "brief:check-in:single-todo-style",
               "metadata" => %{
                 "linked_todo_ids" => [todo.id],
                 "timezone_offset_hours" => "-4"
               }
             })

    [digest_todo] = Briefs.todo_digest_todos(brief)

    intro = Briefs.todo_digest_intro_text(brief, [digest_todo])

    assert intro =~ "Best next move: Reply to finance about the receipt."
    assert intro =~ "Then make the call: mark it done, snooze it, keep it active, or dismiss it."
    assert intro =~ "Open work: 1 new today."
    refute intro =~ "the rest"
    refute intro =~ "items still need"
  end

  test "brief todo review sends open work one item at a time and summarizes decisions", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [first_todo, second_todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("briefs-review:first", "Reply to finance about the receipt",
          priority: 96,
          source_occurred_at: "2026-04-02T14:00:00Z"
        ),
        todo_attrs("briefs-review:second", "Confirm the shipment ETA",
          source_occurred_at: "2026-04-02T15:00:00Z"
        )
      ])

    {:ok, %Brief{} = brief} =
      Briefs.record(user_id, agent.id, %{
        "cadence" => "morning",
        "title" => "Morning brief: 2 todos",
        "summary" => "Two todos need a decision.",
        "body" => "Review the list.",
        "scheduled_for" => ~U[2026-04-02 16:30:00Z],
        "dedupe_key" => "brief:morning:review",
        "metadata" => %{"linked_todo_ids" => [first_todo.id, second_todo.id]}
      })

    button =
      brief
      |> Briefs.telegram_payload()
      |> get_in([:reply_markup, "inline_keyboard"])
      |> List.flatten()
      |> Enum.find(&(&1["text"] == "Review open work"))

    assert button["callback_data"] =~ "brftd:"

    :ok =
      BriefTodoReview.handle_callback(%{
        chat_id: 777_123,
        callback_id: "cb-list",
        data: button["callback_data"]
      })

    sends = sent_messages()
    assert length(sends) == 1
    assert hd(sends).text =~ "Open work decision 1 of 2"
    assert hd(sends).text =~ first_todo.next_action

    :ok =
      TodoActions.handle_callback(%{
        chat_id: 777_123,
        message_id: "todo-1",
        callback_id: "cb-done",
        data: "tgtodo:#{first_todo.id}:done"
      })

    sends = sent_messages()
    assert length(sends) == 2
    assert List.last(sends).text =~ "Open work decision 2 of 2"
    assert List.last(sends).text =~ second_todo.next_action
    assert Todos.get_for_user(user_id, first_todo.id).status == "done"

    :ok =
      TodoActions.handle_callback(%{
        chat_id: 777_123,
        message_id: "todo-2",
        callback_id: "cb-dismiss",
        data: "tgtodo:#{second_todo.id}:dismiss"
      })

    summary = sent_messages() |> List.last()
    assert summary.text =~ "Open work review finished"
    assert summary.text =~ "Cleared: 2 (1 done, 1 dismissed)"
    assert summary.text =~ "Still open: 0"
    assert summary.text =~ "Done and dismissed items are off future briefs"

    updated_brief = Repo.get!(Brief, brief.id)
    assert get_in(updated_brief.metadata, ["todo_review", "status"]) == "completed"
    assert get_in(updated_brief.metadata, ["todo_review", "summary", "done_count"]) == 1
  end

  test "brief action row lets the user scan linked open work before reviewing", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [first_todo, second_todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("briefs-scan:first", "Reply to finance about the receipt",
          priority: 96,
          source_occurred_at: "2026-04-02T14:00:00Z",
          summary: "Finance needs the corrected receipt today.",
          next_action: "Send finance the corrected receipt and confirm reimbursement timing.",
          notes: "Finance asked for the corrected receipt before the reimbursement cutoff.",
          metadata: %{
            "thread_id" => "briefs-scan:first",
            "subject" => "Reply to finance about the receipt",
            "why_now" => "Finance needs the corrected receipt today.",
            "source_evidence" =>
              "Finance asked for the corrected receipt before the reimbursement cutoff."
          }
        ),
        todo_attrs("briefs-scan:second", "Confirm the shipment ETA",
          source_occurred_at: "2026-04-02T15:00:00Z",
          next_action: "Reply with the signed shipment timing before noon."
        )
      ])

    {:ok, %Brief{} = brief} =
      Briefs.record(user_id, agent.id, %{
        "cadence" => "morning",
        "title" => "Morning brief: scan before review",
        "summary" => "Two work items need a decision.",
        "body" => "Review the list.",
        "scheduled_for" => ~U[2026-04-02 16:30:00Z],
        "dedupe_key" => "brief:morning:scan-before-review",
        "metadata" => %{"linked_todo_ids" => [first_todo.id, second_todo.id]}
      })

    buttons =
      brief
      |> Briefs.telegram_payload()
      |> get_in([:reply_markup, "inline_keyboard"])
      |> List.flatten()

    assert Enum.find(buttons, &(&1["text"] == "Review open work"))["callback_data"] ==
             "brftd:#{brief.id}:start"

    assert Enum.find(buttons, &(&1["text"] == "Show list"))["callback_data"] ==
             "brftd:#{brief.id}:list"

    :ok =
      BriefTodoReview.handle_callback(%{
        chat_id: 777_123,
        callback_id: "cb-scan",
        data: "brftd:#{brief.id}:list"
      })

    [message] = sent_messages()
    assert String.starts_with?(message.text, "Best next move: Send finance the corrected receipt")
    assert message.text =~ "\n\n<b>Open work</b>"
    assert message.text =~ "<b>Open work</b>"
    assert message.text =~ "1. #{first_todo.title}"
    assert message.text =~ "Why now: Finance needs the corrected receipt today."
    assert message.text =~ "Next: Send finance the corrected receipt"
    assert message.text =~ "Evidence: Finance asked for the corrected receipt"
    assert message.text =~ "2. #{second_todo.title}"
    assert message.text =~ "Best next move: Send finance the corrected receipt"

    review_button =
      message.opts
      |> Keyword.fetch!(:reply_markup)
      |> Map.fetch!("inline_keyboard")
      |> List.flatten()
      |> Enum.find(&(&1["text"] == "Decide one by one"))

    assert review_button["callback_data"] == "brftd:#{brief.id}:start"

    refute get_in(Repo.get!(Brief, brief.id).metadata || %{}, ["todo_review", "status"]) ==
             "active"
  end

  test "brief open work list polishes legacy todo copy before display", %{
    user_id: user_id,
    agent: agent
  } do
    legacy_todo =
      Repo.insert!(%Todo{
        user_id: user_id,
        owner_user_id: user_id,
        source: "gmail",
        kind: "gmail_triage",
        attention_mode: "act_now",
        title: "User committed to follow-up with Finance; follow-up not yet sent.",
        summary: "This thread still needs a reply from the user.",
        next_action:
          "Reply now with owner, ETA, and the exact artifact or update you committed to.",
        priority: 91,
        status: "open",
        source_item_id: "briefs-legacy-copy-thread",
        dedupe_key: "briefs-legacy-copy",
        metadata: %{
          "subject" => "Corrected receipt",
          "why_now" => "The user needs this before noon.",
          "source_evidence" => "The user asked for the corrected receipt.",
          "record" => %{"person" => "Finance", "commitment" => "Corrected receipt"}
        }
      })

    {:ok, %Brief{} = brief} =
      Briefs.record(user_id, agent.id, %{
        "cadence" => "morning",
        "title" => "Morning brief: legacy copy",
        "summary" => "One item needs review.",
        "body" => "Review the list.",
        "scheduled_for" => ~U[2026-04-02 16:30:00Z],
        "dedupe_key" => "brief:morning:legacy-copy",
        "metadata" => %{"linked_todo_ids" => [legacy_todo.id]}
      })

    :ok =
      BriefTodoReview.handle_callback(%{
        chat_id: 777_123,
        callback_id: "cb-legacy-copy-list",
        data: "brftd:#{brief.id}:list"
      })

    [message] = sent_messages()

    assert message.text =~ "Follow up with Finance about Corrected receipt"
    assert message.text =~ "Why now: You need this before noon."
    assert message.text =~ "Evidence: You asked for the corrected receipt."
    refute message.text =~ "User committed"
    refute message.text =~ "the user"
    refute message.text =~ "owner, ETA"
  end

  test "brief todo review recap keeps next actions on remaining work", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [first_todo, second_todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("briefs-review-open:first", "Reply to finance about the receipt",
          priority: 96,
          source_occurred_at: "2026-04-02T14:00:00Z",
          next_action: "Send finance the corrected receipt and confirm reimbursement timing."
        ),
        todo_attrs("briefs-review-open:second", "Confirm the shipment ETA",
          source_occurred_at: "2026-04-02T15:00:00Z",
          summary: "The receiving window closes before tomorrow's dispatch.",
          next_action: "Reply with the signed shipment timing before noon.",
          notes: "Ops asked for the signed shipment timing before noon.",
          metadata: %{
            "thread_id" => "briefs-review-open:second",
            "subject" => "Confirm the shipment ETA",
            "why_now" => "The receiving window closes before tomorrow's dispatch.",
            "source_evidence" => "Ops asked for the signed shipment timing before noon."
          }
        )
      ])

    {:ok, %Brief{} = brief} =
      Briefs.record(user_id, agent.id, %{
        "cadence" => "morning",
        "title" => "Morning brief: open todo recap",
        "summary" => "Two todos need review.",
        "body" => "Review the list.",
        "scheduled_for" => ~U[2026-04-02 16:30:00Z],
        "dedupe_key" => "brief:morning:review-open-recap",
        "metadata" => %{"linked_todo_ids" => [first_todo.id, second_todo.id]}
      })

    :ok =
      BriefTodoReview.handle_callback(%{
        chat_id: 777_123,
        callback_id: "cb-open-recap",
        data: "brftd:#{brief.id}:start"
      })

    :ok =
      TodoActions.handle_callback(%{
        chat_id: 777_123,
        message_id: "todo-open-recap-1",
        callback_id: "cb-open-recap-done",
        data: "tgtodo:#{first_todo.id}:done"
      })

    :ok =
      TodoActions.handle_callback(%{
        chat_id: 777_123,
        message_id: "todo-open-recap-2",
        callback_id: "cb-open-recap-snooze",
        data: "tgtodo:#{second_todo.id}:snooze"
      })

    summary = sent_messages() |> List.last()
    assert summary.text =~ "Open work review finished"
    assert summary.text =~ "Still open: 1"
    assert summary.text =~ "Confirm the shipment ETA"
    assert summary.text =~ "Why now: The receiving window closes before tomorrow's dispatch."
    assert summary.text =~ "Next: Reply with the signed shipment timing before noon."
    assert summary.text =~ "Evidence: Ops asked for the signed shipment timing before noon."
  end

  test "telegram text request starts latest open work review and advances after each action", %{
    user_id: user_id,
    agent: agent
  } do
    assert BriefTodoReview.text_review_request?("Let's go through my todos one at a time")
    assert BriefTodoReview.text_review_request?("Let's review open work one at a time")
    refute BriefTodoReview.text_review_request?("List Todos")
    refute BriefTodoReview.text_review_request?("Add buy milk to my todo list")
    refute BriefTodoReview.text_review_request?("What's on my todo list?")
    assert BriefTodoReview.text_review_intent("List Todos").intent == :show_list
    assert BriefTodoReview.text_review_intent("Show open work").intent == :show_list

    assert BriefTodoReview.text_review_intent("Can you review my todos?").intent ==
             :clarify_review

    {:ok, [first_todo, second_todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("briefs-text-review:first", "Reply to school about the pickup form",
          priority: 96,
          source_occurred_at: "2026-04-02T14:00:00Z"
        ),
        todo_attrs("briefs-text-review:second", "Confirm the Sunday prep notes",
          source_occurred_at: "2026-04-02T15:00:00Z"
        )
      ])

    {:ok, %Brief{} = brief} =
      Briefs.record(user_id, agent.id, %{
        "cadence" => "morning",
        "title" => "Morning brief: text review",
        "summary" => "Two todos need a one-at-a-time review.",
        "body" => "Review the list.",
        "scheduled_for" => ~U[2026-04-02 16:30:00Z],
        "dedupe_key" => "brief:morning:text-review",
        "metadata" => %{"linked_todo_ids" => [first_todo.id, second_todo.id]}
      })

    assert :ok =
             TelegramAssistant.handle_inbound(%{
               user_id: user_id,
               chat_id: "777123",
               text: "Let's go through my todos one at a time",
               source_message_id: "text-review-request"
             })

    sends = sent_messages()
    assert length(sends) == 1
    assert hd(sends).text =~ "Open work decision 1 of 2"
    assert hd(sends).text =~ first_todo.next_action

    updated_brief = Repo.get!(Brief, brief.id)
    assert get_in(updated_brief.metadata, ["todo_review", "status"]) == "active"
    assert get_in(updated_brief.metadata, ["todo_review", "current_todo_id"]) == first_todo.id

    :ok =
      TodoActions.handle_callback(%{
        chat_id: "777123",
        message_id: "todo-text-1",
        callback_id: "cb-text-done",
        data: "tgtodo:#{first_todo.id}:done"
      })

    sends = sent_messages()
    assert length(sends) == 2
    assert List.last(sends).text =~ "Open work decision 2 of 2"
    assert List.last(sends).text =~ second_todo.next_action
  end

  test "telegram text review uses the current open work set over an older brief", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [old_todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("briefs-text-current:old", "Confirm the old shipment note",
          priority: 40,
          source_occurred_at: "2026-04-01T14:00:00Z",
          next_action: "Confirm whether the old shipment note still matters."
        )
      ])

    {:ok, %Brief{} = old_brief} =
      Briefs.record(user_id, agent.id, %{
        "cadence" => "morning",
        "title" => "Morning brief: older linked list",
        "summary" => "Only the older item existed when this brief was written.",
        "body" => "Review the older item.",
        "scheduled_for" => ~U[2026-04-01 16:30:00Z],
        "dedupe_key" => "brief:morning:older-linked-list",
        "metadata" => %{"linked_todo_ids" => [old_todo.id]}
      })

    {:ok, [new_todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("briefs-text-current:new", "Reply to school about today's form",
          priority: 99,
          source_occurred_at: "2026-04-02T15:30:00Z",
          next_action: "Send the signed school form and ask for confirmation today."
        )
      ])

    assert :ok =
             TelegramAssistant.handle_inbound(%{
               user_id: user_id,
               chat_id: "777123",
               text: "Let's go through my open work one at a time",
               source_message_id: "text-review-current-open-work"
             })

    [message] = sent_messages()
    assert message.text =~ "Open work decision 1 of 2"
    assert message.text =~ new_todo.next_action

    fresh_review =
      Brief
      |> Repo.all()
      |> Enum.find(fn brief ->
        get_in(brief.metadata || %{}, ["origin"]) == "telegram_text_request"
      end)

    assert fresh_review
    refute fresh_review.id == old_brief.id

    assert Enum.sort(get_in(fresh_review.metadata, ["linked_todo_ids"])) ==
             Enum.sort([old_todo.id, new_todo.id])
  end

  test "quick todo list empty state uses product copy" do
    assert :ok =
             BriefTodoReview.handle_callback(%{
               chat_id: "777123",
               callback_id: "cb-empty-quick-list",
               data: "brftd:latest:list"
             })

    [message] = sent_messages()

    assert message.text ==
             "No saved open work is ready for review right now. New commitments will appear here once Maraithon has enough context to recommend a concrete next move."

    refute message.text =~ "I "
    refute message.text =~ "don't"
    refute message.text =~ "source-backed"
  end

  test "latest review empty state answers with accurate callback copy" do
    assert :ok =
             BriefTodoReview.handle_callback(%{
               chat_id: "777123",
               callback_id: "cb-empty-start",
               data: "brftd:latest:start"
             })

    [callback] = callback_events()
    assert Keyword.fetch!(callback.opts, :text) == "No saved open work to review"

    [message] = sent_messages()

    assert message.text ==
             "No saved open work is ready for review right now. New commitments will appear here once Maraithon has enough context to recommend a concrete next move."

    refute message.text =~ "source-backed"
  end

  test "unavailable brief review callback uses product copy" do
    assert :ok =
             BriefTodoReview.handle_callback(%{
               chat_id: "777123",
               callback_id: "cb-missing-review",
               data: "brftd:00000000-0000-0000-0000-000000000000:start"
             })

    [callback] = callback_events()
    assert Keyword.fetch!(callback.opts, :text) == "That open work review is no longer available."
  end

  test "quick todo list includes the next action for each item", %{user_id: user_id} do
    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("briefs-quick-list:first", "Reply to school about the pickup form",
          priority: 96,
          source_occurred_at: "2026-04-02T14:00:00Z",
          summary: "Pickup-form changes close today.",
          next_action: "Send the signed pickup form and ask for confirmation.",
          notes: "School asked for the signed form before the pickup cutoff.",
          metadata: %{
            "thread_id" => "briefs-quick-list:first",
            "subject" => "Reply to school about the pickup form",
            "why_now" => "Pickup-form changes close today.",
            "source_evidence" => "School asked for the signed form before the pickup cutoff."
          }
        )
      ])

    assert :ok =
             BriefTodoReview.handle_callback(%{
               chat_id: "777123",
               callback_id: "cb-quick-list",
               data: "brftd:latest:list"
             })

    [message] = sent_messages()
    assert String.starts_with?(message.text, "Best next move: Send the signed pickup form")
    assert message.text =~ "Open work"
    assert message.text =~ "1. #{todo.title}"
    assert message.text =~ "Why now: Pickup-form changes close today."
    assert message.text =~ "Next: Send the signed pickup form and ask for confirmation."
    assert message.text =~ "Evidence: School asked for the signed form before the pickup cutoff."

    assert message.text =~
             "Best next move: Send the signed pickup form and ask for confirmation. Then decide each remaining item"

    refute message.text =~ "clear decisions"
  end

  test "ambiguous typed todo review requests ask before starting the action queue", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [first_todo, second_todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("briefs-clarify-review:first", "Reply to math tutor about Sunday"),
        todo_attrs("briefs-clarify-review:second", "Confirm the grocery pickup window")
      ])

    {:ok, %Brief{} = _brief} =
      Briefs.record(user_id, agent.id, %{
        "cadence" => "morning",
        "title" => "Morning brief: clarify review",
        "summary" => "Two todos need a decision.",
        "body" => "Review the list.",
        "scheduled_for" => ~U[2026-04-02 16:30:00Z],
        "dedupe_key" => "brief:morning:clarify-review",
        "metadata" => %{"linked_todo_ids" => [first_todo.id, second_todo.id]}
      })

    {:ok, conversation} =
      TelegramConversations.start_or_continue(user_id, "777123", %{
        "root_message_id" => "text-review-ambiguous"
      })

    assert :ok =
             TelegramAssistant.handle_inbound(%{
               user_id: user_id,
               chat_id: "777123",
               text: "Can you review my todos?",
               source_message_id: "text-review-ambiguous",
               conversation: conversation
             })

    [question] = sent_messages()
    assert question.text =~ "decide one item at a time"
    assert question.text =~ "scan the list first"
    refute question.text =~ "clear open work"
    conversation = Repo.get!(TelegramConversations.Conversation, conversation.id)
    assert conversation.metadata["pending_todo_review_clarification"]

    start_button =
      question.opts
      |> Keyword.fetch!(:reply_markup)
      |> Map.fetch!("inline_keyboard")
      |> List.flatten()
      |> Enum.find(&(&1["text"] == "Decide one by one"))

    assert start_button["callback_data"] == "brftd:latest:start"

    assert :ok =
             TelegramAssistant.handle_inbound(%{
               user_id: user_id,
               chat_id: "777123",
               text: "review each item now",
               source_message_id: "text-review-clarified",
               conversation: conversation
             })

    sends = sent_messages()
    assert length(sends) == 2
    assert List.last(sends).text =~ "Open work decision 1 of 2"
    assert List.last(sends).text =~ first_todo.next_action
  end

  defp todo_attrs(thread_id, title), do: todo_attrs(thread_id, title, [])

  defp todo_attrs(thread_id, title, overrides) when is_list(overrides) do
    defaults = %{
      "source" => "gmail",
      "kind" => "gmail_triage",
      "attention_mode" => "act_now",
      "title" => title,
      "summary" => "This thread still needs a reply from the user.",
      "next_action" => "Reply in-thread and close the loop.",
      "priority" => 88,
      "source_item_id" => thread_id,
      "source_occurred_at" => "2026-04-02T04:19:00Z",
      "dedupe_key" => "gmail:gmail_triage:#{thread_id}",
      "metadata" => %{
        "thread_id" => thread_id,
        "subject" => title,
        "from" => "ops@example.com",
        "google_account_email" => user_account_email()
      }
    }

    override_map =
      overrides
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()

    Map.merge(defaults, override_map)
  end

  defp user_account_email, do: "briefs-user@example.com"

  defp sent_messages do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.type == :send))
  end

  defp callback_events do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.type == :callback))
  end
end
