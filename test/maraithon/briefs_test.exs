defmodule Maraithon.BriefsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.Todos

  setup do
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(:maraithon, :briefs,
      telegram_module: Maraithon.TestSupport.CapturingTelegram
    )

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant, telegram_unified_push_enabled: false)
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :briefs)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
    end)

    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

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
    assert Briefs.todo_digest_prefix_text(brief, first_todo) == "<b>New Today</b>"
    assert Briefs.todo_digest_prefix_text(brief, second_todo) == "<b>Still Open</b>"
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
end
