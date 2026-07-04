defmodule Maraithon.TelegramAssistant.ChatWorkerTest.RecordingTelegram do
  @moduledoc false
  # Records Telegram calls to the test process registered under the
  # :chat_worker_test_pid app env key (the worker runs in its own process).

  def configured?, do: true

  def send_message(chat_id, text, opts \\ []) do
    notify({:telegram_send, chat_id, text, opts})
    {:ok, %{"message_id" => System.unique_integer([:positive])}}
  end

  def send_chat_action(chat_id, action) do
    notify({:telegram_chat_action, chat_id, to_string(action)})
    {:ok, true}
  end

  def edit_message_text(chat_id, message_id, text, _opts \\ []) do
    notify({:telegram_edit, chat_id, message_id, text})
    {:ok, true}
  end

  def answer_callback_query(_callback_query_id, _opts \\ []), do: {:ok, true}

  defp notify(message) do
    case Application.get_env(:maraithon, :chat_worker_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end

    :ok
  end
end

defmodule Maraithon.TelegramAssistant.ChatWorkerTest do
  # async: false — these tests flip the global async_enabled config.
  use ExUnit.Case, async: false

  alias Maraithon.TelegramAssistant.ChatWorker
  alias Maraithon.TelegramAssistant.ChatWorkerTest.RecordingTelegram

  @registry Maraithon.TelegramAssistant.ChatRegistry

  setup do
    original = Application.get_env(:maraithon, ChatWorker, [])
    original_insights = Application.get_env(:maraithon, :insights, [])
    original_test_pid = Application.get_env(:maraithon, :chat_worker_test_pid)

    Application.put_env(:maraithon, ChatWorker, async_enabled: true)

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights, telegram_module: RecordingTelegram)
    )

    on_exit(fn ->
      Application.put_env(:maraithon, ChatWorker, original)
      Application.put_env(:maraithon, :insights, original_insights)

      if original_test_pid do
        Application.put_env(:maraithon, :chat_worker_test_pid, original_test_pid)
      else
        Application.delete_env(:maraithon, :chat_worker_test_pid)
      end
    end)

    :ok
  end

  # A message with no "text" makes TelegramRouter.handle_message return early
  # (before any DB access), so the worker can process a cast without needing
  # an Ecto sandbox allowance.
  defp inert_message(chat_id, message_id) do
    %{"chat_id" => chat_id, "message_id" => message_id}
  end

  defp stop_worker(chat_id) do
    case Registry.lookup(@registry, chat_id) do
      [{pid, _}] -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  defp await_worker_drained(chat_id) do
    [{pid, _}] = Registry.lookup(@registry, chat_id)
    # get_state is a synchronous call, so it returns only after every prior
    # cast has been handled.
    :sys.get_state(pid)
  end

  test "enqueue starts one worker per chat, reuses it, and isolates chats" do
    chat_a = "chatworker-a-#{System.unique_integer([:positive])}"
    chat_b = "chatworker-b-#{System.unique_integer([:positive])}"
    on_exit(fn -> Enum.each([chat_a, chat_b], &stop_worker/1) end)

    assert :ok = ChatWorker.enqueue(chat_a, inert_message(chat_a, "1"))
    assert :ok = ChatWorker.enqueue(chat_a, inert_message(chat_a, "2"))
    assert :ok = ChatWorker.enqueue(chat_b, inert_message(chat_b, "1"))

    # Let the casts drain.
    Process.sleep(50)

    assert [{pid_a, _}] = Registry.lookup(@registry, chat_a)
    assert [{pid_b, _}] = Registry.lookup(@registry, chat_b)

    assert Process.alive?(pid_a)
    assert Process.alive?(pid_b)
    # Same chat reuses one worker; different chats get different workers.
    assert pid_a != pid_b
  end

  test "worker records message ids and drops duplicate deliveries" do
    chat = "chatworker-dedupe-#{System.unique_integer([:positive])}"
    on_exit(fn -> stop_worker(chat) end)

    ChatWorker.enqueue(chat, inert_message(chat, "msg-1"))
    Process.sleep(50)

    [{pid, _}] = Registry.lookup(@registry, chat)
    assert MapSet.member?(:sys.get_state(pid).seen_set, "msg-1")

    # A duplicate (Telegram retried) is a no-op — seen set stays size 1.
    ChatWorker.enqueue(chat, inert_message(chat, "msg-1"))
    Process.sleep(50)
    assert MapSet.size(:sys.get_state(pid).seen_set) == 1
  end

  test "enqueue runs the router synchronously when async is disabled" do
    Application.put_env(:maraithon, ChatWorker, async_enabled: false)
    chat = "chatworker-sync-#{System.unique_integer([:positive])}"

    # No worker is started — the router runs inline and returns :ok.
    assert :ok = ChatWorker.enqueue(chat, inert_message(chat, "1"))
    assert Registry.lookup(@registry, chat) == []
  end

  # SPEC 09 R0: a genuinely new message fires a typing ping at pickup — as
  # the very first Telegram call, strictly before routing/context work (the
  # router never sends anything for this inert message, so the ping is the
  # only event and demonstrably precedes any router activity).
  test "fires a typing ping the moment a genuinely new message is picked up" do
    Application.put_env(:maraithon, :chat_worker_test_pid, self())
    chat = "chatworker-ping-#{System.unique_integer([:positive])}"
    on_exit(fn -> stop_worker(chat) end)

    assert :ok = ChatWorker.enqueue(chat, inert_message(chat, "msg-ping-1"))

    assert_receive {:telegram_chat_action, ^chat, "typing"}, 1_000
    await_worker_drained(chat)
    # The ping is the first (and only) Telegram call for this message.
    refute_received {:telegram_send, _chat, _text, _opts}
  end

  test "does not fire a typing ping for a duplicate webhook delivery" do
    Application.put_env(:maraithon, :chat_worker_test_pid, self())
    chat = "chatworker-ping-dupe-#{System.unique_integer([:positive])}"
    on_exit(fn -> stop_worker(chat) end)

    ChatWorker.enqueue(chat, inert_message(chat, "msg-dupe-1"))
    assert_receive {:telegram_chat_action, ^chat, "typing"}, 1_000
    await_worker_drained(chat)

    # Telegram retried an already-handled message id — no second ping.
    ChatWorker.enqueue(chat, inert_message(chat, "msg-dupe-1"))
    await_worker_drained(chat)
    refute_received {:telegram_chat_action, ^chat, "typing"}
  end
