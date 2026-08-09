defmodule Maraithon.TelegramAssistant.RunnerTest.Engines do
  @moduledoc false
  # Context-engine doubles for SPEC 09 R1/R2 ordering and teardown tests.
  # Both observe the world at build_context time and report it to the test
  # process so the liveness-before-context ordering is directly assertable.

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.Run

  @liveness_registry Maraithon.TelegramAssistant.LivenessRegistry

  def observe_build_started do
    case Application.get_env(:maraithon, :runner_test_pid) do
      pid when is_pid(pid) ->
        live_session_run_ids =
          Registry.select(@liveness_registry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])

        running_run_ids =
          Run
          |> where([r], r.status == "running")
          |> select([r], r.id)
          |> Repo.all()

        send(pid, {:context_build_started, live_session_run_ids, running_run_ids})

      _other ->
        :ok
    end
  end

  defmodule Crashing do
    @moduledoc false
    alias Maraithon.TelegramAssistant.RunnerTest.Engines

    def build_context(_attrs) do
      Engines.observe_build_started()
      raise "context build exploded"
    end

    def tool_catalog(_context), do: []
  end

  defmodule Healthy do
    @moduledoc false
    alias Maraithon.TelegramAssistant.RunnerTest.Engines

    def build_context(_attrs) do
      Engines.observe_build_started()
      %{"engine" => "runner-test-stub", "defaults" => %{}}
    end

    def tool_catalog(_context), do: []
  end
end

defmodule Maraithon.TelegramAssistant.RunnerTest.BlockingToolbox do
  @moduledoc false

  def execute("blocking_test_tool", _arguments, _context) do
    test_pid = Application.fetch_env!(:maraithon, :runner_test_pid)
    send(test_pid, {:blocking_tool_started, self()})

    receive do
      :release ->
        send(test_pid, {:blocking_tool_completed, self()})
        {:ok, %{"released" => true}}
    end
  end
end

defmodule Maraithon.TelegramAssistant.RunnerTest.CountingFailingTelegram do
  @moduledoc false

  def configured?, do: true

  def send_message(chat_id, text, opts \\ []) do
    test_pid = Application.fetch_env!(:maraithon, :runner_test_pid)
    send(test_pid, {:runner_delivery_attempt, chat_id, text, opts})
    {:error, Application.fetch_env!(:maraithon, :runner_delivery_failure)}
  end

  def edit_message_text(chat_id, message_id, text, opts \\ []) do
    send_message(chat_id, text, Keyword.put(opts, :message_id, message_id))
  end

  def answer_callback_query(_callback_id, _opts \\ []), do: {:ok, true}
end

defmodule Maraithon.TelegramAssistant.RunnerTest.DigestToolbox do
  @moduledoc false

  def execute("list_todos", _arguments, _context) do
    test_pid = Application.fetch_env!(:maraithon, :runner_test_pid)
    send(test_pid, :runner_digest_tool_called)
    {:ok, Application.fetch_env!(:maraithon, :runner_digest_tool_result)}
  end
end

defmodule Maraithon.TelegramAssistant.RunnerTest.FlakyDigestTelegram do
  @moduledoc false

  def configured?, do: true

  def send_message(chat_id, text, opts \\ []) do
    counter = Application.fetch_env!(:maraithon, :runner_digest_delivery_counter)
    fail_on = Application.fetch_env!(:maraithon, :runner_digest_fail_on_attempt)
    failure = Application.fetch_env!(:maraithon, :runner_digest_delivery_failure)

    attempt = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
    test_pid = Application.fetch_env!(:maraithon, :runner_test_pid)
    send(test_pid, {:runner_digest_delivery_attempt, attempt, text, opts})

    if attempt == fail_on do
      {:error, failure}
    else
      {:ok, %{"message_id" => "digest-message-#{attempt}", "chat_id" => chat_id}}
    end
  end

  def edit_message_text(chat_id, _message_id, text, opts \\ []),
    do: send_message(chat_id, text, opts)

  def send_chat_action(_chat_id, _action), do: {:ok, true}
  def answer_callback_query(_callback_id, _opts \\ []), do: {:ok, true}
end

