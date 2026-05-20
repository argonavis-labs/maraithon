defmodule Maraithon.TelegramAssistant.ProactiveSourceEnqueueTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.ProactiveCandidate
  alias Maraithon.TestSupport.CapturingTelegram

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    original_insights = Application.get_env(:maraithon, :insights, [])
    original_briefs = Application.get_env(:maraithon, :briefs, [])
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights, telegram_module: CapturingTelegram)
    )

    Application.put_env(
      :maraithon,
      :briefs,
      Keyword.merge(original_briefs, telegram_module: CapturingTelegram)
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
      Application.put_env(:maraithon, :briefs, original_briefs)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
    end)

    user_id = "source-enqueue-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "inbox_calendar_advisor",
        config: %{}
      })

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "source-enqueue"}
      })

    %{user_id: user_id, agent: agent}
  end

  test "insight delivery enqueues instead of sending when the planner is enabled", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
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

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)

    assert result.sent == 1
    assert telegram_messages() == []

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    assert delivery.status == "pending"

    candidate =
      Repo.get_by!(ProactiveCandidate,
        user_id: user_id,
        source: "insight",
        source_id: delivery.id
      )

    assert candidate.status == "pending"
    assert candidate.dedupe_key == "insight_delivery:#{delivery.id}"
    assert candidate.body =~ "Reply to customer escalation"
  end

  test "brief delivery enqueues instead of sending when the planner is enabled", %{
    user_id: user_id,
    agent: agent
  } do
    assert {:ok, %Brief{} = brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning brief: 2 loops worth watching",
               "summary" => "Two high-signal loops look open this morning.",
               "body" => "- [Gmail] Send the deck\n- [Slack] Post owners and next steps",
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "brief:planner:morning"
             })

    assert :ok = Briefs.send_brief(brief)
    assert telegram_messages() == []

    assert Repo.get!(Brief, brief.id).status == "pending"

    candidate =
      Repo.get_by!(ProactiveCandidate,
        user_id: user_id,
        source: "brief",
        source_id: brief.id
      )

    assert candidate.status == "pending"
    assert candidate.dedupe_key == "brief:#{brief.id}"
    assert candidate.body =~ "Morning brief"
  end

  test "proactive check-in send decisions enqueue instead of sending", %{user_id: user_id} do
    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "decision" => "send_now",
             "assistant_message" => "Rippling still needs an eligibility reply today.",
             "message_class" => "assistant_push",
             "urgency" => 0.91,
             "interrupt_now" => true,
             "dedupe_key" => "proactive:planner:rippling",
             "todo_ids" => [],
             "summary" => "A high-priority open loop is timely."
           })
       }}
    end

    assert {:ok, %{"decision" => "queued", "candidate_id" => candidate_id}} =
             TelegramAssistant.deliver_proactive_check_in(user_id,
               force: true,
               llm_complete: llm_complete
             )

    assert telegram_messages() == []

    candidate = Repo.get!(ProactiveCandidate, candidate_id)
    assert candidate.source == "proactive_check_in"
    assert candidate.status == "pending"
    assert candidate.body =~ "Rippling"
    assert candidate.structured_data["interrupt_now"] == true
  end

  defp telegram_messages do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.type == :send))
  end
end
