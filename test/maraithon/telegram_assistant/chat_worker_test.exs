defmodule Maraithon.TelegramAssistant.ChatWorkerTest do
  # async: false — these tests flip the global async_enabled config.
  use ExUnit.Case, async: false

  alias Maraithon.TelegramAssistant.ChatWorker

  @registry Maraithon.TelegramAssistant.ChatRegistry

  setup do
    original = Application.get_env(:maraithon, ChatWorker, [])
    Application.put_env(:maraithon, ChatWorker, async_enabled: true)

    on_exit(fn -> Application.put_env(:maraithon, ChatWorker, original) end)
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
end
