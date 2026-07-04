defmodule Maraithon.TelegramAssistant.DeliveryPlannerTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.DeliveryPlanner
  alias Maraithon.TelegramAssistant.ProactiveCandidate
  alias Maraithon.TelegramAssistant.ProactiveQueue
  alias Maraithon.TelegramAssistant.PushReceipt
  alias Maraithon.TestSupport.CapturingTelegram

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    original_insights = Application.get_env(:maraithon, :insights, [])
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights, telegram_module: CapturingTelegram)
    )

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_unified_push_enabled: true,
        proactive_delivery_planner_enabled: true
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
    end)

    user_id = "delivery-planner-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "planner"}
      })

    %{user_id: user_id}
  end

  test "interrupt_now candidates are sent individually and marked delivered", %{user_id: user_id} do
    {:ok, candidate} =
      ProactiveQueue.enqueue(
        candidate_attrs(user_id, %{
          title: "Customer escalation",
          body: "The customer escalation needs a same-day reply.",
          urgency: 0.95
        })
      )

    llm_complete = fn params ->
      prompt = get_in(params, ["messages", Access.at(1), "content"])

      assert prompt =~ "Delivery planning contract:"
      assert prompt =~ "Customer escalation"
      assert prompt =~ "planning_rank"
      assert prompt =~ "attention_profile"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "dispositions" => [
               %{
                 "candidate_id" => candidate.id,
                 "disposition" => "interrupt_now",
                 "reason" => "The escalation is time-sensitive."
               }
             ],
             "digest_intro" => "",
             "summary" => "Interrupt for the escalation."
           })
       }}
    end

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.planned == 1
    assert result.interrupt_now == 1
    assert result.delivered == 1

    [message] = telegram_messages()
    assert message.text =~ "customer escalation"

    assert Repo.get!(ProactiveCandidate, candidate.id).status == "delivered"

    receipt = Repo.get_by!(PushReceipt, user_id: user_id, dedupe_key: candidate.dedupe_key)
    assert receipt.decision == "sent_now"
    assert receipt.origin_type == "insight"

    [ledger_entry] =
      ActionLedger.list_recent(user_id, event_type: "proactive.delivery_planned", limit: 1)

    assert ledger_entry.status == "completed"
    assert ledger_entry.metadata["interrupt_now_count"] == 1
  end

  test "digest candidates are grouped behind one parent message and merged receipts", %{
    user_id: user_id
  } do
    {:ok, first} =
      ProactiveQueue.enqueue(
        candidate_attrs(user_id, %{
          source: "brief",
          title: "Morning brief",
          body: "The morning brief has two open loops.",
          dedupe_key: "brief:planner-one"
        })
      )

    {:ok, second} =
      ProactiveQueue.enqueue(
        candidate_attrs(user_id, %{
          source: "proactive_check_in",
          title: "Check-in",
          body: "The Rippling todo still needs a reply.",
          dedupe_key: "proactive:planner-two"
        })
      )

    llm_complete =
      plan_llm(%{
        first.id => {"digest", "Batch this with the digest."},
        second.id => {"digest", "Batch this with the digest."}
      })

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.digest == 2
    assert result.delivered == 2

    [intro, first_card, second_card] = telegram_messages()
    assert intro.text =~ "Two updates are ready to review together"
    assert intro.text =~ "morning brief has two open follow-ups"
    assert intro.text =~ "Rippling work item is waiting on your reply"
    refute intro.text =~ "proactive updates"
    refute intro.text =~ "todo"
    assert first_card.text =~ "morning brief"
    refute first_card.text =~ "open loops"
    assert second_card.text =~ "Rippling"
    assert second_card.text =~ "work item is waiting on your reply"
    refute second_card.text =~ "todo"

    assert Repo.get!(ProactiveCandidate, first.id).status == "delivered"
    assert Repo.get!(ProactiveCandidate, second.id).status == "delivered"

    merged =
      Repo.all(
        from receipt in PushReceipt,
          where: receipt.user_id == ^user_id,
          where: receipt.decision == "merged",
          select: receipt.dedupe_key
      )

    assert Enum.sort(merged) == Enum.sort([first.dedupe_key, second.dedupe_key])
  end

  test "planner payload hides legacy briefing failure metadata", %{user_id: user_id} do
    {:ok, candidate} =
      ProactiveQueue.enqueue(
        candidate_attrs(user_id, %{
          source: "brief",
          title: "Morning briefing generation failed",
          body: "Maraithon kept only review-ready next steps.",
          why_now: "The configured model did not produce a valid brief.",
          structured_data: %{
            "source" => "test",
            "title" => "Morning briefing generation failed",
            "why_now" => "The configured model did not produce a valid brief."
          },
          dedupe_key: "brief:planner-legacy-failure"
        })
      )

    llm_complete = fn params ->
      prompt = get_in(params, ["messages", Access.at(1), "content"])

      assert prompt =~ "Chief of staff brief"
      assert prompt =~ "Maraithon kept only review-ready next steps."
      refute prompt =~ "Morning briefing generation failed"
      refute prompt =~ "configured model"
      refute prompt =~ "did not produce a valid brief"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "dispositions" => [
               %{
                 "candidate_id" => candidate.id,
                 "disposition" => "hold",
                 "reason" => "No verified recommendation is ready."
               }
             ],
             "digest_intro" => "",
             "summary" => "Held the unsafe brief candidate."
           })
       }}
    end

    # Cadence briefs are an explicit user subscription: even though the model
    # tried to `hold` this one, a brief-sourced candidate is never
    # model-holdable for relevance/fatigue (see resolve_disposition/2 in
    # DeliveryPlanner) — it is forced to send instead, using the same
    # redacted, product-safe body verified above.
    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.planned == 1
    assert result.held == 0
    assert result.interrupt_now == 1
    assert result.delivered == 1

    [message] = telegram_messages()
    assert message.text =~ "Maraithon kept only review-ready next steps."

    delivered_candidate = Repo.get!(ProactiveCandidate, candidate.id)
    assert delivered_candidate.status == "delivered"
    assert delivered_candidate.disposition == "interrupt_now"
  end

  test "hold candidates are marked held without sending", %{user_id: user_id} do
    {:ok, candidate} = ProactiveQueue.enqueue(candidate_attrs(user_id))

    llm_complete =
      plan_llm(%{
        candidate.id => {"hold", "Not useful enough to interrupt."}
      })

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.held == 1
    assert result.delivered == 0
    assert telegram_messages() == []

    held = Repo.get!(ProactiveCandidate, candidate.id)
    assert held.status == "held"
    assert held.disposition == "hold"
    assert held.plan_reason == "Not useful enough to interrupt."
  end

  test "a cadence brief candidate cannot be fatigue-held by the model, unlike other sources", %{
    user_id: user_id
  } do
    {:ok, brief_candidate} =
      ProactiveQueue.enqueue(
        candidate_attrs(user_id, %{
          source: "brief",
          title: "Morning brief",
          body: "Two open loops need a decision this morning.",
          dedupe_key: "brief:fatigue-hold-regression"
        })
      )

    llm_complete =
      plan_llm(%{
        brief_candidate.id =>
          {"hold", "A check-in already went out this morning; holding to prevent fatigue."}
      })

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    # The model's fatigue-hold rationale is overridden: a cadence brief is an
    # explicit subscription, not an opportunistic push, so it is forced to
    # send instead of sitting "pending" forever (the production incident this
    # regression test guards against).
    assert result.held == 0
    assert result.interrupt_now == 1
    assert result.delivered == 1
    assert telegram_messages() != []

    planned = Repo.get!(ProactiveCandidate, brief_candidate.id)
    assert planned.status == "delivered"
    assert planned.disposition == "interrupt_now"
    assert planned.plan_reason =~ "forced to send"
  end

  test "a fatigue-held brief still respects quiet hours instead of bypassing them", %{
    user_id: user_id
  } do
    {:ok, brief_candidate} =
      ProactiveQueue.enqueue(
        candidate_attrs(user_id, %{
          source: "brief",
          title: "Morning brief",
          body: "Two open loops need a decision this morning.",
          dedupe_key: "brief:fatigue-hold-quiet-hours"
        })
      )

    llm_complete =
      plan_llm(%{
        brief_candidate.id => {"hold", "Holding to prevent notification fatigue."}
      })

    # Force quiet hours to cover "now" (whatever hour the suite happens to
    # run at) so this assertion isn't time-of-day-dependent. The real
    # send-time gate (PushBroker.interruption_hold_reason/1) reads wall-clock
    # time directly, not the `context:` opt, so quiet hours can only be
    # exercised deterministically through config, not through a synthetic
    # context payload.
    assistant_config = Application.get_env(:maraithon, :telegram_assistant, [])
    now_hour = Maraithon.TelegramAssistant.PushBroker.local_now_for_user(user_id).hour

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(assistant_config,
        quiet_hours_start_local: now_hour,
        quiet_hours_end_local: rem(now_hour + 1, 24)
      )
    )

    on_exit(fn -> Application.put_env(:maraithon, :telegram_assistant, assistant_config) end)

    # Forcing the brief to `interrupt_now` must not also grant it the
    # urgency-exempt bypass of quiet hours; it should be held by the runtime
    # send-time gate instead.
    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.interrupt_now == 1
    assert result.delivered == 0
    assert result.held == 1
    assert telegram_messages() == []

    planned = Repo.get!(ProactiveCandidate, brief_candidate.id)
    assert planned.status == "held"
    assert planned.disposition == "interrupt_now"
  end

  test "feedback verification holds stale backlog dumps even when model asks to interrupt", %{
    user_id: user_id
  } do
    {:ok, candidate} =
      ProactiveQueue.enqueue(
        candidate_attrs(user_id, %{
          source: "proactive_check_in",
          title: "Overdue follow-up digest",
          body: """
          You have several overdue follow-ups that need your attention:
          • Dan Bourke: confirm the artifact status and give a concrete ETA.
          • Matthew Diakonov: confirm the artifact status and give a concrete ETA.
          • Faye Pang: update on shared materials and next steps.
          • Halah AlQahtani: confirm introduction and follow-up status.
          Also, several recent meetings need a follow-up recap with owners and next steps, including Emma's Soccer Practice.
          Prioritize sending these follow-ups now to maintain relationships.
          """,
          urgency: 0.94,
          dedupe_key: "proactive:bad-backlog-dump"
        })
      )

    llm_complete =
      plan_llm(%{
        candidate.id => {"interrupt_now", "The model thought this was urgent."}
      })

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.held == 1
    assert result.delivered == 0
    assert telegram_messages() == []

    held = Repo.get!(ProactiveCandidate, candidate.id)
    assert held.status == "held"
    assert held.disposition == "hold"
    assert held.plan_reason =~ "Feedback verification"
  end

  test "run_for_due_users drains pending users", %{user_id: first_user_id} do
    second_user_id = "delivery-planner-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(second_user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(second_user_id, "telegram", %{
        external_account_id: "67890",
        metadata: %{"username" => "planner-two"}
      })

    {:ok, first} = ProactiveQueue.enqueue(candidate_attrs(first_user_id))
    {:ok, second} = ProactiveQueue.enqueue(candidate_attrs(second_user_id))

    llm_complete =
      plan_llm(%{
        first.id => {"hold", "Quiet for now."},
        second.id => {"hold", "Quiet for now."}
      })

    result =
      DeliveryPlanner.run_for_due_users(
        user_ids: [first_user_id, second_user_id],
        context: %{},
        llm_complete: llm_complete
      )

    assert result.users == 2
    assert result.planned == 2
    assert result.held == 2
  end

  # SPEC 02 R6: a planner-dispatched insight must advance the underlying
  # InsightNotifications.Delivery off "pending" — otherwise InsightNotifier
  # re-selects it every tick, minting a fresh ProactiveCandidate (and a
  # plan_delivery model call) forever.
  test "planner dispatch marks the insight delivery sent and stops re-minting candidates", %{
    user_id: user_id
  } do
    # Deterministic quiet-hours: the staged delivery's urgency is its score,
    # which may sit under the 0.9 exemption threshold, so pin the
    # quiet-hours window away from the current local hour.
    local_hour = Maraithon.TelegramAssistant.PushBroker.local_now_for_user(user_id).hour

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(Application.get_env(:maraithon, :telegram_assistant, []),
        quiet_hours_start_local: rem(local_hour + 2, 24),
        quiet_hours_end_local: rem(local_hour + 3, 24)
      )
    )

    {:ok, agent} =
      Maraithon.Agents.create_agent(%{
        user_id: user_id,
        behavior: "inbox_calendar_advisor",
        config: %{}
      })

    {:ok, [insight]} =
      Maraithon.Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Reply to customer escalation",
          "summary" => "The thread is urgent and needs a same-day response.",
          "recommended_action" => "Reply immediately with resolution steps.",
          "priority" => 96,
          "confidence" => 0.94,
          "dedupe_key" => "email:planner:reply_urgent"
        }
      ])

    # First InsightNotifier tick: stages the delivery and (with the planner
    # enabled) enqueues one ProactiveCandidate; the Delivery stays pending.
    _ = Maraithon.InsightNotifications.dispatch_telegram_batch(batch_size: 10)

    delivery =
      Repo.get_by!(Maraithon.InsightNotifications.Delivery,
        insight_id: insight.id,
        user_id: user_id,
        channel: "telegram"
      )

    assert delivery.status == "pending"

    [candidate] = candidates_for_delivery(user_id, delivery.id)

    llm_complete =
      plan_llm(%{candidate.id => {"interrupt_now", "Escalation is time-sensitive."}})

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.delivered == 1
    assert Repo.get!(ProactiveCandidate, candidate.id).status == "delivered"

    # The stranded-pending bug: the Delivery must now be "sent".
    assert Repo.get!(Maraithon.InsightNotifications.Delivery, delivery.id).status == "sent"

    # A second InsightNotifier tick must not re-select the Delivery or mint
    # a second ProactiveCandidate for it.
    _ = Maraithon.InsightNotifications.dispatch_telegram_batch(batch_size: 10)

    assert length(candidates_for_delivery(user_id, delivery.id)) == 1
    assert Repo.get!(Maraithon.InsightNotifications.Delivery, delivery.id).status == "sent"
  end

  defp candidates_for_delivery(user_id, delivery_id) do
    import Ecto.Query

    Repo.all(
      from(candidate in ProactiveCandidate,
        where: candidate.user_id == ^user_id,
        where: candidate.dedupe_key == ^"insight_delivery:#{delivery_id}"
      )
    )
  end

  describe "SPEC 01 nudge-sourced candidates" do
    test "a nudge candidate dispatches through interrupt_now without raising and records a nudge receipt",
         %{user_id: user_id} do
      todo = owed_to_me_todo(user_id, "nudge-interrupt")

      {:ok, candidate} =
        ProactiveQueue.enqueue(
          candidate_attrs(user_id, %{
            source: "nudge",
            source_id: todo.id,
            dedupe_key: "nudge:#{todo.id}:nudge_due:0",
            title: "Nudge Elena about the pricing doc",
            body: "You've been waiting on Elena since the 1st — want me to send a nudge?",
            urgency: 0.9,
            structured_data: %{
              "todo_ids" => [todo.id],
              "message_class" => "todo_digest",
              "nudge_reason" => "follow_up_due"
            }
          })
        )

      llm_complete = plan_llm(%{candidate.id => {"interrupt_now", "The follow-up moment arrived."}})

      assert {:ok, result} =
               DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

      assert result.interrupt_now == 1
      assert result.delivered == 1
      assert result.failed == 0

      assert Repo.get!(ProactiveCandidate, candidate.id).status == "delivered"

      receipt = Repo.get_by!(PushReceipt, user_id: user_id, dedupe_key: candidate.dedupe_key)
      assert receipt.origin_type == "nudge"
      assert receipt.decision == "sent_now"

      # The candidate's todo card (with its own interactive buttons) rides
      # along via the existing todo_digest path — no new dispatch code.
      messages = telegram_messages()
      assert Enum.any?(messages, &(&1.text =~ "waiting on Elena"))
      assert Enum.any?(messages, &(&1.text =~ "pricing doc"))
    end

    test "a nudge candidate dispatches through the digest path without raising", %{
      user_id: user_id
    } do
      todo = owed_to_me_todo(user_id, "nudge-digest")

      {:ok, candidate} =
        ProactiveQueue.enqueue(
          candidate_attrs(user_id, %{
            source: "nudge",
            source_id: todo.id,
            dedupe_key: "nudge:#{todo.id}:overdue:2026-07-04",
            title: "The pricing doc deadline passed",
            body: "The pricing doc you are waiting on from Elena is now overdue.",
            urgency: 0.6,
            structured_data: %{
              "todo_ids" => [todo.id],
              "message_class" => "todo_digest",
              "nudge_reason" => "overdue"
            }
          })
        )

      llm_complete = plan_llm(%{candidate.id => {"digest", "Batch it with the digest."}})

      assert {:ok, result} =
               DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

      assert result.digest == 1
      assert result.delivered == 1
      assert result.failed == 0

      assert Repo.get!(ProactiveCandidate, candidate.id).status == "delivered"

      receipt =
        Repo.get_by!(PushReceipt, user_id: user_id, dedupe_key: candidate.dedupe_key)

      assert receipt.origin_type == "nudge"
      assert receipt.decision == "merged"
    end
  end

  defp owed_to_me_todo(user_id, key) do
    {:ok, [todo]} =
      Maraithon.Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "title" => "Waiting on Elena for the pricing doc",
          "summary" => "Elena owes you the pricing doc for the renewal.",
          "next_action" => "Nudge Elena if she stays quiet.",
          "dedupe_key" => "delivery-planner-#{key}",
          "direction" => "owed_to_me",
          "counterparty_label" => "Elena"
        }
      ])

    todo
  end

  defp plan_llm(dispositions_by_id) do
    fn _params ->
      dispositions =
        Enum.map(dispositions_by_id, fn {candidate_id, {disposition, reason}} ->
          %{
            "candidate_id" => candidate_id,
            "disposition" => disposition,
            "reason" => reason
          }
        end)

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "dispositions" => dispositions,
             "digest_intro" => "Here are the proactive updates to review together.",
             "summary" => "Planned proactive delivery."
           })
       }}
    end
  end

  defp telegram_messages do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.type == :send))
  end

  defp candidate_attrs(user_id, overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        user_id: user_id,
        source: "insight",
        source_id: "source-#{unique}",
        dedupe_key: "candidate:planner:#{unique}",
        title: "Reply to customer escalation",
        body: "The customer escalation needs a same-day reply.",
        urgency: 0.7,
        why_now: "The thread is urgent and still open.",
        structured_data: %{"source" => "test"},
        telegram_opts: %{"parse_mode" => "HTML"}
      },
      overrides
    )
  end
end