defmodule Maraithon.TelegramAssistant.RunnerTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramAssistant.Runner
  alias Maraithon.TelegramAssistant.RunnerTest.Engines
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.Turn
  alias Maraithon.Todos
  alias Maraithon.TestSupport.FakeTelegram

  @liveness_registry Maraithon.TelegramAssistant.LivenessRegistry

  setup do
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])
    original_insights = Application.get_env(:maraithon, :insights, [])
    original_engine = Application.get_env(:maraithon, Maraithon.ContextEngine, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_full_chat_enabled: true,
        telegram_liveness_enabled: true,
        typing_initial_delay_ms: 60_000,
        typing_refresh_ms: 60_000,
        contextual_progress_delay_ms: 60_000,
        timeout_notice_ms: 60_000,
        client_module: Maraithon.TestSupport.TelegramAssistantClientStub
      )
    )

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights, telegram_module: FakeTelegram)
    )

    Application.put_env(:maraithon, :runner_test_pid, self())

    on_exit(fn ->
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
      Application.put_env(:maraithon, :insights, original_insights)
      Application.put_env(:maraithon, Maraithon.ContextEngine, original_engine)
      Application.delete_env(:maraithon, :runner_test_pid)
      Application.delete_env(:maraithon, :runner_delivery_failure)
      Application.delete_env(:maraithon, :runner_digest_delivery_counter)
      Application.delete_env(:maraithon, :runner_digest_fail_on_attempt)
      Application.delete_env(:maraithon, :runner_digest_delivery_failure)
      Application.delete_env(:maraithon, :runner_digest_tool_result)
    end)

    user_id = "runner-test-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    chat_id = "runner-chat-#{System.unique_integer([:positive])}"
    {:ok, conversation} = TelegramConversations.start_or_continue(user_id, chat_id, %{})

    %{user_id: user_id, chat_id: chat_id, conversation: conversation}
  end

  defp put_engine(engine) do
    Application.put_env(:maraithon, Maraithon.ContextEngine, engine: engine)
  end

  defp inbound_attrs(%{user_id: user_id, chat_id: chat_id, conversation: conversation}, text) do
    %{
      user_id: user_id,
      chat_id: chat_id,
      conversation: conversation,
      text: text,
      source_message_id: "100"
    }
  end

  defp await_no_liveness_session(run_id, attempts \\ 50)

  defp await_no_liveness_session(_run_id, 0), do: flunk("liveness session was not cancelled")

  defp await_no_liveness_session(run_id, attempts) do
    case Registry.lookup(@liveness_registry, run_id) do
      [] ->
        :ok

      _entries ->
        Process.sleep(20)
        await_no_liveness_session(run_id, attempts - 1)
    end
  end

  test "killing the run owner also kills every in-flight tool task", ctx do
    put_engine(Engines.Healthy)

    assistant_config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(assistant_config,
        toolbox_module: Maraithon.TelegramAssistant.RunnerTest.BlockingToolbox,
        next_step: fn _payload ->
          {:ok,
           %{
             "status" => "tool_calls",
             "tool_calls" => [
               %{"tool" => "blocking_test_tool", "arguments" => %{}}
             ]
           }}
        end
      )
    )

    owner_pid =
      spawn(fn ->
        Runner.run_inbound(inbound_attrs(ctx, "Run the blocking tool"))
      end)

    owner_ref = Process.monitor(owner_pid)
    assert_receive {:blocking_tool_started, tool_pid}, 2_000
    tool_ref = Process.monitor(tool_pid)

    Process.exit(owner_pid, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}, 2_000
    assert_receive {:DOWN, ^tool_ref, :process, ^tool_pid, _reason}, 2_000
    refute_received {:blocking_tool_completed, ^tool_pid}
  end

  test "durable final delivery errors surface while legacy mode still attempts fallback", ctx do
    put_engine(Engines.Healthy)
    failure = {:telegram_error, 503, "final delivery unavailable"}
    Application.put_env(:maraithon, :runner_delivery_failure, failure)

    assistant_config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.put(assistant_config, :next_step, fn _payload ->
        {:ok,
         %{
           "status" => "final",
           "message_class" => "assistant_reply",
           "assistant_message" => "This must be durably delivered."
         }}
      end)
    )

    insights_config = Application.get_env(:maraithon, :insights, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.put(
        insights_config,
        :telegram_module,
        Maraithon.TelegramAssistant.RunnerTest.CountingFailingTelegram
      )
    )

    durable_attrs =
      ctx
      |> inbound_attrs("Give me the durable answer")
      |> Map.put(:durable_processing, true)

    assert {:error, ^failure} = Runner.run_inbound(durable_attrs)
    assert_receive {:runner_delivery_attempt, _, "This must be durably delivered.", _}, 2_000
    refute_received {:runner_delivery_attempt, _, _, _}

    legacy_attrs = inbound_attrs(ctx, "Give me the legacy answer")

    assert {:error, {:telegram_send_failed, ^failure}} = Runner.run_inbound(legacy_attrs)
    assert_receive {:runner_delivery_attempt, _, "This must be durably delivered.", _}, 2_000
    assert_receive {:runner_delivery_attempt, _, fallback_text, _}, 2_000
    assert is_binary(fallback_text)
    assert fallback_text != "This must be durably delivered."
  end

  test "a partial todo digest is nonterminal and retry delivers only the missing suffix", ctx do
    put_engine(Engines.Healthy)

    {:ok, todos} =
      Todos.upsert_many(ctx.user_id, [
        %{
          "source" => "manual",
          "title" => "First durable digest item",
          "summary" => "The first item should not make the response terminal.",
          "next_action" => "Handle the first durable digest item.",
          "priority" => 90,
          "dedupe_key" => "runner-digest:first"
        },
        %{
          "source" => "manual",
          "title" => "Second durable digest item",
          "summary" => "The second item is the terminal digest delivery.",
          "next_action" => "Handle the second durable digest item.",
          "priority" => 80,
          "dedupe_key" => "runner-digest:second"
        }
      ])

    delivery_counter =
      start_supervised!(%{
        id: :runner_digest_delivery_counter,
        start: {Agent, :start_link, [fn -> 0 end]}
      })

    llm_counter =
      start_supervised!(%{
        id: :runner_digest_llm_counter,
        start: {Agent, :start_link, [fn -> 0 end]}
      })

    failure = {:telegram_error, 503, "second digest item unavailable"}
    Application.put_env(:maraithon, :runner_digest_delivery_counter, delivery_counter)
    Application.put_env(:maraithon, :runner_digest_fail_on_attempt, 3)
    Application.put_env(:maraithon, :runner_digest_delivery_failure, failure)

    Application.put_env(:maraithon, :runner_digest_tool_result, %{
      "todos" => Enum.map(todos, &%{"id" => &1.id})
    })

    assistant_config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(assistant_config,
        toolbox_module: Maraithon.TelegramAssistant.RunnerTest.DigestToolbox,
        next_step: fn payload ->
          Agent.update(llm_counter, &(&1 + 1))

          if Map.get(payload, :llm_turns, 0) == 0 do
            {:ok,
             %{
               "status" => "tool_calls",
               "tool_calls" => [%{"tool" => "list_todos", "arguments" => %{}}]
             }}
          else
            {:ok,
             %{
               "status" => "final",
               "message_class" => "todo_digest",
               "assistant_message" => "Here is your durable open work."
             }}
          end
        end
      )
    )

    insights_config = Application.get_env(:maraithon, :insights, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.put(
        insights_config,
        :telegram_module,
        Maraithon.TelegramAssistant.RunnerTest.FlakyDigestTelegram
      )
    )

    attrs =
      ctx
      |> inbound_attrs("List my current open work")
      |> Map.put(:source_message_id, "durable-digest-source")
      |> Map.put(:durable_processing, true)

    assert {:error, ^failure} = Runner.run_inbound(attrs)
    assert Agent.get(llm_counter, & &1) == 2
    assert_received :runner_digest_tool_called
    assert Agent.get(delivery_counter, & &1) == 3

    partial_turns =
      Turn
      |> where([turn], turn.conversation_id == ^ctx.conversation.id)
      |> order_by([turn], asc: turn.inserted_at)
      |> Repo.all()

    assert length(partial_turns) == 2
    assert Enum.all?(partial_turns, &(get_in(&1.structured_data, ["terminal_response"]) == false))

    refute TelegramConversations.assistant_reply_recorded?(
             ctx.chat_id,
             "durable-digest-source"
           )

    partial_run = Repo.one!(from run in Run, where: run.user_id == ^ctx.user_id)
    assert partial_run.status == "degraded"
    assert get_in(partial_run.result_summary, ["delivery_checkpoint", "kind"]) == "todo_digest"

    assert :ok = Runner.run_inbound(attrs)
    assert Agent.get(llm_counter, & &1) == 2
    refute_received :runner_digest_tool_called
    assert Agent.get(delivery_counter, & &1) == 4

    completed_turns =
      Turn
      |> where([turn], turn.conversation_id == ^ctx.conversation.id)
      |> order_by([turn], asc: turn.inserted_at)
      |> Repo.all()

    assert length(completed_turns) == 3

    assert Enum.count(
             completed_turns,
             &(get_in(&1.structured_data, ["message_class"]) == "todo_item")
           ) == 2

    assert get_in(List.last(completed_turns).structured_data, ["terminal_response"]) == true

    assert TelegramConversations.assistant_reply_recorded?(
             ctx.chat_id,
             "durable-digest-source"
           )

    assert Repo.get!(Run, partial_run.id).status == "completed"
  end

  test "bounds retained tool results while preserving required identifiers" do
    huge = %{
      "id" => "provider-result-123",
      "status" => "completed",
      "payload" => Map.new(1..3_000, &{"key-#{&1}", String.duplicate("x", 1_000)})
    }

    assert %{
             "id" => "provider-result-123",
             "status" => "completed",
             "_truncated" => true
           } = bounded = Runner.bounded_tool_result(huge)

    assert Maraithon.PromptBudget.encoded_bytes(bounded) <= 32_000

    deep = Enum.reduce(1..20, %{"leaf" => true}, fn _, acc -> %{"nested" => acc} end)
    assert %{"_truncated" => true} = Runner.bounded_tool_result(deep)
  end

  test "mints the run and starts liveness before context build begins (SPEC 09 R1)",
       ctx do
    put_engine(Engines.Crashing)

    _result = Runner.run_inbound(inbound_attrs(ctx, "Who is Elena Fisher?"))

    assert_receive {:context_build_started, live_session_run_ids, running_run_ids}, 2_000

    run = Repo.one!(from r in Run, where: r.user_id == ^ctx.user_id)

    # By the time build_context ran, this run's row already existed at
    # status "running" AND its liveness session was already registered.
    assert run.id in running_run_ids
    assert run.id in live_session_run_ids
  end

  test "a context-build crash degrades the run and cancels liveness (SPEC 09 R2)", ctx do
    put_engine(Engines.Crashing)

    assert {:fallback, %RuntimeError{message: "context build exploded"}} =
             Runner.run_inbound(inbound_attrs(ctx, "Who is Elena Fisher?"))

    run = Repo.one!(from r in Run, where: r.user_id == ^ctx.user_id)

    # Never left parked at "running" with an orphaned liveness session.
    assert run.status == "degraded"
    assert is_binary(run.error)
    await_no_liveness_session(run.id)
  end

  test "backfills the real prompt snapshot after the placeholder run is minted", ctx do
    put_engine(Engines.Healthy)

    :maraithon
    |> Application.get_env(:telegram_assistant, [])
    |> Keyword.put(:next_step, fn _payload ->
      {:ok,
       %{
         "status" => "final",
         "message_class" => "assistant_reply",
         "assistant_message" => "All done."
       }}
    end)
    |> then(&Application.put_env(:maraithon, :telegram_assistant, &1))

    assert :ok = Runner.run_inbound(inbound_attrs(ctx, "What should I do next?"))

    run = Repo.one!(from r in Run, where: r.user_id == ^ctx.user_id)

    assert run.status == "completed"
    # The placeholder %{} snapshot was replaced with the built context.
    assert run.prompt_snapshot["engine"] == "runner-test-stub"
  end
end
