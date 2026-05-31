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
    assert intro.text =~ "Two updates are worth a look together"
    assert intro.text =~ "morning brief has two open follow-ups"
    assert intro.text =~ "Rippling work item still needs a reply"
    refute intro.text =~ "proactive updates"
    refute intro.text =~ "todo"
    assert first_card.text =~ "morning brief"
    refute first_card.text =~ "open loops"
    assert second_card.text =~ "Rippling"
    assert second_card.text =~ "work item still needs a reply"
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

    assert {:ok, result} =
             DeliveryPlanner.run_for_user(user_id, context: %{}, llm_complete: llm_complete)

    assert result.planned == 1
    assert result.held == 1
    assert telegram_messages() == []
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
