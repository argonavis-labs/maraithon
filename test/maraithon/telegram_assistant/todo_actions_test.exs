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
    assert Enum.any?(buttons, &(&1["text"] == "Keep active"))

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
    assert last_telegram_message(:callback).opts[:text] == "Kept active"
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
    assert payload.text =~ "Decision: Choose the next move with Dan Bourke."
    refute payload.text =~ "Decision: Decide whether"
  end

  test "source link buttons name the source app" do
    source_url = "https://mail.google.com/mail/u/0/#inbox/thread-1"

    todo = %{
      "id" => Ecto.UUID.generate(),
      "source" => "gmail",
      "status" => "open",
      "title" => "Reply to the partner thread",
      "summary" => "The partner is waiting on a short reply.",
      "next_action" => "Send the partner a clear next step.",
      "metadata" => %{"url" => source_url}
    }

    payload = TodoActions.telegram_payload(todo)
    buttons = payload.reply_markup["inline_keyboard"] |> List.flatten()

    assert Enum.any?(buttons, &(&1["text"] == "Open Gmail" and &1["url"] == source_url))
    refute Enum.any?(buttons, &(&1["text"] == "Open Source"))
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

  test "draftable email todo cards generate an approval-ready draft from Telegram", %{
    user_id: user_id
  } do
    original_assistant_config = Application.get_env(:maraithon, :telegram_assistant, [])
    test_pid = self()

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.put(original_assistant_config, :draft_opts,
        llm_complete: fn params ->
          send(test_pid, {:draft_params, params})

          {:ok,
           %{
             content:
               Jason.encode!(%{
                 "subject" => "Re: Starteryou UGC Campaigns",
                 "body" =>
                   "Hi Alex,\n\nI can send the campaign next step today. I will confirm the asset order and timing before I send anything final."
               })
           }}
        end
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :telegram_assistant, original_assistant_config)
    end)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "status" => "open",
          "title" => "Reply to Alex Müller about Starteryou UGC Campaigns",
          "summary" => "Alex is waiting on the UGC campaign materials decision.",
          "next_action" =>
            "Reply to Alex Müller about Starteryou UGC Campaigns with the recommended next step.",
          "source_item_id" => "thread-alex-starteryou",
          "dedupe_key" => "todo-actions:draft-email",
          "metadata" => %{
            "subject" => "Starteryou UGC Campaigns",
            "source_evidence" => "You said you would follow up on campaign timing.",
            "record" => %{
              "person" => "Alex Müller",
              "company" => "Starteryou",
              "relationship_context" => "UGC campaign contact"
            }
          }
        }
      ])

    payload = TodoActions.telegram_payload(todo)
    buttons = payload.reply_markup["inline_keyboard"] |> List.flatten()

    assert Enum.any?(buttons, &(&1["text"] == "Draft Email"))

    open_button = Enum.find(buttons, &(&1["text"] == "Open Maraithon"))
    assert open_button["url"] =~ "/todos?todo_id=#{todo.id}"

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          chat_id: 12345,
          message_id: "todo-draft-email",
          callback_id: "cb-draft-email",
          data: "tgtodo:#{todo.id}:draft_email"
        }
      })

    assert last_telegram_message(:callback).opts[:text] == "Draft ready"
    assert_receive {:draft_params, %{"messages" => [%{"content" => prompt}]}}, 500
    assert prompt =~ "thread-alex-starteryou"
    assert prompt =~ "Prepare this for approval. Do not send it."

    sent = last_telegram_message(:send)
    assert sent.opts[:reply_to] == "todo-draft-email"
    assert sent.text =~ "<b>Email draft ready</b>"
    assert sent.text =~ "<b>Subject:</b> Re: Starteryou UGC Campaigns"
    assert sent.text =~ "Hi Alex"
    assert sent.text =~ "Review before sending."
    refute sent.text =~ "sent anything"
  end

  test "assistant-sourced cards do not hardcode the operator name" do
    todo = %{
      "id" => Ecto.UUID.generate(),
      "source" => "chief_of_staff_morning_briefing",
      "status" => "open",
      "title" => "Review Runner launch note",
      "summary" => "The GTM channel needs review before the launch window.",
      "next_action" => "next: review the launch note and approve or leave edits.",
      "metadata" => %{
        "why_now" => "The launch window is today."
      }
    }

    payload = TodoActions.telegram_payload(todo)

    assert payload.text =~ "<b>Review the launch note and approve or leave edits.</b>"
    refute payload.text =~ "Kent,"
    refute payload.text =~ "the user"
  end

  test "assistant-sourced cards preserve direct you-language without adding a name" do
    todo = %{
      "id" => Ecto.UUID.generate(),
      "source" => "chief_of_staff_commitment_tracker",
      "status" => "open",
      "title" => "Reply to Sarah",
      "summary" => "Sarah is waiting on the deck from chief_of_staff_commitment_tracker.",
      "next_action" =>
        "You should send Sarah the current deck and call out the two open risks from chief_of_staff_commitment_tracker."
    }

    payload = TodoActions.telegram_payload(todo)

    assert payload.text =~ "<b>You should send Sarah the current deck"
    assert payload.text =~ "the open work review"
    refute payload.text =~ "Kent,"
    refute payload.text =~ "Kent"
    refute payload.text =~ "chief_of_staff"
    refute payload.text =~ "commitment tracker"
  end

  test "todo cards do not corrupt product user terminology" do
    todo = %{
      "id" => Ecto.UUID.generate(),
      "source" => "github",
      "status" => "open",
      "title" => "Fix the user interface reload regression",
      "summary" =>
        "The user interface flashes after reload and the user experience feels unstable.",
      "next_action" =>
        "Review the user's account settings page and confirm which state changes trigger the flash."
    }

    payload = TodoActions.telegram_payload(todo)

    assert payload.text =~ "The user interface"
    assert payload.text =~ "the user experience"
    assert payload.text =~ "the user's account settings"
    refute payload.text =~ "you interface"
    refute payload.text =~ "you experience"
    refute payload.text =~ "your account settings"
  end

  test "todo card source line humanizes local and namespaced source keys" do
    todo = %{
      "id" => Ecto.UUID.generate(),
      "source" => "voice_memos",
      "status" => "open",
      "title" => "Review launch recording",
      "summary" => "The recording contains the launch decision.",
      "next_action" => "Review the launch recording and extract the owner decision."
    }

    payload = TodoActions.telegram_payload(todo)

    assert payload.text =~ "From Voice Memos."
    refute payload.text =~ "Voice_memos"
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
    assert Enum.any?(buttons, &(&1["text"] == "Show less"))

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

    assert last_telegram_message(:callback).opts[:text] ==
             "Maraithon will show fewer like this"

    edit = last_telegram_message(:edit)
    assert edit.text =~ "Feedback: Show less"
    refute edit.text =~ "Feedback noted:"
    refute edit.text =~ "I'll show fewer"
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
