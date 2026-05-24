defmodule Maraithon.TelegramAssistant.ProactiveTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.PushReceipt
  alias Maraithon.TestSupport.CapturingTelegram
  alias Maraithon.Todos

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
        telegram_proactive_checkins_enabled: true,
        telegram_unified_push_enabled: true
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
    end)

    user_id = "proactive-assistant-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "kent"}
      })

    %{user_id: user_id}
  end

  test "model-backed proactive planner sends a Telegram check-in and records a receipt", %{
    user_id: user_id
  } do
    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("rippling-eligibility", "Reply to Rippling about employment eligibility")
      ])

    llm_complete = fn params ->
      prompt = get_in(params, ["messages", Access.at(1), "content"])

      assert prompt =~ "Proactive decision contract:"
      assert prompt =~ "Reply to Rippling about employment eligibility"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "decision" => "send_now",
             "assistant_message" =>
               "Rippling still needs the employment eligibility reply today.\nNext: reply with the requested eligibility details.",
             "message_class" => "todo_digest",
             "urgency" => 0.94,
             "interrupt_now" => true,
             "dedupe_key" => "proactive:rippling:#{todo.id}",
             "todo_ids" => [todo.id],
             "summary" => "The open todo is high priority and timely."
           })
       }}
    end

    assert {:ok, result} =
             TelegramAssistant.deliver_proactive_check_in(user_id,
               force: true,
               llm_complete: llm_complete
             )

    assert result["decision"] == "sent_now"
    assert result["todo_items_sent"] == 1

    [intro, todo_card] = telegram_messages()
    assert intro.text =~ "Rippling still needs"
    assert todo_card.text =~ "Reply in-thread and close the loop."
    assert todo_card.text =~ "This Gmail thread still needs a user response."
    refute todo_card.text =~ "Reply to Rippling about employment eligibility"
    refute todo_card.text =~ "Maraithon Todo"
    refute todo_card.text =~ "About:"

    receipt =
      Repo.one!(
        from receipt in PushReceipt,
          where: receipt.user_id == ^user_id,
          where: receipt.origin_type == "assistant_digest",
          limit: 1
      )

    assert receipt.decision == "sent_now"
    assert receipt.dedupe_key == "proactive:rippling:#{todo.id}"

    [ledger_entry] = ActionLedger.list_recent(user_id, event_type: "proactive.sent", limit: 1)
    assert ledger_entry.status == "sent"
    assert ledger_entry.model_summary == "The open todo is high priority and timely."
    assert ledger_entry.source_evidence["todo_ids"] == [todo.id]
    assert ledger_entry.result_object_refs["dedupe_key"] == "proactive:rippling:#{todo.id}"
  end

  test "model hold decisions do not send Telegram messages", %{user_id: user_id} do
    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "decision" => "hold",
             "assistant_message" => "",
             "message_class" => "assistant_push",
             "urgency" => 0.1,
             "interrupt_now" => false,
             "dedupe_key" => "proactive:hold",
             "todo_ids" => [],
             "summary" => "Nothing needs a proactive interruption."
           })
       }}
    end

    assert {:ok, %{"decision" => "hold"}} =
             TelegramAssistant.deliver_proactive_check_in(user_id,
               force: true,
               llm_complete: llm_complete
             )

    assert telegram_messages() == []

    [ledger_entry] = ActionLedger.list_recent(user_id, event_type: "proactive.held", limit: 1)
    assert ledger_entry.status == "held"
    assert ledger_entry.model_summary == "Nothing needs a proactive interruption."
    assert ledger_entry.source_evidence["dedupe_key"] == "proactive:hold"
  end

  test "feedback verification rewrites stale backlog dumps before Telegram delivery", %{
    user_id: user_id
  } do
    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "title" => "Dan Bourke artifact status",
          "summary" =>
            "Commitment to Dan Bourke remains open and overdue with no evidence of completion.",
          "next_action" => "Confirm whether this is still important to handle.",
          "priority" => 40,
          "source_occurred_at" => "2026-05-01T14:00:00Z",
          "dedupe_key" => "gmail:dan-bourke-stale",
          "metadata" => %{
            "record" => %{
              "person" => "Dan Bourke",
              "company" => "A-Team",
              "relationship_context" => "video project contact",
              "commitment" => "Dan asked about the Claude Cowork killer artifact."
            }
          }
        }
      ])

    llm_complete = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "decision" => "send_now",
             "assistant_message" => """
             You have several overdue follow-ups that need your attention:
             • Dan Bourke: confirm the artifact status and give a concrete ETA.
             • Matthew Diakonov: confirm the artifact status and give a concrete ETA.
             • Faye Pang: update on shared materials and next steps.
             • Halah AlQahtani: confirm introduction and follow-up status.
             Also, several recent meetings need a follow-up recap with owners and next steps, including Emma's Soccer Practice.
             Prioritize sending these follow-ups now to keep commitments on track and maintain relationships.
             """,
             "message_class" => "assistant_push",
             "urgency" => 0.92,
             "interrupt_now" => true,
             "dedupe_key" => "proactive:bad-backlog",
             "todo_ids" => [todo.id],
             "summary" => "Several overdue follow-ups need attention."
           })
       }}
    end

    assert {:ok, result} =
             TelegramAssistant.deliver_proactive_check_in(user_id,
               force: true,
               context: %{todos: [Todos.serialize_for_prompt(todo)]},
               llm_complete: llm_complete
             )

    assert result["decision"] == "sent_now"
    assert result["todo_items_sent"] == 1

    [intro, todo_card] = telegram_messages()
    assert intro.text =~ "older follow-up"
    assert intro.text =~ "Dan Bourke"
    assert intro.text =~ "Mark it important"
    refute intro.text =~ "several overdue follow-ups"
    refute intro.text =~ "Emma's Soccer Practice"
    assert todo_card.text =~ "Dan Bourke (A-Team; video project contact)"
  end

  defp telegram_messages do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.type == :send))
  end

  defp todo_attrs(thread_id, title) do
    %{
      "source" => "gmail",
      "kind" => "gmail_triage",
      "attention_mode" => "act_now",
      "title" => title,
      "summary" => "This Gmail thread still needs a user response.",
      "next_action" => "Reply in-thread and close the loop.",
      "priority" => 95,
      "source_item_id" => thread_id,
      "source_occurred_at" => "2026-05-09T14:00:00Z",
      "dedupe_key" => "gmail:gmail_triage:#{thread_id}",
      "metadata" => %{"thread_id" => thread_id}
    }
  end
end
