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

defmodule Maraithon.TelegramAssistant.ChatWorkerTest.IncompleteCompletion do
  @moduledoc false
  def assistant_reply_recorded?(_chat_id, _message_id), do: false
end

defmodule Maraithon.TelegramAssistant.ChatWorkerTest.FailingCompletion do
  @moduledoc false
  def assistant_reply_recorded?(_chat_id, _message_id), do: exit(:completion_store_unavailable)
end

defmodule Maraithon.TelegramAssistant.ChatWorkerTest.CrashingRouter do
  @moduledoc false
  def handle_message(_data), do: raise("router exploded with token=never-log-or-complete")
end

defmodule Maraithon.TelegramAssistant.ChatWorkerTest.OwnedLivenessBlockingRouter do
  @moduledoc false

  alias Maraithon.TelegramAssistant.LivenessSupervisor

  def handle_message(data) do
    observer = Application.fetch_env!(:maraithon, :chat_worker_test_pid)
    run_id = Map.fetch!(data, "run_id")

    {:ok, session} =
      LivenessSupervisor.start_session(%{
        run_id: run_id,
        user_id: "liveness-owner-test",
        chat_id: Map.fetch!(data, "chat_id"),
        source_text: "blocking liveness owner test",
        owner_pid: self()
      })

    send(observer, {:owned_liveness_started, self(), session, run_id})

    receive do
      :release_owned_liveness_router -> :ok
    after
      10_000 -> {:error, :owned_liveness_router_timeout}
    end
  end
end

