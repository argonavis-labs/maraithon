defmodule Maraithon.InsightNotificationsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.DeliveryErrorCopy
  alias Maraithon.InsightNotifications
  alias Maraithon.InsightNotifications.{Delivery, ThresholdProfile}
  alias Maraithon.Insights
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.ChatWorker
  alias MaraithonWeb.TelegramLink

  setup do
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])
    original_chat_worker = Application.get_env(:maraithon, ChatWorker, [])

    Application.put_env(:maraithon, :insights,
      telegram_module: Maraithon.TestSupport.FakeTelegram
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :insights)
      Application.delete_env(:maraithon, :failing_telegram)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
      Application.put_env(:maraithon, ChatWorker, original_chat_worker)
    end)

    user_id = "notify-user@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "inbox_calendar_advisor",
        config: %{}
      })

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "kent"}
      })

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
          "dedupe_key" => "email:notify:reply_urgent"
        }
      ])

    %{user_id: user_id, insight: insight}
  end

  describe "dispatch_telegram_batch/1" do
    test "stages and sends eligible insights", %{user_id: user_id, insight: insight} do
      result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)

      assert result.staged >= 1
      assert result.sent == 1

      delivery =
        Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

      assert delivery.status == "sent"
      assert delivery.provider_message_id == "123"
      assert delivery.score >= delivery.threshold
    end

    test "an explicit admission pause neither stages nor sends insight deliveries", %{
      user_id: user_id,
      insight: insight
    } do
      use_failing_delivery(:unexpected_send,
        telegram_full_chat_enabled: false,
        telegram_unified_push_enabled: false,
        proactive_delivery_planner_enabled: false
      )

      assert InsightNotifications.dispatch_telegram_batch(batch_size: 10) == %{
               staged: 0,
               sent: 0,
               failed: 0
             }

      assert Repo.get_by(Delivery,
               insight_id: insight.id,
               user_id: user_id,
               channel: "telegram"
             ) == nil

      {:ok, pending} =
        %Delivery{}
        |> Delivery.changeset(%{
          insight_id: insight.id,
          user_id: user_id,
          channel: "telegram",
          destination: "12345",
          score: 0.94,
          threshold: 0.78,
          status: "pending"
        })
        |> Repo.insert()

      assert InsightNotifications.dispatch_telegram_batch(batch_size: 10) == %{
               staged: 0,
               sent: 0,
               failed: 0
             }

      reloaded = Repo.get!(Delivery, pending.id)
      assert reloaded.status == "pending"
      assert reloaded.error_message == nil
      assert reloaded.sent_at == nil
      assert reloaded.updated_at == pending.updated_at
      assert Repo.aggregate(Delivery, :count, :id) == 1
    end

    test "fallback delivery failures store product-safe copy", %{
      user_id: user_id,
      insight: insight
    } do
      use_failing_delivery(
        {:telegram_error, 500, "RuntimeError token=secret stacktrace %{chat_id: 12345}"},
        telegram_full_chat_enabled: false,
        telegram_unified_push_enabled: nil,
        proactive_delivery_planner_enabled: false
      )

      result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
      assert result.failed == 1

      delivery =
        Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

      assert delivery.status == "failed"

      assert delivery.error_message ==
               "Telegram is temporarily unavailable. Wait a minute before sending another delivery."

      refute String.contains?(String.downcase(delivery.error_message), "try again")
      refute delivery.error_message =~ "token"
      refute delivery.error_message =~ "stacktrace"
      refute delivery.error_message =~ "chat_id"
    end

    test "unified push delivery failures store product-safe copy", %{
      user_id: user_id,
      insight: insight
    } do
      use_failing_delivery(
        {:telegram_error, 403, "Forbidden: bot was blocked by the user token=secret"},
        telegram_full_chat_enabled: true,
        telegram_unified_push_enabled: true,
        proactive_delivery_planner_enabled: false
      )

      result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
      assert result.failed == 1

      delivery =
        Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

      assert delivery.status == "failed"
      assert delivery.error_message == DeliveryErrorCopy.storage_message(:no_push_device)
      # Deliberately retryable: the delivery becomes sendable the moment a
      # device registers.
      refute DeliveryErrorCopy.terminal?(delivery.error_message)
      refute delivery.error_message =~ "token"
      refute delivery.error_message =~ "Forbidden"
    end
  end

  describe "handle_telegram_event/1" do
    test "links telegram chat from start command" do
      user_id = "link-user@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      event = %{
        type: "message",
        data: %{
          chat_id: 998_877,
          text: "/start #{user_id}",
          from: %{id: 1001, username: "linker"}
        }
      }

      :ok = InsightNotifications.handle_telegram_event(event)

      account = ConnectedAccounts.get(user_id, "telegram")
      assert account.status == "connected"
      assert account.external_account_id == "998877"
    end

    test "links telegram chat from start command with bot mention" do
      user_id = "link-bot-mention@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      event = %{
        type: "message",
        data: %{
          chat_id: 445_566,
          text: "/start@maraithon_bot #{user_id}",
          from: %{id: 1002, username: "linker2"}
        }
      }

      :ok = InsightNotifications.handle_telegram_event(event)

      account = ConnectedAccounts.get(user_id, "telegram")
      assert account.status == "connected"
      assert account.external_account_id == "445566"
    end

    test "links telegram chat from signed start token" do
      user_id = "link-token@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      token = TelegramLink.sign_token(user_id)

      event = %{
        type: "message",
        data: %{
          chat_id: 223_344,
          text: "/start #{token}",
          from: %{id: 1003, username: "linker3"}
        }
      }

      :ok = InsightNotifications.handle_telegram_event(event)

      account = ConnectedAccounts.get(user_id, "telegram")
      assert account.status == "connected"
      assert account.external_account_id == "223344"
    end

    test "durable message dispatch waits behind earlier work in the same chat" do
      Application.put_env(:maraithon, ChatWorker, async_enabled: true)
      chat_id = "durable-insight-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        case Registry.lookup(Maraithon.TelegramAssistant.ChatRegistry, chat_id) do
          [{pid, _value}] -> GenServer.stop(pid, :normal)
          [] -> :ok
        end
      end)

      ordinary = %{
        type: "message",
        data: %{chat_id: chat_id, message_id: "first", text: "unlinked first"}
      }

      durable = %{
        type: "message",
        data: %{chat_id: chat_id, message_id: "second", text: "unlinked second"}
      }

      assert :ok = InsightNotifications.handle_telegram_event(ordinary)
      assert :ok = InsightNotifications.handle_telegram_event(durable, durable: true)

      [{pid, _value}] = Registry.lookup(Maraithon.TelegramAssistant.ChatRegistry, chat_id)
      state = :sys.get_state(pid)
      assert MapSet.subset?(MapSet.new(["first", "second"]), state.seen_set)
    end

    test "records callback feedback and tunes threshold", %{user_id: user_id, insight: insight} do
      _ = InsightNotifications.dispatch_telegram_batch(batch_size: 10)

      delivery =
        Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

      {:ok, profile_before} = InsightNotifications.get_or_create_profile(user_id)

      :ok =
        InsightNotifications.handle_telegram_event(%{
          type: "callback_query",
          data: %{
            callback_id: "cb_1",
            chat_id: 12345,
            data: "insfb:#{delivery.id}:n"
          }
        })

      updated_delivery = Repo.get!(Delivery, delivery.id)
      updated_profile = Repo.get_by!(ThresholdProfile, user_id: user_id)
      dismissed = Repo.get!(Maraithon.Insights.Insight, insight.id)

      assert updated_delivery.feedback == "not_helpful"
      assert updated_delivery.status == "feedback_not_helpful"
      assert updated_profile.score_threshold > profile_before.score_threshold
      assert dismissed.status == "dismissed"
    end

    test "uses ai-derived telegram fit score when deciding whether to send", %{
      user_id: user_id,
      insight: insight
    } do
      insight
      |> Ecto.Changeset.change(metadata: %{"telegram_fit_score" => 0.41})
      |> Repo.update!()

      result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)

      assert result.staged == 0
      assert result.sent == 0

      assert Repo.get_by(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram") ==
               nil
    end
  end

  defp use_failing_delivery(reason, assistant_opts) do
    assistant_config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(:maraithon, :insights,
      telegram_module: Maraithon.TestSupport.FailingTelegram
    )

    Application.put_env(:maraithon, :failing_telegram, reason: reason)

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(assistant_config, assistant_opts)
    )
  end
end
