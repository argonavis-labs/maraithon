defmodule Maraithon.TelegramAssistant.TodoActionsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.Memory
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

  test "legacy generic commitment cards are rewritten with person, topic, and next step" do
    todo = %{
      "id" => Ecto.UUID.generate(),
      "source" => "gmail",
      "status" => "open",
      "title" => "User committed to follow-up with Alex Müller; follow-up not yet sent.",
      "summary" => "User committed to follow-up with Alex Müller; follow-up not yet sent.",
      "next_action" =>
        "Reply now with owner, ETA, and the exact artifact or update you committed to.",
      "metadata" => %{
        "subject" => "Starteryou UGC Campaigns",
        "company" => "Starteryou",
        "why_it_matters" => "Alex is waiting on the UGC campaign materials decision.",
        "source_evidence" => "You said you would follow up on Starteryou UGC campaign timing.",
        "record" => %{
          "person" => "Alex Müller",
          "relationship_context" => "Starteryou UGC campaign contact",
          "commitment" => "Follow through on \"Starteryou UGC Campaigns\" for Alex Müller"
        }
      }
    }

    payload = TodoActions.telegram_payload(todo)

    assert payload.text =~ "Alex Müller"
    assert payload.text =~ "Starteryou UGC Campaigns"
    assert payload.text =~ "Starteryou UGC campaign contact"
    assert payload.text =~ "Reply to Alex Müller about Starteryou UGC Campaigns"
    refute payload.text =~ "User committed"
    refute payload.text =~ "owner, ETA"
    refute payload.text =~ "exact artifact or update"
  end

  test "see less callback records negative memory and dismisses todo", %{user_id: user_id} do
    install_see_less_model()

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "title" => "Read generic vendor newsletter",
          "summary" => "A broad vendor newsletter has no direct ask.",
          "next_action" => "No action needed.",
          "priority" => 40,
          "dedupe_key" => "todo-actions:see-less"
        }
      ])

    payload = TodoActions.telegram_payload(todo)
    buttons = payload.reply_markup["inline_keyboard"] |> List.flatten()
    assert Enum.any?(buttons, &(&1["text"] == "See Less"))

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          chat_id: 12345,
          message_id: "todo-see-less",
          callback_id: "cb-see-less",
          data: "tgtodo:#{todo.id}:see_less"
        }
      })

    updated = Todos.get_for_user(user_id, todo.id)
    assert updated.status == "dismissed"
    assert get_in(updated.metadata, ["assistant_feedback", "value"]) == "see_less"

    [memory] =
      Memory.list_items(user_id,
        kind: "relevance_feedback",
        tag: "todo_relevance",
        limit: 5
      )

    assert memory.polarity == "negative"
    assert memory.source_ref_id == todo.id
    assert last_telegram_message(:callback).opts[:text] == "I'll show fewer todos like this"
  end

  defp last_telegram_message(type) do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.type == type))
    |> List.last()
  end

  defp install_see_less_model do
    original = Application.get_env(:maraithon, :todos, [])

    Application.put_env(
      :maraithon,
      :todos,
      Keyword.put(original, :see_less_llm_complete, fn prompt ->
        assert prompt =~ "TODO_SEE_LESS_TRAINING_JSON_V1"

        {:ok,
         Jason.encode!(%{
           "title" => "See less: generic vendor newsletters",
           "summary" => "Generic vendor newsletters without direct asks should not become todos.",
           "content" =>
             "When a vendor newsletter is informational and has no direct ask, skip it instead of creating a todo.",
           "pattern_key" => "generic_vendor_newsletters_without_direct_asks",
           "categories" => ["newsletter", "vendor", "no_direct_ask"],
           "negative_signals" => ["broadcast update", "no direct ask"],
           "exceptions" => ["explicit deadline", "customer impact"],
           "confidence" => 0.87,
           "reasoning" => "The selected todo is not actionable."
         })}
      end)
    )

    on_exit(fn -> Application.put_env(:maraithon, :todos, original) end)
  end
end
