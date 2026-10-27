defmodule Maraithon.TelegramAssistant.DeliveryPlannerTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.Agents
  alias Maraithon.Briefs.Brief
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights.Insight
  alias Maraithon.Memory
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.DeliveryPlanner
  alias Maraithon.TelegramAssistant.ProactiveCandidate
  alias Maraithon.TelegramAssistant.ProactiveQueue
  alias Maraithon.TelegramAssistant.PushReceipt
  alias Maraithon.TestSupport.CapturingAPNS

  setup do
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_unified_push_enabled: true,
        proactive_delivery_planner_enabled: true
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
    end)

    user_id = "delivery-planner-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    CapturingAPNS.enable(user_id)

    # Pin quiet hours away from "now" so dispatch outcomes don't depend on
    # what hour the suite runs at. The quiet-hours tests below override this.
    local_hour = Maraithon.TelegramAssistant.PushBroker.local_now_for_user(user_id).hour

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(Application.get_env(:maraithon, :telegram_assistant, []),
        quiet_hours_start_local: rem(local_hour + 2, 24),
        quiet_hours_end_local: rem(local_hour + 3, 24)
      )
    )

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

    [%{payload: payload}] = apns_pushes()
    assert payload["aps"]["alert"]["body"] =~ "customer escalation"

    assert Repo.get!(ProactiveCandidate, candidate.id).status == "delivered"

    receipt = Repo.get_by!(PushReceipt, user_id: user_id, dedupe_key: candidate.dedupe_key)
    assert receipt.decision == "sent_now"
    assert receipt.origin_type == "insight"

    [ledger_entry] =
      ActionLedger.list_recent(user_id, event_type: "proactive.delivery_planned", limit: 1)

    assert ledger_entry.status == "completed"
    assert ledger_entry.metadata["interrupt_now_count"] == 1
  end

  # The phone digest push is the delivery itself — there is no per-candidate
  # card fan-out on mobile. A successfully sent digest must mark every
  # bundled candidate delivered (the stranded-"planned" regression behind
  # the 2026-07-30 stuck-briefs alarms).
  test "digest candidates are grouped behind one parent push and marked delivered", %{
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

    # One doorbell push for the whole digest, not one per candidate.
    [%{payload: payload}] = apns_pushes()
    assert payload["aps"]["alert"]["title"] == "Maraithon digest"
    assert payload["aps"]["alert"]["body"] =~ "review together"

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

    # The push banner must not leak the legacy failure metadata either.
    [%{payload: payload}] = apns_pushes()
    refute payload["aps"]["alert"]["title"] =~ "generation failed"
    refute payload["aps"]["alert"]["body"] =~ "did not produce a valid brief"

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
    assert apns_pushes() == []

    held = Repo.get!(ProactiveCandidate, candidate.id)
    assert held.status == "held"
    assert held.disposition == "hold"
    assert held.plan_reason == "model_hold"
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
    assert apns_pushes() != []

    planned = Repo.get!(ProactiveCandidate, brief_candidate.id)
    assert planned.status == "delivered"
    assert planned.disposition == "interrupt_now"
    assert is_nil(planned.plan_reason)
  end

  test "quiet hours defer planning entirely: no model call, candidates stay pending", %{
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

    # Force quiet hours to cover "now" (whatever hour the suite happens to
    # run at) so this assertion isn't time-of-day-dependent.
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

    # The send-time gate would hold anything the model plans, so planning
    # during quiet hours only burns a model call per cycle all night (the
    # 2026-07-30 churn). The model must not run at all.
    llm_complete = fn _params ->
      flunk("plan_delivery must not be called during quiet hours")
    end

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.planned == 0
    assert result.delivered == 0
    assert apns_pushes() == []

    deferred = Repo.get!(ProactiveCandidate, brief_candidate.id)
    assert deferred.status == "pending"
  end

  test "an urgency-exempt candidate still plans and sends during quiet hours", %{
    user_id: user_id
  } do
    {:ok, urgent} =
      ProactiveQueue.enqueue(
        candidate_attrs(user_id, %{
          title: "Production is down",
          body: "The API has been hard-down for ten minutes.",
          urgency: 0.97,
          dedupe_key: "insight:quiet-hours-exempt"
        })
      )

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

    llm_complete = plan_llm(%{urgent.id => {"interrupt_now", "Hard down; wake the operator."}})

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.interrupt_now == 1
    assert result.delivered == 1

    assert [_push] = apns_pushes()
    assert Repo.get!(ProactiveCandidate, urgent.id).status == "delivered"
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
    assert apns_pushes() == []

    held = Repo.get!(ProactiveCandidate, candidate.id)
    assert held.status == "held"
    assert held.disposition == "hold"
    assert held.plan_reason == "model_hold"
  end

  test "planner batches normal candidates within the response budget", %{user_id: user_id} do
    candidates =
      Enum.map(1..15, fn index ->
        assert {:ok, candidate} =
                 ProactiveQueue.enqueue(
                   candidate_attrs(user_id, %{
                     dedupe_key: "response-budget:#{index}",
                     title: "Bounded candidate #{index}"
                   })
                 )

        candidate
      end)

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id,
               context: %{},
               dispatch: false,
               llm_complete:
                 plan_llm(Map.new(candidates, &{&1.id, {"hold", "Wait for more evidence."}}))
             )

    assert result.planned == 12
    assert length(ProactiveQueue.list_pending_for_user(user_id)) == 3
  end

  test "old low-urgency family work survives an over-cap urgency backlog", %{user_id: user_id} do
    family_todo = %{
      "id" => "family-overflow-todo",
      "title" => "Pick up the child for the family school appointment",
      "priority" => 20,
      "status" => "open",
      "metadata" => %{"relationship_domain" => "family"}
    }

    assert {:ok, family_candidate} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{
                 dedupe_key: "family-overflow-candidate",
                 title: "Family school appointment",
                 urgency: 0.01,
                 structured_data: %{"todo_ids" => [family_todo["id"]]}
               })
             )

    fillers =
      Enum.map(1..55, fn index ->
        assert {:ok, candidate} =
                 ProactiveQueue.enqueue(
                   candidate_attrs(user_id, %{
                     dedupe_key: "family-overflow-filler:#{index}",
                     urgency: 0.99
                   })
                 )

        candidate
      end)

    all_candidates = [family_candidate | fillers]

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id,
               context: %{todos: [family_todo]},
               dispatch: false,
               llm_complete:
                 plan_llm(Map.new(all_candidates, &{&1.id, {"hold", "Model requested a hold."}}))
             )

    assert result.planned == 12

    persisted_family = Repo.get!(ProactiveCandidate, family_candidate.id)
    assert persisted_family.status == "planned"
    assert persisted_family.disposition == "hold"
  end

  test "required briefs survive an over-cap urgency backlog", %{user_id: user_id} do
    fillers =
      Enum.map(1..55, fn index ->
        assert {:ok, candidate} =
                 ProactiveQueue.enqueue(
                   candidate_attrs(user_id, %{
                     dedupe_key: "required-overflow-filler:#{index}",
                     urgency: 0.99
                   })
                 )

        candidate
      end)

    assert {:ok, brief} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{
                 source: "brief",
                 dedupe_key: "required-overflow-brief",
                 title: "Required cadence brief",
                 urgency: 0.01
               })
             )

    all_candidates = [brief | fillers]

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id,
               context: %{},
               dispatch: false,
               llm_complete:
                 plan_llm(Map.new(all_candidates, &{&1.id, {"hold", "Model requested a hold."}}))
             )

    assert result.planned == 12
    assert result.interrupt_now == 1

    persisted_brief = Repo.get!(ProactiveCandidate, brief.id)
    assert persisted_brief.status == "planned"
    assert persisted_brief.disposition == "interrupt_now"
    assert length(ProactiveQueue.list_pending_for_user(user_id)) == 44
  end

  test "full escape-heavy brief lane still reserves oldest and urgent ordinary lanes", %{
    user_id: user_id
  } do
    assert {:ok, oldest} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{
                 dedupe_key: "tight-fairness-oldest",
                 urgency: 0.01,
                 body: String.duplicate("\\\"", 3_000)
               })
             )

    briefs =
      Enum.map(1..12, fn index ->
        assert {:ok, brief} =
                 ProactiveQueue.enqueue(
                   candidate_attrs(user_id, %{
                     source: "brief",
                     dedupe_key: "tight-fairness-brief:#{index}",
                     urgency: 0.5,
                     body: String.duplicate("\\\"", 3_000)
                   })
                 )

        brief
      end)

    assert {:ok, urgent} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{
                 dedupe_key: "tight-fairness-urgent",
                 urgency: 0.99,
                 title: "Urgent customer escalation",
                 body: String.duplicate("\\\"", 3_000)
               })
             )

    all_candidates = [oldest, urgent | briefs]

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id,
               context: %{},
               dispatch: false,
               llm_complete:
                 plan_llm(Map.new(all_candidates, &{&1.id, {"hold", "Model requested a hold."}}))
             )

    assert result.planned == 12

    planned_briefs =
      Enum.count(briefs, fn brief ->
        Repo.get!(ProactiveCandidate, brief.id).status == "planned"
      end)

    assert planned_briefs >= 1
    assert Repo.get!(ProactiveCandidate, oldest.id).status == "planned"
    assert Repo.get!(ProactiveCandidate, urgent.id).status == "planned"
  end

  test "successful attempts rotate remaining backlog so a user beyond the first 25 is reached" do
    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "dispositions" => [],
             "digest_intro" => "",
             "summary" => "Hold this batch."
           })
       }}
    end

    backlogged_users =
      Enum.map(1..25, fn index ->
        user_id =
          "planner-rotation-backlog-#{index}-#{System.unique_integer([:positive])}@example.com"

        {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
        register_push_device(user_id)

        candidates =
          Enum.map(1..13, fn candidate_index ->
            assert {:ok, candidate} =
                     ProactiveQueue.enqueue(
                       candidate_attrs(user_id, %{
                         dedupe_key: "rotation:#{index}:#{candidate_index}",
                         title: "Backlog #{index}-#{candidate_index}",
                         urgency: 0.8
                       })
                     )

            candidate
          end)

        {user_id, candidates}
      end)

    healthy_user =
      "planner-rotation-healthy-#{System.unique_integer([:positive])}@example.com"

    {:ok, _user} = Accounts.get_or_create_user_by_email(healthy_user)
    register_push_device(healthy_user)

    assert {:ok, healthy_candidate} =
             ProactiveQueue.enqueue(
               candidate_attrs(healthy_user, %{
                 dedupe_key: "rotation:healthy",
                 title: "Healthy later user"
               })
             )

    assert %{users: 25, planned: 300} =
             DeliveryPlanner.run_for_due_users(
               batch_size: 25,
               context: %{},
               dispatch: false,
               llm_complete: llm_complete
             )

    assert Repo.get!(ProactiveCandidate, healthy_candidate.id).status == "pending"

    {_first_user, first_candidates} = hd(backlogged_users)

    remaining =
      Enum.find(first_candidates, fn candidate ->
        Repo.get!(ProactiveCandidate, candidate.id).status == "pending"
      end)

    rotated = Repo.get!(ProactiveCandidate, remaining.id)
    assert rotated.inserted_at == remaining.inserted_at
    assert DateTime.compare(rotated.updated_at, remaining.updated_at) in [:gt, :eq]

    assert %{users: 25} =
             DeliveryPlanner.run_for_due_users(
               batch_size: 25,
               context: %{},
               dispatch: false,
               llm_complete: llm_complete
             )

    assert Repo.get!(ProactiveCandidate, healthy_candidate.id).status == "planned"
  end

  test "quote-heavy recalled memory still fits the final whole-message cap", %{user_id: user_id} do
    escape_heavy =
      String.duplicate("\\", 500) <> String.duplicate("\"", 500) <> String.duplicate("\n", 500)

    escaped_memory = "MEMORY-ESCAPE-SENTINEL " <> escape_heavy

    Enum.each(1..6, fn index ->
      assert {:ok, _memory} =
               Memory.write(user_id, %{
                 "kind" => "preference",
                 "title" => "Memory bound candidate #{index}",
                 "content" => escaped_memory,
                 "importance" => 100 - index,
                 "confidence" => 1.0
               })
    end)

    candidates =
      Enum.map(1..12, fn index ->
        assert {:ok, candidate} =
                 ProactiveQueue.enqueue(
                   candidate_attrs(user_id, %{
                     dedupe_key: "memory-bound:#{index}",
                     title: "Memory bound candidate #{index}",
                     body: String.duplicate(escape_heavy, 4),
                     why_now: "Memory bound candidate #{index} is due."
                   })
                 )

        candidate
      end)

    llm_complete = fn params ->
      send(self(), {:memory_bounded_request, params})
      plan_llm(Map.new(candidates, &{&1.id, {"hold", "Respect recalled preference."}})).(params)
    end

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id,
               context: %{},
               dispatch: false,
               llm_complete: llm_complete
             )

    assert result.planned > 0
    assert_receive {:memory_bounded_request, params}

    assert params["messages"]
           |> Maraithon.AssistantHarness.PromptStability.encode!()
           |> byte_size() <= Maraithon.AssistantHarness.delivery_plan_prompt_byte_cap()

    assert get_in(params, ["messages", Access.at(1), "content"]) =~ "MEMORY-ESCAPE-SENTINEL"
  end

  test "whole planner prompt stays byte bounded for pathological candidates and context", %{
    user_id: user_id
  } do
    escaped_unicode = String.duplicate("🙂\"\n", 1_000)
    bounded_why_now = String.duplicate("🙂\"\n", 300)
    todo_ids = Enum.map(1..10, &"todo-#{&1}")

    candidates =
      Enum.map(1..25, fn index ->
        assert {:ok, candidate} =
                 ProactiveQueue.enqueue(
                   candidate_attrs(user_id, %{
                     dedupe_key: "pathological:#{index}",
                     title: "Candidate #{index}",
                     body: escaped_unicode,
                     why_now: bounded_why_now,
                     structured_data: %{
                       "linked_project" => %{
                         "notes" => escaped_unicode,
                         "history" => List.duplicate(escaped_unicode, 20)
                       },
                       "todo_ids" => todo_ids,
                       "untrusted_blob" => "must-not-reach-the-planner-#{escaped_unicode}"
                     }
                   })
                 )

        candidate
      end)

    assert {:ok, small_late_candidate} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{
                 dedupe_key: "pathological:small-late",
                 title: "Small late candidate",
                 body: "A compact candidate should still be considered.",
                 why_now: "It remains due.",
                 urgency: 0.01,
                 structured_data: %{}
               })
             )

    candidates = candidates ++ [small_late_candidate]

    todos =
      Enum.map(todo_ids, fn todo_id ->
        %{
          "id" => todo_id,
          "title" => escaped_unicode,
          "summary" => escaped_unicode,
          "next_action" => escaped_unicode
        }
      end)

    llm_complete = fn params ->
      send(self(), {:planner_request, params})

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "dispositions" =>
               candidates
               |> Enum.filter(fn candidate ->
                 prompt = get_in(params, ["messages", Access.at(1), "content"]) || ""
                 String.contains?(prompt, ~s("id":"#{candidate.id}"))
               end)
               |> Enum.map(fn candidate ->
                 %{
                   "candidate_id" => candidate.id,
                   "disposition" => "hold",
                   "reason" => "Bounded planning test."
                 }
               end),
             "digest_intro" => "",
             "summary" => "Hold the bounded test batch."
           })
       }}
    end

    context = %{
      user: %{"biography" => escaped_unicode},
      preference_memory: List.duplicate(%{"text" => escaped_unicode}, 50),
      calendar: List.duplicate(%{"description" => escaped_unicode}, 50),
      todos: todos
    }

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id,
               context: context,
               dispatch: false,
               llm_complete: llm_complete
             )

    assert result.planned > 0
    assert result.planned < length(candidates)
    assert Repo.get!(ProactiveCandidate, small_late_candidate.id).status == "planned"

    assert_receive {:planner_request, params}

    prompt_bytes =
      params["messages"]
      |> Maraithon.AssistantHarness.PromptStability.encode!()
      |> byte_size()

    prompt = get_in(params, ["messages", Access.at(1), "content"])

    assert prompt_bytes <= Maraithon.AssistantHarness.delivery_plan_prompt_byte_cap()
    assert String.valid?(prompt)
    refute prompt =~ "must-not-reach-the-planner"

    assert length(ProactiveQueue.list_pending_for_user(user_id)) ==
             length(candidates) - result.planned
  end

  test "run_for_due_users drains pending users", %{user_id: first_user_id} do
    second_user_id = "delivery-planner-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(second_user_id)
    CapturingAPNS.enable(second_user_id)

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
  test "users without a push device remain pending without failure noise" do
    user_id = "delivery-planner-no-device-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    assert {:ok, candidate} = ProactiveQueue.enqueue(candidate_attrs(user_id))

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        result =
          DeliveryPlanner.run_for_due_users(
            user_ids: [user_id],
            context: %{},
            llm_complete: fn _params -> flunk("the model must not run without a push device") end
          )

        assert result.failed == 0
        assert result.undeliverable == 1
        assert result.failure_codes == %{}
      end)

    assert log == ""
    assert Repo.get!(ProactiveCandidate, candidate.id).status == "pending"
  end

  test "due-user failures emit warning telemetry without provider bodies", %{user_id: user_id} do
    assert {:ok, _candidate} = ProactiveQueue.enqueue(candidate_attrs(user_id))

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        result =
          DeliveryPlanner.run_for_due_users(
            user_ids: [user_id],
            context: %{},
            llm_complete: fn _params ->
              {:error, {:api_error, 500, %{"secret" => "provider-internal-body"}}}
            end
          )

        assert result.failed == 1
        assert result.failure_codes == %{"api_500" => 1}
      end)

    assert log =~ "Proactive delivery planning failed"
    refute log =~ user_id
    refute log =~ "provider-internal-body"
  end

  test "due-user exceptions are isolated and never log exception text", %{user_id: user_id} do
    assert {:ok, _candidate} = ProactiveQueue.enqueue(candidate_attrs(user_id))

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        result =
          DeliveryPlanner.run_for_due_users(
            user_ids: [user_id],
            context: %{},
            llm_complete: fn _params -> raise "provider-internal-secret" end
          )

        assert result.failed == 1
        assert result.failure_codes == %{"planner_exception" => 1}
      end)

    assert log =~ "Proactive delivery planning failed"
    refute log =~ "provider-internal-secret"
  end

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

    # Insight staging still iterates legacy telegram connected accounts for
    # its destination key (rename refactor pending) even though delivery
    # itself goes to the phone.
    {:ok, _telegram} =
      Maraithon.ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "planner"}
      })

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

  test "a durable unknown receipt quarantines a requeued candidate without another push", %{
    user_id: user_id
  } do
    {:ok, candidate} =
      ProactiveQueue.enqueue(
        candidate_attrs(user_id, %{
          urgency: 0.95,
          dedupe_key: "planner:existing-delivery-unknown"
        })
      )

    assert {:ok, _receipt} =
             Maraithon.TelegramAssistant.record_push_receipt(%{
               user_id: user_id,
               dedupe_key: candidate.dedupe_key,
               origin_type: "insight",
               origin_id: candidate.source_id,
               decision: "delivery_unknown"
             })

    llm_complete = plan_llm(%{candidate.id => {"interrupt_now", "Time-sensitive."}})

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.delivery_unknown == 1
    assert result.delivered == 0
    assert result.failed == 0

    quarantined = Repo.get!(ProactiveCandidate, candidate.id)
    assert quarantined.status == "held"
    assert quarantined.plan_reason == "delivery_unknown"
    assert apns_pushes() == []
  end

  test "rolls candidate quarantine back when source ambiguity repair fails", %{
    user_id: user_id
  } do
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "ambiguity-source", "prompt" => "Test"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    brief =
      %Brief{}
      |> Brief.changeset(%{
        user_id: user_id,
        agent_id: agent.id,
        cadence: "check_in",
        title: "Atomic source repair",
        summary: "Atomic source repair must not split state.",
        body: "Atomic source repair must roll candidate and source changes back together.",
        status: "pending",
        scheduled_for: DateTime.utc_now(),
        dedupe_key: "atomic-source:#{Ecto.UUID.generate()}"
      })
      |> Repo.insert!()

    {:ok, candidate} =
      ProactiveQueue.enqueue(
        candidate_attrs(user_id, %{
          source: "brief",
          source_id: brief.id,
          dedupe_key: "atomic-candidate:#{brief.id}",
          urgency: 0.95
        })
      )

    assert {:ok, _receipt} =
             Maraithon.TelegramAssistant.record_push_receipt(%{
               user_id: user_id,
               dedupe_key: candidate.dedupe_key,
               origin_type: "brief",
               origin_id: brief.id,
               decision: "delivery_unknown"
             })

    suffix = System.unique_integer([:positive])
    function_name = "reject_ambiguous_brief_#{suffix}"
    trigger_name = "reject_ambiguous_brief_trigger_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger AS $$
    BEGIN
      IF NEW.error_message = 'delivery_unknown' THEN
        RAISE EXCEPTION 'injected source repair failure';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE UPDATE ON briefs
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    llm_complete = plan_llm(%{candidate.id => {"interrupt_now", "Time-sensitive."}})

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.delivery_unknown == 1
    assert result.failed == 1
    assert result.held == 0
    assert Repo.get!(ProactiveCandidate, candidate.id).status == "pending"
    assert Repo.get!(Brief, brief.id).status == "pending"

    Repo.query!("DROP TRIGGER #{trigger_name} ON briefs")
    Repo.query!("DROP FUNCTION #{function_name}()")

    assert {:ok, repaired} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert repaired.delivery_unknown == 1
    assert repaired.failed == 0
    assert repaired.held == 1
    assert Repo.get!(ProactiveCandidate, candidate.id).status == "held"

    repaired_brief = Repo.get!(Brief, brief.id)
    assert repaired_brief.status == "failed"
    assert repaired_brief.error_message == "delivery_unknown"
  end

  test "ambiguity quarantine does not overwrite a feedback source state", %{
    user_id: user_id
  } do
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "feedback-source", "prompt" => "Test"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    insight =
      %Insight{}
      |> Insight.changeset(%{
        user_id: user_id,
        agent_id: agent.id,
        source: "test_source",
        category: "general",
        title: "Feedback source state",
        summary: "Confirmed feedback must survive ambiguity quarantine.",
        recommended_action: "Keep the confirmed feedback state.",
        dedupe_key: "feedback-insight:#{Ecto.UUID.generate()}",
        tracking_key: "feedback-track:#{Ecto.UUID.generate()}"
      })
      |> Repo.insert!()

    delivery =
      %Delivery{}
      |> Delivery.changeset(%{
        insight_id: insight.id,
        user_id: user_id,
        channel: "push",
        destination: "mobile",
        score: 0.9,
        threshold: 0.5,
        status: "feedback_helpful",
        feedback: "helpful",
        feedback_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, candidate} =
      ProactiveQueue.enqueue(
        candidate_attrs(user_id, %{
          source: "insight",
          source_id: delivery.id,
          dedupe_key: "feedback-candidate:#{delivery.id}",
          urgency: 0.95
        })
      )

    assert {:ok, _receipt} =
             Maraithon.TelegramAssistant.record_push_receipt(%{
               user_id: user_id,
               dedupe_key: candidate.dedupe_key,
               origin_type: "insight",
               origin_id: delivery.id,
               decision: "delivery_unknown"
             })

    llm_complete = plan_llm(%{candidate.id => {"interrupt_now", "Time-sensitive."}})

    assert {:ok, %{delivery_unknown: 1, held: 1, failed: 0}} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert Repo.get!(ProactiveCandidate, candidate.id).status == "held"
    preserved = Repo.get!(Delivery, delivery.id)
    assert preserved.status == "feedback_helpful"
    assert preserved.feedback == "helpful"
  end

  # The 2026-07-30 stuck-briefs incident: a transient APNs failure at
  # dispatch time left the candidate stranded in "planned" — a status no
  # process ever re-reads — and the live stranded row dedupe-blocked the
  # brief from re-enqueueing until the candidate TTL expired (~2h per
  # failure). Failed dispatches must return candidates to "pending" so the
  # next planner cycle retries them, bounded by expires_at.
  describe "dispatch failure retry contract" do
    defmodule RejectedAPNSHTTP do
      def post(_url, _headers, _body), do: {:ok, 429, ~s({"reason":"TooManyRequests"})}
    end

    defmodule AmbiguousAPNSHTTP do
      def post(_url, _headers, _body), do: {:error, %Mint.TransportError{reason: :closed}}
    end

    setup do
      Application.put_env(
        :maraithon,
        :apns,
        Keyword.put(Application.get_env(:maraithon, :apns), :http_module, RejectedAPNSHTTP)
      )

      :ok
    end

    test "a failed interrupt send returns the candidate to pending instead of stranding it",
         %{user_id: user_id} do
      {:ok, candidate} = ProactiveQueue.enqueue(candidate_attrs(user_id, %{urgency: 0.95}))

      llm_complete = plan_llm(%{candidate.id => {"interrupt_now", "Time-sensitive."}})

      assert {:ok, result} =
               DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

      assert result.failed == 1
      assert result.delivered == 0

      assert Repo.get!(ProactiveCandidate, candidate.id).status == "pending"
    end

    test "an ambiguous interrupt send is quarantined instead of falsely requeued", %{
      user_id: user_id
    } do
      Application.put_env(
        :maraithon,
        :apns,
        Keyword.put(
          Application.get_env(:maraithon, :apns),
          :http_module,
          AmbiguousAPNSHTTP
        )
      )

      {:ok, candidate} = ProactiveQueue.enqueue(candidate_attrs(user_id, %{urgency: 0.95}))
      llm_complete = plan_llm(%{candidate.id => {"interrupt_now", "Time-sensitive."}})

      assert {:ok, result} =
               DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

      assert result.failed == 0
      assert result.delivered == 0
      assert result.delivery_unknown == 1
      assert result.held == 1

      quarantined = Repo.get!(ProactiveCandidate, candidate.id)
      assert quarantined.status == "held"
      assert quarantined.plan_reason == "delivery_unknown"

      assert %PushReceipt{decision: "delivery_unknown"} =
               Repo.get_by!(PushReceipt, user_id: user_id, dedupe_key: candidate.dedupe_key)
    end

    test "a later digest bundle is held without being mislabeled as possibly sent", %{
      user_id: user_id
    } do
      Application.put_env(
        :maraithon,
        :apns,
        Keyword.put(
          Application.get_env(:maraithon, :apns),
          :http_module,
          AmbiguousAPNSHTTP
        )
      )

      {:ok, first} =
        ProactiveQueue.enqueue(candidate_attrs(user_id, %{dedupe_key: "digest-origin:one"}))

      {:ok, second} =
        ProactiveQueue.enqueue(candidate_attrs(user_id, %{dedupe_key: "digest-origin:two"}))

      first_plan =
        plan_llm(%{
          first.id => {"digest", "Batch it."},
          second.id => {"digest", "Batch it."}
        })

      assert {:ok, first_result} =
               DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: first_plan)

      assert first_result.delivery_unknown == 2

      digest_key = "delivery_digest:#{user_id}:#{Date.utc_today() |> Date.to_iso8601()}"
      receipt = Repo.get_by!(PushReceipt, user_id: user_id, dedupe_key: digest_key)
      assert MapSet.new(receipt.metadata["candidate_ids"]) == MapSet.new([first.id, second.id])

      assert MapSet.new(receipt.metadata["candidate_dedupe_hashes"]) ==
               MapSet.new([
                 PushReceipt.dedupe_hash(first.dedupe_key),
                 PushReceipt.dedupe_hash(second.dedupe_key)
               ])

      {:ok, later} =
        ProactiveQueue.enqueue(candidate_attrs(user_id, %{dedupe_key: "digest-later:three"}))

      later_plan = plan_llm(%{later.id => {"digest", "Batch it later."}})

      assert {:ok, later_result} =
               DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: later_plan)

      assert later_result.delivery_unknown == 0
      assert later_result.delivered == 0
      assert later_result.held == 1

      held = Repo.get!(ProactiveCandidate, later.id)
      assert held.status == "held"
      assert held.plan_reason == "daily_digest_delivery_unknown"
    end

    test "digest dedupe membership fences a re-enqueued child even if disposition drifts", %{
      user_id: user_id
    } do
      child_dedupe_key = "digest-reenqueued:stable-child"
      old_candidate_id = Ecto.UUID.generate()
      digest_key = "delivery_digest:#{user_id}:#{Date.utc_today() |> Date.to_iso8601()}"

      assert {:ok, _receipt} =
               Maraithon.TelegramAssistant.record_push_receipt(%{
                 user_id: user_id,
                 dedupe_key: digest_key,
                 origin_type: "assistant_digest",
                 origin_id: digest_key,
                 decision: "delivery_unknown",
                 metadata: %{
                   "candidate_ids" => [old_candidate_id],
                   "candidate_dedupe_hashes" => [PushReceipt.dedupe_hash(child_dedupe_key)]
                 }
               })

      {:ok, replacement} =
        ProactiveQueue.enqueue(
          candidate_attrs(user_id, %{
            dedupe_key: child_dedupe_key,
            urgency: 0.95
          })
        )

      refute replacement.id == old_candidate_id
      llm_complete = plan_llm(%{replacement.id => {"interrupt_now", "Disposition drifted."}})

      assert {:ok, result} =
               DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

      assert result.delivery_unknown == 1
      assert result.delivered == 0
      assert result.held == 1
      assert apns_pushes() == []

      quarantined = Repo.get!(ProactiveCandidate, replacement.id)
      assert quarantined.status == "held"
      assert quarantined.plan_reason == "delivery_unknown"
    end

    test "invalid digest membership metadata is quarantined conservatively", %{user_id: user_id} do
      Application.put_env(
        :maraithon,
        :apns,
        Keyword.put(
          Application.get_env(:maraithon, :apns),
          :http_module,
          AmbiguousAPNSHTTP
        )
      )

      {:ok, original} =
        ProactiveQueue.enqueue(candidate_attrs(user_id, %{dedupe_key: "digest-invalid:original"}))

      original_plan = plan_llm(%{original.id => {"digest", "Batch it."}})

      assert {:ok, %{delivery_unknown: 1}} =
               DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: original_plan)

      digest_key = "delivery_digest:#{user_id}:#{Date.utc_today() |> Date.to_iso8601()}"
      receipt = Repo.get_by!(PushReceipt, user_id: user_id, dedupe_key: digest_key)

      receipt
      |> Ecto.Changeset.change(metadata: %{"candidate_ids" => [123]})
      |> Repo.update!()

      {:ok, later} =
        ProactiveQueue.enqueue(candidate_attrs(user_id, %{dedupe_key: "digest-invalid:later"}))

      later_plan = plan_llm(%{later.id => {"digest", "Batch it later."}})

      assert {:ok, %{delivery_unknown: 1, held: 1}} =
               DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: later_plan)

      quarantined = Repo.get!(ProactiveCandidate, later.id)
      assert quarantined.status == "held"
      assert quarantined.plan_reason == "delivery_unknown"
    end

    test "a failed digest send returns every bundled candidate to pending", %{user_id: user_id} do
      {:ok, first} =
        ProactiveQueue.enqueue(candidate_attrs(user_id, %{dedupe_key: "digest-fail:one"}))

      {:ok, second} =
        ProactiveQueue.enqueue(candidate_attrs(user_id, %{dedupe_key: "digest-fail:two"}))

      llm_complete =
        plan_llm(%{
          first.id => {"digest", "Batch it."},
          second.id => {"digest", "Batch it."}
        })

      assert {:ok, result} =
               DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

      assert result.failed == 2
      assert result.delivered == 0

      assert Repo.get!(ProactiveCandidate, first.id).status == "pending"
      assert Repo.get!(ProactiveCandidate, second.id).status == "pending"
    end

    test "an ambiguous digest send quarantines every bundled candidate", %{user_id: user_id} do
      Application.put_env(
        :maraithon,
        :apns,
        Keyword.put(
          Application.get_env(:maraithon, :apns),
          :http_module,
          AmbiguousAPNSHTTP
        )
      )

      {:ok, first} =
        ProactiveQueue.enqueue(candidate_attrs(user_id, %{dedupe_key: "digest-unknown:one"}))

      {:ok, second} =
        ProactiveQueue.enqueue(candidate_attrs(user_id, %{dedupe_key: "digest-unknown:two"}))

      llm_complete =
        plan_llm(%{
          first.id => {"digest", "Batch it."},
          second.id => {"digest", "Batch it."}
        })

      assert {:ok, result} =
               DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

      assert result.failed == 0
      assert result.delivered == 0
      assert result.delivery_unknown == 2
      assert result.held == 2

      assert Repo.get!(ProactiveCandidate, first.id).status == "held"
      assert Repo.get!(ProactiveCandidate, second.id).status == "held"
    end
  end

  # The digest sibling of the stranding bug: on the phone there is no
  # Telegram conversation, so a successfully sent digest push used to fall
  # into the "conversation vanished" failure branch and strand its
  # candidates while the user had already been notified.
  test "a mobile digest push marks bundled brief rows sent", %{user_id: user_id} do
    {:ok, agent} =
      Maraithon.Agents.create_agent(%{
        user_id: user_id,
        behavior: "inbox_calendar_advisor",
        config: %{}
      })

    {:ok, brief} =
      Maraithon.Briefs.record(user_id, agent.id, %{
        "cadence" => "check_in",
        "title" => "Afternoon check-in: two open loops",
        "summary" => "Two loops need a look before the end of the day.",
        "body" => "- Approve the release\n- Submit the karate form",
        "scheduled_for" => DateTime.utc_now(),
        "dedupe_key" => "brief:planner-digest-brief"
      })

    {:ok, candidate} =
      ProactiveQueue.enqueue(
        candidate_attrs(user_id, %{
          source: "brief",
          source_id: brief.id,
          dedupe_key: "brief:#{brief.id}",
          title: "Afternoon check-in: two open loops",
          body: "Two loops need a look before the end of the day."
        })
      )

    llm_complete = plan_llm(%{candidate.id => {"digest", "Batch it with the digest."}})

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.delivered == 1
    assert result.failed == 0

    assert Repo.get!(ProactiveCandidate, candidate.id).status == "delivered"
    assert Repo.get!(Maraithon.Briefs.Brief, brief.id).status == "sent"
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

      llm_complete =
        plan_llm(%{candidate.id => {"interrupt_now", "The follow-up moment arrived."}})

      assert {:ok, result} =
               DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

      assert result.interrupt_now == 1
      assert result.delivered == 1
      assert result.failed == 0

      assert Repo.get!(ProactiveCandidate, candidate.id).status == "delivered"

      receipt = Repo.get_by!(PushReceipt, user_id: user_id, dedupe_key: candidate.dedupe_key)
      assert receipt.origin_type == "nudge"
      assert receipt.decision == "sent_now"

      [%{payload: payload}] = apns_pushes()
      assert payload["aps"]["alert"]["body"] =~ "waiting on Elena"
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
    fn params ->
      prompt = get_in(params, ["messages", Access.at(1), "content"]) || ""

      dispositions =
        dispositions_by_id
        |> Enum.filter(fn {candidate_id, _decision} ->
          String.contains?(prompt, ~s("id":"#{candidate_id}"))
        end)
        |> Enum.map(fn {candidate_id, {disposition, reason}} ->
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

  defp apns_pushes do
    CapturingAPNS.recorded()
  end

  defp register_push_device(user_id) do
    {:ok, _device} =
      Maraithon.Push.Devices.register(user_id, %{
        device_token: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      })
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
