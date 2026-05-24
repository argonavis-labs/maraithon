defmodule Maraithon.TelegramAssistant.TodoActionsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.TelegramAssistant.TodoActions
  alias Maraithon.TestSupport.CapturingTelegram
  alias Maraithon.Todos

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    original_insights = Application.get_env(:maraithon, :insights, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights, telegram_module: CapturingTelegram)
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights)
    end)

    user_id = "todo-actions-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "todo-actions"}
      })

    %{user_id: user_id}
  end

  test "important callback marks a stale item important", %{user_id: user_id} do
    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "title" => "Check if Dan Bourke still matters",
          "summary" => "This old follow-up may no longer be important.",
          "next_action" => "Confirm whether this is still important to handle.",
          "priority" => 40,
          "dedupe_key" => "todo-actions:important"
        }
      ])

    payload = TodoActions.telegram_payload(todo)
    buttons = payload.reply_markup["inline_keyboard"] |> List.flatten()
    assert Enum.any?(buttons, &(&1["text"] == "Important"))

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          chat_id: 12345,
          message_id: "todo-important",
          callback_id: "cb-important",
          data: "tgtodo:#{todo.id}:important"
        }
      })

    updated = Todos.get_for_user(user_id, todo.id)
    assert updated.priority == 90
    assert updated.attention_mode == "act_now"
    assert get_in(updated.metadata, ["assistant_feedback", "value"]) == "important"
    assert get_in(updated.metadata, ["importance_override", "value"]) == "important"
    assert last_telegram_message(:callback).opts[:text] == "Marked important"
  end

  test "commitment cards include company and relationship context" do
    todo = %{
      "id" => Ecto.UUID.generate(),
      "source" => "gmail",
      "status" => "open",
      "title" => "You committed to Dan Bourke and no follow-up has gone out yet.",
      "summary" =>
        "Commitment to Dan Bourke to follow up remains open and overdue with no evidence of completion.",
      "next_action" => "Ask if this is still important before spending time on it.",
      "metadata" => %{
        "record" => %{
          "person" => "Dan Bourke",
          "company" => "A-Team",
          "relationship_context" => "video project contact",
          "commitment" => "Dan asked about the Claude Cowork killer artifact."
        }
      }
    }

    payload = TodoActions.telegram_payload(todo)

    assert payload.text =~ "Dan Bourke (A-Team; video project contact)"
    assert payload.text =~ "Claude Cowork killer artifact"
  end

  defp last_telegram_message(type) do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.type == type))
    |> List.last()
  end
end
