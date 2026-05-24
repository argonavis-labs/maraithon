defmodule Maraithon.BriefsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.BriefTodoReview
  alias Maraithon.TelegramAssistant.TodoActions
  alias Maraithon.Todos

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
               "title" => "Check-in: 2 items still need movement",
               "summary" => "Two open communication loops still need movement.",
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
    assert intro =~ "checking on these today"
    assert intro =~ "1 new today"
    assert intro =~ "1 still open from earlier"
    assert intro =~ "Tap List Todos"
    assert is_nil(Briefs.todo_digest_prefix_text(brief, first_todo))
    assert is_nil(Briefs.todo_digest_prefix_text(brief, second_todo))
  end

  test "brief todo review lists one todo at a time and summarizes decisions", %{
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
      |> Enum.find(&(&1["text"] == "List Todos"))

    assert button["callback_data"] =~ "brftd:"

    :ok =
      BriefTodoReview.handle_callback(%{
        chat_id: 777_123,
        callback_id: "cb-list",
        data: button["callback_data"]
      })

    sends = sent_messages()
    assert length(sends) == 1
    assert hd(sends).text =~ "Todo 1 of 2"
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
    assert List.last(sends).text =~ "Todo 2 of 2"
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
    assert summary.text =~ "Todo review complete"
    assert summary.text =~ "Done: 1"
    assert summary.text =~ "Dismissed: 1"
    assert summary.text =~ "Still open: 0"
    assert summary.text =~ "Tomorrow's briefing will build on this"

    updated_brief = Repo.get!(Brief, brief.id)
    assert get_in(updated_brief.metadata, ["todo_review", "status"]) == "completed"
    assert get_in(updated_brief.metadata, ["todo_review", "summary", "done_count"]) == 1
  end

  test "telegram text request starts latest todo review and advances after each action", %{
    user_id: user_id,
    agent: agent
  } do
    assert BriefTodoReview.text_review_request?("Let's go through my todos one at a time")
    assert BriefTodoReview.text_review_request?("List Todos")
    refute BriefTodoReview.text_review_request?("Add buy milk to my todo list")
    refute BriefTodoReview.text_review_request?("What's on my todo list?")

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
    assert hd(sends).text =~ "Todo 1 of 2"
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
    assert List.last(sends).text =~ "Todo 2 of 2"
    assert List.last(sends).text =~ second_todo.next_action
  end

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
end