end

defmodule Maraithon.TelegramAssistant.ChatWorkerCompletedRetryTest do
  # DataCase (shared sandbox) so the worker process can run the persisted
  # already_completed?/2 check against a real recorded assistant reply.
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.TelegramAssistant.ChatWorker
  alias Maraithon.TelegramAssistant.ChatWorkerTest.RecordingTelegram
  alias Maraithon.TelegramConversations

  @registry Maraithon.TelegramAssistant.ChatRegistry

  setup do
    original = Application.get_env(:maraithon, ChatWorker, [])
    original_insights = Application.get_env(:maraithon, :insights, [])

    Application.put_env(:maraithon, ChatWorker, async_enabled: true)

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights, telegram_module: RecordingTelegram)
    )

    Application.put_env(:maraithon, :chat_worker_test_pid, self())

    on_exit(fn ->
      Application.put_env(:maraithon, ChatWorker, original)
      Application.put_env(:maraithon, :insights, original_insights)
      Application.delete_env(:maraithon, :chat_worker_test_pid)
    end)

    :ok
  end

  defp stop_worker(chat_id) do
    case Registry.lookup(@registry, chat_id) do
      [{pid, _}] -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  # SPEC 09 R0 acceptance: a webhook retry for an already-completed message
  # short-circuits on already_completed?/2 and never fires the typing ping.
  test "never fires a typing ping for a message that already got a completed reply" do
    user_id = "chatworker-completed-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    chat = "chatworker-completed-#{System.unique_integer([:positive])}"
    message_id = "msg-completed-1"
    on_exit(fn -> stop_worker(chat) end)

    {:ok, conversation} = TelegramConversations.start_or_continue(user_id, chat, %{})

    {:ok, {_conversation, _turn}} =
      TelegramConversations.append_turn(conversation, %{
        "role" => "assistant",
        "reply_to_message_id" => message_id,
        "text" => "Already answered."
      })

    assert TelegramConversations.assistant_reply_recorded?(chat, message_id)

    ChatWorker.enqueue(chat, %{"chat_id" => chat, "message_id" => message_id})

    [{pid, _}] = Registry.lookup(@registry, chat)
    state = :sys.get_state(pid)

    # The retry was remembered without reprocessing — and no typing ping.
    assert MapSet.member?(state.seen_set, message_id)
    refute_received {:telegram_chat_action, ^chat, "typing"}
  end
end
