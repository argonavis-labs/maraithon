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

  defp receipts(user_id) do
    Repo.all(from r in PushReceipt, where: r.user_id == ^user_id)
  end

  # ---------------------------------------------------------------------------
  # Mobile push cutover
  # ---------------------------------------------------------------------------

  defmodule RecordingAPNSHTTP do
    def post(url, _headers, body) do
      config = Application.fetch_env!(:maraithon, :apns)
      recipient = Keyword.fetch!(config, :test_pid)
      payload = Jason.decode!(body)

      response = Keyword.get(config, :test_response, {:ok, 200, ""})

      if Keyword.get(config, :block_test_request, false) do
        send(recipient, {:apns_started, self(), url, payload})

        receive do
          :release_apns -> response
        end
      else
        send(recipient, {:apns_send, url, payload})
        response
      end
    end
  end

  defp enable_apns(opts \\ []) do
    previous = Application.get_env(:maraithon, :apns, [])

    ec_key = :public_key.generate_key({:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec_key)])

    Application.put_env(:maraithon, :apns,
      team_id: "TEAM123456",
      key_id: "KEY1234567",
      private_key: pem,
      http_module: RecordingAPNSHTTP,
      test_pid: self(),
      block_test_request: Keyword.get(opts, :block_test_request, false),
      test_response: Keyword.get(opts, :test_response, {:ok, 200, ""})
    )

    Maraithon.Push.APNS.reset_jwt_cache()

    on_exit(fn ->
      Maraithon.Push.APNS.reset_jwt_cache()
      Application.put_env(:maraithon, :apns, previous)
    end)
  end

  test "registration retains at most five active devices", %{user_id: user_id} do
    for index <- 1..7 do
      token = String.pad_leading(Integer.to_string(index, 16), 64, "0")
      assert {:ok, _device} = Maraithon.Push.Devices.register(user_id, %{device_token: token})
    end

    assert length(Maraithon.Push.Devices.active_for_user(user_id)) == 5

    active_count =
      Repo.aggregate(
        from(device in Maraithon.Push.Device,
          where: device.user_id == ^user_id and device.status == "active"
        ),
        :count
      )

    assert active_count == 5
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

  test "an old hold receives a fresh delivery lease when APNS starts", %{
    user_id: user_id,
    chat_id: chat_id
  } do
    enable_apns(block_test_request: true)

    {:ok, _} =
      Maraithon.Push.Devices.register(user_id, %{device_token: String.duplicate("f", 64)})

    attrs = candidate(user_id, chat_id, "Body.")

    assert {:ok, held} =
             Maraithon.TelegramAssistant.record_push_receipt(%{
               user_id: user_id,
               dedupe_key: attrs.dedupe_key,
               origin_type: attrs.origin_type,
               origin_id: attrs.origin_id,
               decision: "held_rate_limit"
             })

    old_timestamp = DateTime.utc_now() |> DateTime.add(-60 * 60, :second)
    held |> Ecto.Changeset.change(inserted_at: old_timestamp) |> Repo.update!()

    owner = self()

    first =
      Task.async(fn ->
        receive do
          :go -> PushBroker.deliver(attrs)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, first.pid)
    send(first.pid, :go)

    assert_receive {:apns_started, request_pid, _url, _payload}

    assert %PushReceipt{decision: "sending", inserted_at: sending_at} =
             Repo.get_by!(PushReceipt, user_id: user_id, dedupe_key: attrs.dedupe_key)

    assert DateTime.compare(sending_at, old_timestamp) == :gt
    assert {:error, :delivery_in_progress} = PushBroker.deliver(attrs)
    refute_received {:apns_started, _other_pid, _url, _payload}

    send(request_pid, :release_apns)
    assert {:ok, %{decision: "sent_now"}} = Task.await(first)
  end

  test "an in-flight reservation counts against the budget without proving delivery", %{
    user_id: user_id,
    chat_id: chat_id
  } do
    enable_apns(block_test_request: true)

    {:ok, _} =
      Maraithon.Push.Devices.register(user_id, %{device_token: String.duplicate("e", 64)})

    attrs = candidate(user_id, chat_id, "Body.")
    owner = self()

    first =
      Task.async(fn ->
        receive do
          :go -> PushBroker.deliver(attrs)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, first.pid)
    send(first.pid, :go)

    assert_receive {:apns_started, request_pid, _url, _payload}

    assert %PushReceipt{decision: "sending"} =
             Maraithon.TelegramAssistant.push_receipt_for(user_id, attrs.dedupe_key)

    assert {:error, :delivery_in_progress} = PushBroker.deliver(attrs)

    send(request_pid, :release_apns)
    assert {:ok, %{decision: "sent_now"}} = Task.await(first)

    assert %PushReceipt{decision: "sent_now"} =
             Maraithon.TelegramAssistant.push_receipt_for(user_id, attrs.dedupe_key)
  end

  test "a definitive APNS rejection releases the receipt for a safe retry", %{
    user_id: user_id,
    chat_id: chat_id
  } do
    enable_apns(test_response: {:ok, 429, ~s({"reason":"TooManyRequests"})})

    {:ok, _} =
      Maraithon.Push.Devices.register(user_id, %{device_token: String.duplicate("8", 64)})

    attrs = candidate(user_id, chat_id, "Body.")
    assert {:error, :undelivered} = PushBroker.deliver(attrs)
    assert receipts(user_id) == []

    assert {:error, :undelivered} = PushBroker.deliver(attrs)
    assert_received {:apns_send, _url, _payload}
    assert_received {:apns_send, _url, _payload}
  end

  test "ambiguous APNS transport loss blocks duplicate delivery", %{
    user_id: user_id,
    chat_id: chat_id
  } do
    enable_apns(test_response: {:error, :closed})

    {:ok, _} =
      Maraithon.Push.Devices.register(user_id, %{device_token: String.duplicate("7", 64)})

    attrs = candidate(user_id, chat_id, "Body.")
    assert {:error, :delivery_unknown} = PushBroker.deliver(attrs)

    assert %PushReceipt{decision: "delivery_unknown"} =
             Maraithon.TelegramAssistant.push_receipt_for(user_id, attrs.dedupe_key)

    # The APNS client made exactly one external attempt.
    assert_received {:apns_send, _url, _payload}
    refute_received {:apns_send, _url, _payload}

    assert {:error, :delivery_unknown} = PushBroker.deliver(attrs)

    refute_received {:apns_send, _url, _payload}
  end

  test "APNS success remains blocked when receipt finalization loses its CAS", %{
    user_id: user_id,
    chat_id: chat_id
  } do
    enable_apns(block_test_request: true)

    {:ok, _} =
      Maraithon.Push.Devices.register(user_id, %{device_token: String.duplicate("6", 64)})

    attrs = candidate(user_id, chat_id, "Body.")
    owner = self()

    delivery =
      Task.async(fn ->
        receive do
          :go -> PushBroker.deliver(attrs)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, delivery.pid)
    send(delivery.pid, :go)

    assert_receive {:apns_started, request_pid, _url, _payload}

    sending = Repo.get_by!(PushReceipt, user_id: user_id, dedupe_key: attrs.dedupe_key)
    assert sending.decision == "sending"

    # Simulate conservative recovery winning the state transition before the
    # successful APNS response can be finalized. The sent transition must lose
    # its CAS without releasing the durable at-most-once proof.
    sending
    |> Ecto.Changeset.change(decision: "delivery_unknown")
    |> Repo.update!()

    send(request_pid, :release_apns)
    assert {:error, :reservation_lost} = Task.await(delivery)

    assert %PushReceipt{decision: "delivery_unknown"} =
             Maraithon.TelegramAssistant.push_receipt_for(user_id, attrs.dedupe_key)

    assert {:error, :delivery_unknown} = PushBroker.deliver(attrs)

    refute_received {:apns_started, _request_pid, _url, _payload}
  end

  test "an abandoned post-transport lease becomes a blocking unknown delivery", %{
    user_id: user_id,
    chat_id: chat_id
  } do
    enable_apns()

    {:ok, _} =
      Maraithon.Push.Devices.register(user_id, %{device_token: String.duplicate("9", 64)})

    attrs = candidate(user_id, chat_id, "Body.")

    assert {:ok, sending} =
             Maraithon.TelegramAssistant.record_push_receipt(%{
               user_id: user_id,
               dedupe_key: attrs.dedupe_key,
               origin_type: attrs.origin_type,
               origin_id: attrs.origin_id,
               decision: "sending"
             })

    stale_at = DateTime.utc_now() |> DateTime.add(-16 * 60, :second)
    sending |> Ecto.Changeset.change(inserted_at: stale_at) |> Repo.update!()

    assert {:error, :delivery_unknown} = PushBroker.deliver(attrs)

    refute_received {:apns_send, _url, _payload}

    assert %PushReceipt{decision: "delivery_unknown"} =
             Maraithon.TelegramAssistant.push_receipt_for(user_id, attrs.dedupe_key)
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
