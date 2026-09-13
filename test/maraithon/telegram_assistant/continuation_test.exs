defmodule Maraithon.TelegramAssistant.ContinuationTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.{Accounts, AssistantChat, AssistantHarness, TelegramAssistant}
  alias Maraithon.AssistantChat.Execution
  alias Maraithon.TelegramAssistant.{Continuation, Run, Runner, Step}
  alias Maraithon.TelegramConversations.Turn

  setup do
    original = Application.get_env(:maraithon, :telegram_assistant, [])
    engine = Application.get_env(:maraithon, Maraithon.ContextEngine, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original,
        client_module: Maraithon.TestSupport.TelegramAssistantClientStub,
        toolbox_module: Maraithon.TestSupport.ContinuationToolbox
      )
    )

    Application.put_env(:maraithon, Maraithon.ContextEngine,
      engine: Maraithon.TestSupport.ContinuationContextEngine
    )

    Application.put_env(:maraithon, :continuation_test_pid, self())

    on_exit(fn ->
      Application.put_env(:maraithon, :telegram_assistant, original)
      Application.put_env(:maraithon, Maraithon.ContextEngine, engine)
      Application.delete_env(:maraithon, :continuation_test_pid)
      Application.delete_env(:maraithon, :continuation_test_pause)
    end)

    user_id = "continuation-#{System.unique_integer([:positive])}@example.com"
    {:ok, _} = Accounts.get_or_create_user_by_email(user_id)
    {:ok, conversation} = AssistantChat.create_thread(user_id, %{"title" => "Recovery exercise"})

    {:ok, run} =
      TelegramAssistant.start_run(%{
        user_id: user_id,
        chat_id: conversation.chat_id,
        surface: "mobile",
        conversation_id: conversation.id,
        status: "running",
        trigger_type: "inbound_message",
        model_provider: "test",
        model_name: "test-model",
        started_at: DateTime.utc_now(),
        prompt_snapshot: %{},
        result_summary: %{}
      })

    attrs = %{
      run: run,
      user_id: user_id,
      chat_id: conversation.chat_id,
      conversation: conversation,
      surface: "mobile",
      source_message_id: Ecto.UUID.generate(),
      durable_processing: true,
      request_focus: :continuity,
      text: "Review context for this meeting"
    }

    %{run: run, attrs: attrs, profile: %{tier: :chat, model: "test", llm_opts: []}}
  end

  test "restart reuses a committed result, finishes a partial native batch, and delivers once",
       ctx do
    test_pid = self()

    set_client(fn payload ->
      send(test_pid, {:continuation_model, payload})

      if payload.tool_history == [] do
        {:ok,
         %{
           "status" => "tool_calls",
           "tool_calls" => [
             %{"tool" => "list_todos", "arguments" => %{}},
             %{"tool" => "get_person", "arguments" => %{"person_id" => "controlled-person"}}
           ],
           "_native_message" => %{
             "role" => "assistant",
             "reasoning" => "private-not-for-storage",
             "tool_calls" => [
               native_call("call-one", "list_todos", %{}),
               native_call("call-two", "get_person", %{"person_id" => "controlled-person"})
             ]
           }
         }}
      else
        {:ok,
         %{
           "status" => "final",
           "message_class" => "assistant_reply",
           "assistant_message" => "Meeting context reviewed. The meeting remains open."
         }}
      end
    end)

    Application.put_env(:maraithon, :continuation_test_pause, true)
    owner = spawn(fn -> Runner.run_inbound(ctx.attrs) end)
    monitor = Process.monitor(owner)
    assert_receive {:continuation_model, _}, 3_000
    assert_receive {:continuation_tool, "list_todos", _, _}, 3_000
    assert_receive {:continuation_tool, "get_person", _, child}, 3_000
    child_monitor = Process.monitor(child)
    wait_for_receipt(ctx.run.id, "list_todos")
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 2_000
    assert_receive {:DOWN, ^child_monitor, :process, ^child, _}, 2_000

    interrupted = reload(ctx.run)
    checkpoint = interrupted.result_summary["execution_checkpoint"]
    assert checkpoint["phase"] == "decision"
    assert checkpoint["state"]["llm_turns"] == 1
    refute Jason.encode!(checkpoint) =~ "private-not-for-storage"

    assert Enum.map(checkpoint["response"]["tool_calls"], & &1["call_id"]) == [
             "call-one",
             "call-two"
           ]

    Application.put_env(:maraithon, :continuation_test_pause, false)
    assert :ok = Runner.resume_request(%{ctx.attrs | run: interrupted})
    refute_received {:continuation_tool, "list_todos", _, _}
    assert_received {:continuation_tool, "get_person", _, _}

    assert_received {:continuation_model,
                     %{llm_turns: 1, tool_steps: 2, tool_history: history} = payload}

    assert length(history) == 2
    assert payload[:_native_exchanges] == []
    assert reload(ctx.run).status == "completed"

    assert Repo.aggregate(
             from(t in Turn,
               where: t.conversation_id == ^ctx.run.conversation_id and t.role == "assistant"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(s in Step, where: s.run_id == ^ctx.run.id and s.step_type == "tool_call"),
             :count
           ) == 2
  end

  test "unknown mutating outcomes are blocked while a committed mutation is reused", ctx do
    call = %{"tool" => "prepare_external_action", "arguments" => %{}, "call_id" => "action-one"}
    assert {:ok, {:execute, step}} = Continuation.tool(ctx.run, call, 4)
    assert {:error, {:tool_outcome_unknown, id}} = Continuation.tool(ctx.run, call, 4)
    assert id == step.id

    assert {:ok, _} =
             TelegramAssistant.complete_step(step, %{
               response_payload: %{"prepared_action_id" => "saved"}
             })

    assert {:ok, {:receipt, %{"result" => %{"prepared_action_id" => "saved"}}}} =
             Continuation.tool(ctx.run, call, 4)

    assert {:error, :tool_checkpoint_mismatch} =
             Continuation.tool(ctx.run, %{call | "call_id" => "different"}, 4)
  end

  test "model entry survives restart and cannot reset counters or elapsed time", ctx do
    assert {:ok, checkpoint} =
             Continuation.start(ctx.run, ctx.attrs, ctx.profile, max_wall_clock_ms: 30_000)

    state = %{AssistantHarness.initial_loop_state() | llm_turns: 2, tool_steps: 0, sequence: 5}
    assert {:ok, _} = Continuation.save(ctx.run, checkpoint, "model_entered", state)
    assert {:ok, recovered, _, loaded} = Continuation.load(reload(ctx.run), ctx.attrs)
    assert loaded.llm_turns == 2
    assert loaded.sequence == 5
    assert recovered["deadline_ms"] == checkpoint["deadline_ms"]
    assert Continuation.remaining_ms(%{recovered | "deadline_ms" => 0}) == 0
  end

  test "invalid versions, scopes and counters fail closed", ctx do
    {:ok, checkpoint} = Continuation.start(ctx.run, ctx.attrs, ctx.profile, [])

    for corrupt <- [
          Map.put(checkpoint, "version", 900),
          Map.put(checkpoint, "run_id", Ecto.UUID.generate()),
          Map.put(checkpoint, "source_message_id", Ecto.UUID.generate()),
          Map.put(checkpoint, "state", %{}),
          Map.put(checkpoint, "phase", "surprise")
        ] do
      assert {:error, :invalid_execution_checkpoint} =
               Continuation.validate(corrupt, ctx.run, ctx.attrs)
    end

    assert {:error, :invalid_execution_checkpoint} =
             Continuation.validate(checkpoint, %{ctx.run | status: "completed"}, ctx.attrs)
  end

  test "an oversized model decision preserves the last resumable checkpoint", ctx do
    {:ok, checkpoint} = Continuation.start(ctx.run, ctx.attrs, ctx.profile, [])
    state = AssistantHarness.initial_loop_state()
    response = %{"status" => "final", "answer" => String.duplicate("x", 64_001)}

    assert {:error, _} = Continuation.save(ctx.run, checkpoint, "decision", state, response)
    assert {:ok, recovered, _, _} = Continuation.load(reload(ctx.run), ctx.attrs)
    assert recovered == checkpoint

    corrupt = Map.put(checkpoint, "response", response)

    assert {:error, :invalid_execution_checkpoint} =
             Continuation.validate(corrupt, ctx.run, ctx.attrs)
  end

  test "a saved final decision drains after its model deadline without another model call", ctx do
    set_client(fn _ -> flunk("saved final response invoked the model again") end)
    {:ok, checkpoint} = Continuation.start(ctx.run, ctx.attrs, ctx.profile, [])
    checkpoint = Map.put(checkpoint, "deadline_ms", 0)
    state = %{AssistantHarness.initial_loop_state() | llm_turns: 1, sequence: 3}

    {:ok, _} =
      Continuation.save(ctx.run, checkpoint, "decision", state, %{
        "status" => "final",
        "message_class" => "assistant_reply",
        "assistant_message" => "Saved answer."
      })

    assert :ok = Runner.resume_request(%{ctx.attrs | run: reload(ctx.run)})
    assert reload(ctx.run).status == "completed"

    assert {:error, :request_not_resumable} =
             Runner.resume_request(%{ctx.attrs | run: reload(ctx.run)})

    assert reload(ctx.run).status == "completed"
  end

  test "a model request lost before its response consumes its original call budget", ctx do
    parent = self()

    set_client(fn payload ->
      send(parent, {:recovered_model_budget, payload.llm_turns})

      {:ok,
       %{
         "status" => "final",
         "message_class" => "assistant_reply",
         "assistant_message" => "Recovered answer."
       }}
    end)

    {:ok, checkpoint} = Continuation.start(ctx.run, ctx.attrs, ctx.profile, [])
    state = %{AssistantHarness.initial_loop_state() | llm_turns: 1, sequence: 3}
    {:ok, _} = Continuation.save(ctx.run, checkpoint, "model_entered", state)
    assert :ok = Runner.resume_request(%{ctx.attrs | run: reload(ctx.run)})
    assert_received {:recovered_model_budget, 1}
    assert reload(ctx.run).result_summary["llm_turns"] == 2
  end

  test "an expired execution cannot enter a pending tool", ctx do
    set_client(fn _ -> flunk("expired request called the model") end)
    profile = %{ctx.profile | tier: :reasoning}
    {:ok, checkpoint} = Continuation.start(ctx.run, ctx.attrs, profile, [])
    state = %{AssistantHarness.initial_loop_state() | llm_turns: 1, sequence: 3}

    {:ok, _} =
      Continuation.save(ctx.run, Map.put(checkpoint, "deadline_ms", 0), "decision", state, %{
        "status" => "tool_calls",
        "tool_calls" => [%{"tool" => "get_person", "arguments" => %{}}]
      })

    assert :ok = Runner.resume_request(%{ctx.attrs | run: reload(ctx.run)})
    refute_received {:continuation_tool, _, _, _}
    assert reload(ctx.run).status == "degraded"
  end

  test "a worker without a live claim cannot write a completed step", ctx do
    {:ok, {:execute, step}} =
      Continuation.tool(ctx.run, %{"tool" => "list_todos", "arguments" => %{}}, 4)

    stale = %Maraithon.Runtime.BackgroundJob{
      id: Ecto.UUID.generate(),
      claim_token: Ecto.UUID.generate(),
      user_id: ctx.run.user_id,
      payload: %{"conversation_id" => ctx.run.conversation_id}
    }

    result =
      Execution.with_authority(stale, fn ->
        TelegramAssistant.complete_step(step, %{response_payload: %{"forged" => "result"}})
      end)

    assert {:error, reason} = result
    assert reason in [:task_authority_required, :claim_lost]
    assert Repo.get!(Step, step.id).status == "running"
  end

  test "child authority is explicitly inherited and restored", _ctx do
    assert Execution.capture_authority() == nil
    marker = %Maraithon.Runtime.BackgroundJob{id: Ecto.UUID.generate(), user_id: "owned"}

    assert :ok =
             Execution.with_authority(marker, fn ->
               captured = Execution.capture_authority()

               task =
                 Task.async(fn ->
                   Execution.with_authority(captured, fn ->
                     assert Execution.capture_authority() == marker
                     :ok
                   end)
                 end)

               Task.await(task)
             end)

    assert Execution.capture_authority() == nil
  end

  test "model escalation keeps the same run, completed work and charged calls", ctx do
    set_client(fn payload ->
      case payload.llm_turns do
        0 ->
          {:ok,
           %{
             "status" => "tool_calls",
             "tool_calls" => [%{"tool" => "list_todos", "arguments" => %{}}]
           }}

        1 ->
          {:ok,
           %{
             "status" => "tool_calls",
             "tool_calls" => [%{"tool" => "request_deeper_analysis", "arguments" => %{}}]
           }}

        2 ->
          {:ok,
           %{
             "status" => "final",
             "message_class" => "assistant_reply",
             "assistant_message" => "Reviewed with saved context."
           }}
      end
    end)

    assert :ok = Runner.run_inbound(ctx.attrs)
    assert_received {:continuation_tool, "list_todos", _, _}
    refute_received {:continuation_tool, "list_todos", _, _}
    assert reload(ctx.run).result_summary["llm_turns"] == 3
    assert reload(ctx.run).result_summary["tool_steps"] == 1

    assert Repo.aggregate(
             from(r in Run, where: r.conversation_id == ^ctx.run.conversation_id),
             :count
           ) == 1
  end

  test "a lost mutation response pauses for review instead of inviting the model to repeat it",
       ctx do
    set_client(fn _ ->
      {:ok,
       %{
         "status" => "tool_calls",
         "tool_calls" => [
           %{"tool" => "prepare_external_action", "arguments" => %{"lose_response" => true}}
         ]
       }}
    end)

    assert :ok = Runner.run_inbound(ctx.attrs)
    assert_received {:continuation_tool, "prepare_external_action", _, _}
    refute_received {:continuation_tool, "prepare_external_action", _, _}
    assert reload(ctx.run).status == "degraded"
    assert reload(ctx.run).error =~ "tool_outcome_unknown"

    step =
      Repo.one!(from(s in Step, where: s.run_id == ^ctx.run.id and s.step_type == "tool_call"))

    assert step.status == "running"
  end

  defp set_client(fun) do
    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.put(Application.fetch_env!(:maraithon, :telegram_assistant), :next_step, fun)
    )
  end

  defp native_call(id, name, args),
    do: %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
    }

  defp reload(run), do: Repo.get!(Run, run.id) |> Run.hydrate_payloads()
  defp wait_for_receipt(run_id, tool, attempts \\ 200)
  defp wait_for_receipt(_run_id, _tool, 0), do: flunk("tool receipt was not committed")

  defp wait_for_receipt(run_id, tool, attempts) do
    found =
      Repo.all(from(s in Step, where: s.run_id == ^run_id and s.status == "completed"))
      |> Enum.map(&Step.hydrate_payloads/1)
      |> Enum.any?(&(&1.request_payload["tool"] == tool))

    if found,
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_for_receipt(run_id, tool, attempts - 1)
        )
  end
end
