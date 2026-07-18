defmodule Maraithon.TelegramAssistant.PushBrokerTest.RecordingTelegram do
  @moduledoc false
  # PushBroker.deliver/1 runs synchronously in the calling (test) process, so
  # this double can use the process dictionary for send counting/failure
  # injection and message the test's own mailbox directly.

  def configured?, do: true

  def send_message(chat_id, text, opts \\ []) do
    count = Process.get(:push_broker_send_count, 0) + 1
    Process.put(:push_broker_send_count, count)

    if Process.get(:push_broker_fail_on_send) == count do
      {:error, :telegram_down}
    else
      send(self(), {:telegram_send, count, chat_id, text, opts})
      {:ok, %{"message_id" => 1000 + count}}
    end
  end

  def send_chat_action(_chat_id, _action), do: {:ok, true}
  def edit_message_text(_chat_id, _message_id, _text, _opts \\ []), do: {:ok, true}
  def answer_callback_query(_callback_query_id, _opts \\ []), do: {:ok, true}
end

defmodule Maraithon.TelegramAssistant.PushBrokerTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.TelegramAssistant.PushBroker
  alias Maraithon.TelegramAssistant.PushBrokerTest.RecordingTelegram
  alias Maraithon.TelegramAssistant.PushReceipt
  alias Maraithon.TelegramConversations.{Conversation, Turn}

  setup do
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])
    original_insights = Application.get_env(:maraithon, :insights, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_full_chat_enabled: true,
        telegram_unified_push_enabled: true
      )
    )

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights, telegram_module: RecordingTelegram)
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
      Application.put_env(:maraithon, :insights, original_insights)
    end)

    user_id = "push-broker-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    %{user_id: user_id, chat_id: "push-chat-#{System.unique_integer([:positive])}"}
  end

  defp candidate(user_id, chat_id, body, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: user_id,
        chat_id: chat_id,
        origin_type: "brief",
        origin_id: Ecto.UUID.generate(),
        dedupe_key: "push-broker-test:#{System.unique_integer([:positive])}",
        title: "Morning brief",
        body: body,
        # High urgency so the interruption budget/quiet hours gate never
        # holds these focused sends.
        urgency: 0.95,
        interrupt_now: true,
        why_now: "test",
        telegram_opts: [
          parse_mode: "HTML",
          reply_markup: %{"inline_keyboard" => [[%{"text" => "Open", "callback_data" => "x"}]]}
        ]
      },
      overrides
    )
  end

  defp long_body do
    paragraph = String.duplicate("Look ahead line with substance. ", 60) |> String.trim()

    ["<b>Morning brief</b>", paragraph, paragraph, "Today's move: ship the thing."]
    |> Enum.join("\n\n")
  end

  defp receipts(user_id) do
    Repo.all(from r in PushReceipt, where: r.user_id == ^user_id)
  end

  defp turns_for(user_id) do
    Repo.all(
      from t in Turn,
        join: c in Conversation,
        on: t.conversation_id == c.id,
        where: c.user_id == ^user_id,
        order_by: [asc: t.inserted_at]
    )
  end

  # ---------------------------------------------------------------------------
  # Mobile push cutover
  # ---------------------------------------------------------------------------

  defmodule RecordingAPNSHTTP do
    def post(url, _headers, body) do
      send(self(), {:apns_send, url, Jason.decode!(body)})
      {:ok, 200, ""}
    end
  end

  defp enable_apns do
    previous = Application.get_env(:maraithon, :apns, [])

    ec_key = :public_key.generate_key({:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec_key)])

    Application.put_env(:maraithon, :apns,
      team_id: "TEAM123456",
      key_id: "KEY1234567",
      private_key: pem,
      http_module: RecordingAPNSHTTP
    )

    Maraithon.Push.APNS.reset_jwt_cache()

    on_exit(fn ->
      Maraithon.Push.APNS.reset_jwt_cache()
      Application.put_env(:maraithon, :apns, previous)
    end)
  end

  test "a user with a registered device gets APNs instead of Telegram",
       %{user_id: user_id, chat_id: chat_id} do
    enable_apns()

    {:ok, _} =
      Maraithon.Push.Devices.register(user_id, %{device_token: String.duplicate("a", 64)})

    assert {:ok, %{decision: "sent_now"}} =
             PushBroker.deliver(candidate(user_id, chat_id, "<b>Morning brief</b>\n\nBody."))

    assert_received {:apns_send, _url, payload}
    refute_received {:telegram_send, _count, _chat, _text, _opts}

    # A brief's push carries the summary (why_now), not the full rendered
    # text, and deep-links to the Today tab where the app renders it.
    assert payload["aps"]["alert"]["body"] == "test"
    refute payload["aps"]["alert"]["body"] =~ "<b>"
    assert payload["deeplink"] == "maraithon://today"

    # The same receipt machinery records the send.
    assert [receipt] = receipts(user_id)
    assert receipt.decision == "sent_now"
  end

  test "a push-user candidate with no Telegram chat id still delivers", %{user_id: user_id} do
    enable_apns()

    {:ok, _} =
      Maraithon.Push.Devices.register(user_id, %{device_token: String.duplicate("b", 64)})

    assert {:ok, %{decision: "sent_now"}} =
             PushBroker.deliver(
               candidate(user_id, nil, "Insight body", %{origin_type: "insight"})
             )

    assert_received {:apns_send, _url, payload}
    # Non-brief origins keep their (short) body as the push body.
    assert payload["aps"]["alert"]["body"] == "Insight body"
    assert payload["deeplink"] == "maraithon://stream"
  end

  test "the kill switch turns delivery off entirely (no Telegram to fall back to)",
       %{user_id: user_id, chat_id: chat_id} do
    enable_apns()

    {:ok, _} =
      Maraithon.Push.Devices.register(user_id, %{device_token: String.duplicate("c", 64)})

    previous = Application.get_env(:maraithon, :mobile_push, [])
    Application.put_env(:maraithon, :mobile_push, enabled: false)
    on_exit(fn -> Application.put_env(:maraithon, :mobile_push, previous) end)

    assert {:error, :no_push_device} =
             PushBroker.deliver(candidate(user_id, chat_id, "Body."))

    refute_received {:apns_send, _url, _payload}
    refute_received {:telegram_send, _count, _chat, _text, _opts}
  end

  test "a user with no device gets a clean no-device error and no receipt",
       %{user_id: user_id, chat_id: chat_id} do
    enable_apns()

    assert {:error, :no_push_device} =
             PushBroker.deliver(candidate(user_id, chat_id, "Body."))

    refute_received {:apns_send, _url, _payload}
    refute_received {:telegram_send, _count, _chat, _text, _opts}
    assert receipts(user_id) == []
  end

  test "a redelivered push candidate is suppressed as a duplicate", %{
    user_id: user_id,
    chat_id: chat_id
  } do
    enable_apns()

    {:ok, _} =
      Maraithon.Push.Devices.register(user_id, %{device_token: String.duplicate("d", 64)})

    attrs = candidate(user_id, chat_id, "Body.")
    assert {:ok, %{decision: "sent_now"}} = PushBroker.deliver(attrs)
    assert {:ok, %{decision: "suppressed", reason: "duplicate"}} = PushBroker.deliver(attrs)

    assert_received {:apns_send, _url, _payload}
    refute_received {:apns_send, _url2, _payload2}
    assert length(receipts(user_id)) == 1
  end
end