defmodule Maraithon.TelegramAssistant.ChatWorkerTest.BlockingRouter do
  @moduledoc false

  def handle_message(data) do
    observer = Application.fetch_env!(:maraithon, :chat_worker_test_pid)
    execution_id = Map.get(data, "execution_id", Map.get(data, :execution_id))
    send(observer, {:blocking_router_started, self(), execution_id})

    receive do
      {:release_blocking_router, result} -> result
    after
      10_000 -> {:error, :blocking_router_test_timeout}
    end
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

    Application.put_env(:maraithon, ChatWorker,
      async_enabled: true,
      completion_checker: Maraithon.TelegramAssistant.ChatWorkerTest.IncompleteCompletion
    )

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

    _ = await_worker_drained(chat_a)
    _ = await_worker_drained(chat_b)

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
    _ = await_worker_drained(chat)

    [{pid, _}] = Registry.lookup(@registry, chat)
    assert MapSet.member?(:sys.get_state(pid).seen_set, "msg-1")

    # A duplicate (Telegram retried) is a no-op — seen set stays size 1.
    ChatWorker.enqueue(chat, inert_message(chat, "msg-1"))
    _ = await_worker_drained(chat)
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

  test "durable completion-store failure fails closed before routing" do
    Application.put_env(:maraithon, :chat_worker_test_pid, self())

    Application.put_env(:maraithon, ChatWorker,
      async_enabled: true,
      completion_checker: Maraithon.TelegramAssistant.ChatWorkerTest.FailingCompletion,
      router_module: Maraithon.TelegramAssistant.ChatWorkerTest.BlockingRouter
    )

    chat = "chatworker-completion-failure-#{System.unique_integer([:positive])}"

    assert {:error, :retry_completion_check_failed} =
             ChatWorker.process_durable(chat, %{
               "chat_id" => chat,
               "message_id" => "completion-check"
             })

    refute_received {:blocking_router_started, _work, _execution_id}
    refute_received {:telegram_send, _chat, _text, _opts}
  end

  test "durable router crashes remain retryable and do not send a tombstoning fallback" do
    Application.put_env(:maraithon, :chat_worker_test_pid, self())

    Application.put_env(:maraithon, ChatWorker,
      async_enabled: true,
      completion_checker: Maraithon.TelegramAssistant.ChatWorkerTest.IncompleteCompletion,
      router_module: Maraithon.TelegramAssistant.ChatWorkerTest.CrashingRouter
    )

    chat = "chatworker-router-failure-#{System.unique_integer([:positive])}"

    assert {:error, :durable_telegram_router_failed} =
             ChatWorker.process_durable(chat, %{
               "chat_id" => chat,
               "message_id" => "router-crash"
             })

    refute_received {:telegram_send, _chat, _text, _opts}
  end

  test "legacy async routing keeps the user-visible crash fallback" do
    Application.put_env(:maraithon, :chat_worker_test_pid, self())

    Application.put_env(:maraithon, ChatWorker,
      async_enabled: true,
      completion_checker: Maraithon.TelegramAssistant.ChatWorkerTest.IncompleteCompletion,
      router_module: Maraithon.TelegramAssistant.ChatWorkerTest.CrashingRouter
    )

    chat = "chatworker-legacy-fallback-#{System.unique_integer([:positive])}"
    on_exit(fn -> stop_worker(chat) end)

    assert :ok =
             ChatWorker.enqueue(chat, %{"chat_id" => chat, "message_id" => "legacy-crash"})

    _ = await_worker_drained(chat)
    assert_received {:telegram_send, ^chat, _text, _opts}
  end

  test "durable timeout kills owned work before returning and retry starts once" do
    Application.put_env(:maraithon, :chat_worker_test_pid, self())

    Application.put_env(:maraithon, ChatWorker,
      async_enabled: true,
      completion_checker: Maraithon.TelegramAssistant.ChatWorkerTest.IncompleteCompletion,
      router_module: Maraithon.TelegramAssistant.ChatWorkerTest.BlockingRouter,
      durable_timeout_ms: 25
    )

    chat = "chatworker-durable-#{System.unique_integer([:positive])}"

    first =
      Task.async(fn ->
        ChatWorker.process_durable(chat, %{
          "chat_id" => chat,
          "message_id" => "first",
          "execution_id" => "first"
        })
      end)

    assert_receive {:blocking_router_started, first_work, "first"}, 1_000
    first_ref = Process.monitor(first_work)
    assert_receive {:DOWN, ^first_ref, :process, ^first_work, :killed}, 1_000
    assert Task.await(first) == {:error, :durable_processing_timeout}
    assert Registry.lookup(@registry, chat) == []

    second =
      Task.async(fn ->
        ChatWorker.process_durable(chat, %{
          "chat_id" => chat,
          "message_id" => "second",
          "execution_id" => "second"
        })
      end)

    assert_receive {:blocking_router_started, second_work, "second"}, 1_000
    refute second_work == first_work
    send(second_work, {:release_blocking_router, :ok})
    assert Task.await(second) == :ok
    refute_receive {:blocking_router_started, _extra_work, _execution_id}, 50
  end

  test "durable timeout tears down the independently supervised liveness session" do
    Application.put_env(:maraithon, :chat_worker_test_pid, self())

    Application.put_env(:maraithon, ChatWorker,
      async_enabled: true,
      completion_checker: Maraithon.TelegramAssistant.ChatWorkerTest.IncompleteCompletion,
      router_module: Maraithon.TelegramAssistant.ChatWorkerTest.OwnedLivenessBlockingRouter,
      durable_timeout_ms: 25
    )

    chat = "chatworker-liveness-owner-#{System.unique_integer([:positive])}"
    run_id = Ecto.UUID.generate()

    durable =
      Task.async(fn ->
        ChatWorker.process_durable(chat, %{
          "chat_id" => chat,
          "message_id" => "liveness-timeout",
          "run_id" => run_id
        })
      end)

    assert_receive {:owned_liveness_started, work, session, ^run_id}, 1_000
    work_ref = Process.monitor(work)
    session_ref = Process.monitor(session)

    assert_receive {:DOWN, ^work_ref, :process, ^work, :killed}, 1_000
    assert Task.await(durable) == {:error, :durable_processing_timeout}
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 1_000
    _ = :sys.get_state(Maraithon.TelegramAssistant.LivenessRegistry)

    assert Registry.lookup(Maraithon.TelegramAssistant.LivenessRegistry, run_id) == []
  end

  test "legacy enqueue remains immediate and serializes work in the resident worker" do
    Application.put_env(:maraithon, :chat_worker_test_pid, self())

    Application.put_env(:maraithon, ChatWorker,
      async_enabled: true,
      completion_checker: Maraithon.TelegramAssistant.ChatWorkerTest.IncompleteCompletion,
      router_module: Maraithon.TelegramAssistant.ChatWorkerTest.BlockingRouter
    )

    chat = "chatworker-legacy-#{System.unique_integer([:positive])}"
    on_exit(fn -> stop_worker(chat) end)

    assert :ok =
             ChatWorker.enqueue(chat, %{
               "chat_id" => chat,
               "message_id" => "one",
               "execution_id" => "one"
             })

    assert :ok =
             ChatWorker.enqueue(chat, %{
               "chat_id" => chat,
               "message_id" => "two",
               "execution_id" => "two"
             })

    assert_receive {:blocking_router_started, first_work, "one"}, 1_000
    refute_receive {:blocking_router_started, _second_work, "two"}, 50
    send(first_work, {:release_blocking_router, :ok})

    assert_receive {:blocking_router_started, second_work, "two"}, 1_000
    send(second_work, {:release_blocking_router, {:noop, :handled}})
    _ = await_worker_drained(chat)
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

    assert {:noop, :already_completed} =
             ChatWorker.process_durable(chat, %{
               "chat_id" => chat,
               "message_id" => message_id
             })

    # Durable retry checks completion inline and never queues resident work.
    assert Registry.lookup(@registry, chat) == []
    refute_received {:telegram_chat_action, ^chat, "typing"}
  end

  test "awaiting confirmation only keeps action-result completion retryable" do
    user_id = "chatworker-confirmation-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    chat = "chatworker-confirmation-#{System.unique_integer([:positive])}"
    message_id = "msg-confirmation-1"
    {:ok, conversation} = TelegramConversations.start_or_continue(user_id, chat, %{})

    {:ok, {_conversation, prompt_turn}} =
      TelegramConversations.append_turn(conversation, %{
        "role" => "assistant",
        "reply_to_message_id" => message_id,
        "turn_kind" => "approval_prompt",
        "text" => "Confirm?"
      })

    {:ok, _awaiting} = TelegramConversations.mark_awaiting_confirmation(conversation)

    # The original approval prompt completed its source message even though
    # the conversation is now waiting for the user's decision.
    assert TelegramConversations.assistant_reply_recorded?(chat, message_id)

    {:ok, _action_result} =
      prompt_turn
      |> Ecto.Changeset.change(turn_kind: "action_result")
      |> Maraithon.Repo.update()

    # A result written before the local conversation-close checkpoint must let
    # durable processing re-enter and finish that checkpoint.
    refute TelegramConversations.assistant_reply_recorded?(chat, message_id)
  end
end
