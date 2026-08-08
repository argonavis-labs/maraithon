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

defmodule Maraithon.TelegramAssistant.RunnerTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramAssistant.Runner
  alias Maraithon.TelegramAssistant.RunnerTest.Engines
  alias Maraithon.TelegramConversations
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
