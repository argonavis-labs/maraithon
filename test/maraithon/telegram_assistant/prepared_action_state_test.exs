defmodule Maraithon.TelegramAssistant.PreparedActionStateTest.ScriptedExecutor do
  @moduledoc false

  def execute_prepared_action(prepared_action) do
    {call_number, instruction} =
      Agent.get_and_update(:prepared_action_scripted_executor, fn state ->
        case state.script do
          [next | rest] ->
            call_number = state.calls + 1
            {{call_number, next}, %{state | script: rest, calls: call_number}}

          [] ->
            call_number = state.calls + 1

            {{call_number, {:return, {:error, :unexpected_provider_call}}},
             %{state | calls: call_number}}
        end
      end)

    observer = Application.fetch_env!(:maraithon, :prepared_action_executor_test_pid)
    send(observer, {:prepared_action_executor_called, call_number, prepared_action, self()})

    case instruction do
      {:return, result} ->
        result

      {:wait, result} ->
        receive do
          {:release_prepared_action_executor, ^call_number} -> result
        after
          5_000 -> {:error, :scripted_executor_timeout}
        end
    end
  end
end

defmodule Maraithon.TelegramAssistant.PreparedActionStateTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AssistantChat
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.Projects
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.PreparedAction
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.Turn
  alias Maraithon.TestSupport.{BoundedHTTPTimeout, CapturingTelegram}

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    start_supervised!(%{
      id: :prepared_action_scripted_executor,
      start:
        {Agent, :start_link,
         [fn -> %{script: [], calls: 0} end, [name: :prepared_action_scripted_executor]]}
    })

    original_insights = Application.get_env(:maraithon, :insights, [])
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])
    original_capture = Application.get_env(:maraithon, :capturing_telegram, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.put(original_insights, :telegram_module, CapturingTelegram)
    )

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.put(original_assistant, :telegram_full_chat_enabled, true)
    )

    Application.put_env(:maraithon, :capturing_telegram, callback_result: :ok, edit_result: :ok)

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
      Application.put_env(:maraithon, :capturing_telegram, original_capture)
      Application.delete_env(:maraithon, :prepared_action_executor_test_pid)
    end)

    user_id = "prepared-state-#{System.unique_integer([:positive])}@example.com"
    chat_id = "prepared-state-chat-#{System.unique_integer([:positive])}"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: chat_id,
        metadata: %{"username" => "prepared-state"}
      })

    {:ok, conversation} = TelegramConversations.start_or_continue(user_id, chat_id, %{})
    {:ok, run} = create_run(user_id, chat_id, conversation.id, "telegram")

    %{user_id: user_id, chat_id: chat_id, conversation: conversation, run: run}
  end

  test "stale reject, expiry, and draft edit cannot overwrite a closed state", ctx do
    for status <- ~w(confirmed executed failed rejected) do
      {:ok, stale_action} =
        create_action(ctx,
          status: "awaiting_confirmation",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
          target_id: "closed-#{status}-#{System.unique_integer([:positive])}"
        )

      stale_action
      |> Ecto.Changeset.change(status: status)
      |> Repo.update!()

      assert {:error, %PreparedAction{status: ^status}, :already_handled} =
               TelegramAssistant.reject_prepared_action(stale_action)

      assert {:error, %PreparedAction{status: ^status}, :already_handled} =
               TelegramAssistant.expire_prepared_action(stale_action)

      test_pid = self()

      assert {:error, %PreparedAction{status: ^status}, :already_handled} =
               TelegramAssistant.edit_prepared_action(stale_action, fn _locked ->
                 send(test_pid, :stale_edit_ran)
                 {:ok, %{payload: %{"text" => "overwritten"}}}
               end)

      refute_received :stale_edit_ran
      assert Repo.get!(PreparedAction, stale_action.id).status == status
    end
  end

  test "confirmation and rejection race to one coherent terminal outcome", ctx do
    {:ok, project} =
      Projects.create_project(ctx.user_id, %{
        "name" => "Race target",
        "summary" => "before"
      })

    {:ok, action} =
      create_action(ctx,
        target_id: project.id,
        payload: %{
          "project_id" => project.id,
          "attrs" => %{"summary" => "after"}
        }
      )

    parent = self()

    confirm_task =
      Task.async(fn ->
        receive do
          :go -> send(parent, {:confirm_result, TelegramAssistant.confirm_and_execute(action)})
        end
      end)

    reject_task =
      Task.async(fn ->
        receive do
          :go -> send(parent, {:reject_result, TelegramAssistant.reject_prepared_action(action)})
        end
      end)

    send(confirm_task.pid, :go)
    send(reject_task.pid, :go)

    assert_receive {:confirm_result, confirm_result}
    assert_receive {:reject_result, reject_result}
    Task.await(confirm_task)
    Task.await(reject_task)

    final_action = Repo.get!(PreparedAction, action.id)
    final_project = Projects.get_project_for_user(project.id, ctx.user_id)

    case final_action.status do
      "executed" ->
        assert match?({:ok, %PreparedAction{status: "executed"}, _result}, confirm_result)

        assert {:error, %PreparedAction{} = rejected_view, :already_handled} = reject_result
        assert rejected_view.status in ["confirmed", "executed"]

        assert final_project.summary == "after"

      "rejected" ->
        assert match?(
                 {:error, %PreparedAction{status: "rejected"}, :already_handled},
                 confirm_result
               )

        assert match?({:ok, %PreparedAction{status: "rejected"}}, reject_result)
        assert final_project.summary == "before"
    end
  end

  test "approval prompts are not result proof and permanent failures drain once", ctx do
    missing_project_id = Ecto.UUID.generate()

    {:ok, action} =
      create_action(ctx,
        action_type: "project_update",
        target_id: missing_project_id,
        payload: %{
          "project_id" => missing_project_id,
          "attrs" => %{"summary" => "will not apply"}
        }
      )

    {:ok, _waiting} =
      TelegramAssistant.mark_conversation_awaiting_action(ctx.conversation, action)

    assert {:ok, _conversation, %Turn{turn_kind: "approval_prompt"}, _result} =
             TelegramAssistant.send_turn(
               ctx.conversation,
               ctx.chat_id,
               "Approve this update?",
               reply_to_message_id: "approval-source",
               turn_kind: "approval_prompt",
               origin_type: "prepared_action",
               origin_id: action.id,
               structured_data: %{"prepared_action_id" => action.id}
             )

    refute TelegramAssistant.prepared_action_result_delivered?(action)

    event = %{
      type: "callback_query",
      source: "telegram",
      data: %{
        chat_id: ctx.chat_id,
        message_id: "approval-source",
        callback_id: "permanent-action-callback",
        data: "tgact:#{action.id}:confirm"
      }
    }

    assert :ok = InsightNotifications.process_telegram_event_durable(event)

    failed = Repo.get!(PreparedAction, action.id)
    assert failed.status == "failed"
    assert byte_size(failed.error) <= 240
    assert get_in(failed.payload, ["_maraithon_execution_error", "status"]) == "failed"
    assert is_binary(failed.payload["_maraithon_result_delivered_at"])

    assert %Turn{turn_kind: "action_result", origin_id: origin_id} =
             Repo.get_by!(Turn,
               conversation_id: ctx.conversation.id,
               turn_kind: "action_result",
               origin_id: action.id
             )

    assert origin_id == action.id
    sends_before_retry = count_telegram_events(:send)

    assert {:noop, :prepared_action_already_delivered} =
             InsightNotifications.process_telegram_event_durable(event)

    assert count_telegram_events(:send) == sends_before_retry

    assert TelegramAssistant.prepared_action_error_class({:api_error, 503, "unavailable"}) ==
             :transient

    assert TelegramAssistant.prepared_action_error_class(
             "Gmail is temporarily unavailable. Wait a minute before running this action."
           ) == :transient

    assert TelegramAssistant.prepared_action_error_class(:rate_limited) == :transient
    assert TelegramAssistant.prepared_action_error_class(%{reason: :econnrefused}) == :transient
    assert TelegramAssistant.prepared_action_error_class(:project_not_found) == :permanent

    assert TelegramAssistant.prepared_action_error_class("google_account_reauth_required") ==
             :permanent
  end

  test "a provider success followed by turn persistence failure is returned as an error", ctx do
    Code.ensure_loaded!(CapturingTelegram)
    missing_conversation = %{ctx.conversation | id: Ecto.UUID.generate()}
    sends_before = count_telegram_events(:send)

    assert {:error, :telegram_turn_persistence_failed} =
             TelegramAssistant.send_turn(
               missing_conversation,
               ctx.chat_id,
               "The provider accepted this, but the local turn cannot commit.",
               turn_kind: "assistant_reply"
             )

    assert count_telegram_events(:send) == sends_before + 1
  end

  test "mobile confirmation freezes edits, releases its row lock, and executes once", ctx do
    configure_scripted_executor(
      [{:wait, {:ok, %{"message" => "Posted the frozen Slack message."}}}],
      prepared_action_execution_lease_seconds: 1,
      prepared_action_execution_heartbeat_ms: 100
    )

    {:ok, conversation, action} = create_mobile_action(ctx, %{"text" => "old body"})

    first =
      Task.async(fn ->
        AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
          "client_message_id" => Ecto.UUID.generate(),
          "draft_edits" => %{"text" => "frozen body"}
        })
      end)

    assert_receive {:prepared_action_executor_called, 1, executing_action, executor_pid}, 1_000
    assert executing_action.status == "confirmed"
    assert executing_action.payload["text"] == "frozen body"
    assert executing_action.payload["_maraithon_confirmed_payload_sha256"]
    assert executing_action.payload["_maraithon_execution_attempts"] == 1

    # The provider waits outside the confirmation transaction: another
    # caller can acquire the same row immediately and observes the committed
    # frozen decision instead of blocking behind a network call.
    persisted_while_provider_waits = Repo.get!(PreparedAction, action.id)
    assert persisted_while_provider_waits.status == "confirmed"
    assert persisted_while_provider_waits.payload["text"] == "frozen body"

    # Wait past the original one-second lease. The live provider task's
    # heartbeat must keep the token fenced, so this retry still cannot claim.
    Process.send_after(self(), :original_execution_lease_elapsed, 1_200)
    assert_receive :original_execution_lease_elapsed, 1_500

    second =
      Task.async(fn ->
        AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
          "client_message_id" => Ecto.UUID.generate(),
          "draft_edits" => %{"text" => "stale overwrite"}
        })
      end)

    assert Task.await(second, 1_000) ==
             {:error, {:prepared_action_execution_retryable, :transient}}

    send(executor_pid, {:release_prepared_action_executor, 1})

    assert {:ok, %{prepared_action: executed, thread: thread}} = Task.await(first, 2_000)
    assert executed.status == "executed"
    assert executed.payload["text"] == "frozen body"

    result_turns =
      Enum.filter(thread.turns, fn turn ->
        turn.turn_kind == "action_result" and turn.origin_id == action.id
      end)

    assert [%Turn{client_message_id: "prepared-action-result:" <> _id}] = result_turns

    # A later stale editor resumes the checkpoint; it neither calls the
    # provider nor creates another local result/push reservation.
    assert {:ok, %{prepared_action: resumed, thread: resumed_thread}} =
             AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
               "client_message_id" => Ecto.UUID.generate(),
               "draft_edits" => %{"text" => "another stale overwrite"}
             })

    assert resumed.status == "executed"
    assert resumed.payload["text"] == "frozen body"
    assert scripted_executor_calls() == 1

    assert Enum.count(resumed_thread.turns, fn turn ->
             turn.turn_kind == "action_result" and turn.origin_id == action.id
           end) == 1

    assert conversation.id == executed.conversation_id
  end

  test "an expired project mutation owner terminalizes without starting a concurrent task", ctx do
    configure_scripted_executor(
      [{:wait, {:ok, %{"message" => "Created once."}}}],
      prepared_action_execution_lease_seconds: 1,
      prepared_action_execution_heartbeat_ms: 100
    )

    {:ok, _conversation, action} =
      create_mobile_action(
        ctx,
        %{
          "user_id" => ctx.user_id,
          "attrs" => %{"name" => "Fenced project"}
        },
        action_type: "project_create",
        target_type: "project"
      )

    first =
      Task.async(fn ->
        AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
          "client_message_id" => Ecto.UUID.generate()
        })
      end)

    assert_receive {:prepared_action_executor_called, 1, _executing_action, provider_pid}, 1_000
    provider_ref = Process.monitor(provider_pid)
    :erlang.suspend_process(first.pid)

    try do
      stale_action = Repo.get!(PreparedAction, action.id)

      stale_payload =
        stale_action.payload
        |> Map.put(
          "_maraithon_execution_lease_until",
          DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
        )
        |> Map.put("_maraithon_execution_reclaimable", true)

      stale_action
      |> Ecto.Changeset.change(payload: stale_payload)
      |> Repo.update!()

      assert {:ok, %{prepared_action: unknown}} =
               AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
                 "client_message_id" => Ecto.UUID.generate()
               })

      assert unknown.status == "execution_unknown"
      assert get_in(unknown.payload, ["_maraithon_execution_error", "class"]) == "ambiguous"
      assert scripted_executor_calls() == 1
      refute_receive {:prepared_action_executor_called, 2, _action, _pid}, 100
      refute_receive {:DOWN, ^provider_ref, :process, ^provider_pid, _reason}, 100
    after
      :erlang.resume_process(first.pid)
    end

    _ = Task.await(first, 2_000)
    assert_receive {:DOWN, ^provider_ref, :process, ^provider_pid, _reason}, 1_000
    assert Repo.get!(PreparedAction, action.id).status == "execution_unknown"
    assert scripted_executor_calls() == 1
  end

  test "mobile transient execution retries are finite and terminal delivery is deterministic",
       ctx do
    configure_scripted_executor(
      [
        {:return, {:error, {:http_error, 503, "provider unavailable"}}},
        {:return, {:error, {:api_error, 409, "conflict"}}},
        {:return, {:error, %{status: 429, reason: "rate limited"}}}
      ],
      prepared_action_max_attempts: 3
    )

    {:ok, _conversation, action} = create_mobile_action(ctx, %{"text" => "retry me"})

    for expected_attempt <- 1..2 do
      assert {:error, {:prepared_action_execution_retryable, :transient}} =
               AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
                 "client_message_id" => Ecto.UUID.generate()
               })

      retryable = Repo.get!(PreparedAction, action.id)
      assert retryable.status == "confirmed"
      assert retryable.payload["_maraithon_execution_attempts"] == expected_attempt
      refute Map.has_key?(retryable.payload, "_maraithon_execution_token")
    end

    assert {:ok, %{prepared_action: failed, thread: thread}} =
             AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
               "client_message_id" => Ecto.UUID.generate()
             })

    assert failed.status == "failed"
    assert failed.payload["_maraithon_execution_attempts"] == 3
    assert is_map(failed.payload["_maraithon_execution_error"])
    assert scripted_executor_calls() == 3

    assert Enum.count(thread.turns, fn turn ->
             turn.turn_kind == "action_result" and turn.origin_id == action.id
           end) == 1

    assert {:ok, %{prepared_action: still_failed, thread: resumed_thread}} =
             AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
               "client_message_id" => Ecto.UUID.generate()
             })

    assert still_failed.status == "failed"
    assert scripted_executor_calls() == 3

    assert Enum.count(resumed_thread.turns, fn turn ->
             turn.turn_kind == "action_result" and turn.origin_id == action.id
           end) == 1
  end

  test "structured provider status wins over lossy detail text", ctx do
    assert TelegramAssistant.prepared_action_error_class(:timeout) == :ambiguous

    assert TelegramAssistant.prepared_action_error_class({:http_error, 408, "bad request"}) ==
             :ambiguous

    assert TelegramAssistant.prepared_action_error_class({:http_error, 409, "conflict"}) ==
             :transient

    assert TelegramAssistant.prepared_action_error_class(%{status_code: 429}) == :transient

    assert TelegramAssistant.prepared_action_error_class({:api_error, 500, "server"}) ==
             :transient

    assert TelegramAssistant.prepared_action_error_class(
             {:http_error, 422, "the user text said timeout"}
           ) == :permanent

    configure_scripted_executor([
      {:return, {:error, {:http_error, 422, "the user text said timeout"}}}
    ])

    {:ok, _conversation, action} = create_mobile_action(ctx, %{"text" => "poison"})

    assert {:ok, %{prepared_action: failed}} =
             AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
               "client_message_id" => Ecto.UUID.generate()
             })

    assert failed.status == "failed"
    assert failed.payload["_maraithon_execution_attempts"] == 1
    assert scripted_executor_calls() == 1
  end

  test "real lossy HTTP write shapes become execution unknown without durable raw detail", ctx do
    timeout_bypass = Bypass.open()
    BoundedHTTPTimeout.expect_once(timeout_bypass, "/prepared-action-timeout")

    assert {:error, {:http_error, "unknown_error"} = bounded_timeout_reason} =
             BoundedHTTPTimeout.get(timeout_bypass, "/prepared-action-timeout")

    transport_bypass = Bypass.open()
    transport_port = transport_bypass.port
    Bypass.down(transport_bypass)

    assert {:error, {:http_error, "Elixir.Req.TransportError"} = transport_reason} =
             Maraithon.HTTP.get("http://localhost:#{transport_port}/lost-response", [],
               receive_timeout: 500,
               request_timeout: 1_000,
               log_failures?: false
             )

    status_reasons =
      for status <- [408, 504] do
        bypass = Bypass.open()
        raw_detail = "provider-detail-must-not-persist-#{status}"

        Bypass.expect_once(bypass, "GET", "/status-#{status}", fn conn ->
          Plug.Conn.resp(conn, status, raw_detail)
        end)

        assert {:error, {:http_status, ^status, ^raw_detail} = reason} =
                 Maraithon.HTTP.get("http://localhost:#{bypass.port}/status-#{status}", [],
                   log_failures?: false
                 )

        {status, reason, raw_detail}
      end

    cases = [
      {:gmail, "gmail_send", bounded_timeout_reason, nil},
      {:slack, "slack_post", transport_reason, "Req.TransportError"},
      {:gmail, "gmail_send", elem(Enum.at(status_reasons, 0), 1),
       elem(Enum.at(status_reasons, 0), 2)},
      {:slack, "slack_post", elem(Enum.at(status_reasons, 1), 1),
       elem(Enum.at(status_reasons, 1), 2)}
    ]

    for {provider, action_type, raw_reason, forbidden_detail} <- cases do
      wrapper =
        {:provider_error, provider, raw_reason,
         "#{provider} is temporarily unavailable. Wait before retrying."}

      assert TelegramAssistant.prepared_action_error_class(raw_reason) == :ambiguous
      assert TelegramAssistant.prepared_action_error_class(wrapper) == :ambiguous

      configure_scripted_executor([{:return, {:error, wrapper}}])

      {:ok, _conversation, action} =
        create_mobile_action(ctx, %{"text" => "send once"},
          action_type: action_type,
          target_type: if(provider == :gmail, do: "gmail_thread", else: "slack_channel")
        )

      assert {:ok, %{prepared_action: unknown}} =
               AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
                 "client_message_id" => Ecto.UUID.generate()
               })

      checkpoint = unknown.payload["_maraithon_execution_error"]
      assert unknown.status == "execution_unknown"
      assert checkpoint["class"] == "ambiguous"
      refute Map.has_key?(checkpoint, "reason")
      refute Map.has_key?(unknown.payload, "_maraithon_execution_token")

      if forbidden_detail do
        refute inspect(unknown.payload) =~ forbidden_detail
      end

      assert scripted_executor_calls() == 1

      assert {:ok, %{prepared_action: still_unknown}} =
               AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
                 "client_message_id" => Ecto.UUID.generate()
               })

      assert still_unknown.status == "execution_unknown"
      assert scripted_executor_calls() == 1
    end
  end

  test "mobile confirm resumes an executed row before considering expiry or stale draft edits",
       ctx do
    {:ok, mobile_conversation} =
      TelegramConversations.create_mobile_thread(ctx.user_id, %{
        "client_thread_id" => Ecto.UUID.generate()
      })

    {:ok, mobile_run} =
      create_run(ctx.user_id, mobile_conversation.chat_id, mobile_conversation.id, "mobile")

    {:ok, action} =
      TelegramAssistant.create_prepared_action(%{
        user_id: ctx.user_id,
        chat_id: mobile_conversation.chat_id,
        conversation_id: mobile_conversation.id,
        run_id: mobile_run.id,
        surface: "mobile",
        action_type: "slack_post",
        target_type: "slack_channel",
        target_id: "C123",
        payload: %{
          "text" => "committed body",
          "_maraithon_execution_result" => %{"message" => "Slack message sent."}
        },
        preview_text: "Post the update",
        status: "executed",
        confirmed_at: DateTime.add(DateTime.utc_now(), -120, :second),
        executed_at: DateTime.add(DateTime.utc_now(), -119, :second),
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    assert {:ok, %{prepared_action: resumed, thread: thread}} =
             AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
               "client_message_id" => Ecto.UUID.generate(),
               "draft_edits" => %{"text" => "stale overwrite"}
             })

    assert resumed.status == "executed"
    assert resumed.payload["text"] == "committed body"

    assert Enum.any?(thread.turns, fn turn ->
             turn.turn_kind == "action_result" and turn.origin_id == action.id
           end)

    assert {:ok, %{prepared_action: still_executed}} =
             AssistantChat.decide_prepared_action(ctx.user_id, action.id, "reject", %{
               "client_message_id" => Ecto.UUID.generate()
             })

    assert still_executed.status == "executed"
    assert Repo.get!(PreparedAction, action.id).status == "executed"
  end

  test "an ambiguous Gmail response is terminal and is never replayed", ctx do
    configure_scripted_executor([{:return, {:error, :timeout}}])

    {:ok, _conversation, action} =
      create_mobile_action(
        ctx,
        %{
          "user_id" => ctx.user_id,
          "to" => "ops@example.com",
          "subject" => "Update",
          "body" => "The update"
        },
        action_type: "gmail_send",
        target_type: "gmail_thread"
      )

    assert {:ok, %{prepared_action: unknown}} =
             AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
               "client_message_id" => Ecto.UUID.generate()
             })

    assert unknown.status == "execution_unknown"
    assert unknown.payload["_maraithon_execution_attempts"] == 1
    assert get_in(unknown.payload, ["_maraithon_execution_error", "class"]) == "ambiguous"
    assert scripted_executor_calls() == 1

    assert {:ok, %{prepared_action: still_unknown}} =
             AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
               "client_message_id" => Ecto.UUID.generate()
             })

    assert still_unknown.status == "execution_unknown"
    assert scripted_executor_calls() == 1
  end

  test "provider success plus a failed local checkpoint becomes execution unknown", ctx do
    configure_scripted_executor([{:return, {:ok, %{"message" => "Gmail accepted it."}}}])

    {:ok, _conversation, action} =
      create_mobile_action(
        ctx,
        %{
          "user_id" => ctx.user_id,
          "to" => "ops@example.com",
          "subject" => "Update",
          "body" => "The update"
        },
        action_type: "gmail_send",
        target_type: "gmail_thread"
      )

    Repo.query!("""
    CREATE FUNCTION maraithon_test_fail_mobile_prepared_executed_write()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.id = '#{action.id}' AND NEW.status = 'executed' THEN
        RAISE EXCEPTION 'injected prepared-action execution checkpoint failure';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER maraithon_test_fail_mobile_prepared_executed_write
    BEFORE UPDATE ON telegram_prepared_actions
    FOR EACH ROW
    EXECUTE FUNCTION maraithon_test_fail_mobile_prepared_executed_write()
    """)

    result =
      try do
        AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
          "client_message_id" => Ecto.UUID.generate()
        })
      after
        Repo.query!(
          "DROP TRIGGER maraithon_test_fail_mobile_prepared_executed_write " <>
            "ON telegram_prepared_actions"
        )

        Repo.query!("DROP FUNCTION maraithon_test_fail_mobile_prepared_executed_write()")
      end

    assert {:ok, %{prepared_action: unknown}} = result
    assert unknown.status == "execution_unknown"
    assert unknown.payload["_maraithon_execution_attempts"] == 1
    refute Map.has_key?(unknown.payload, "_maraithon_execution_token")
    assert scripted_executor_calls() == 1

    assert {:ok, %{prepared_action: still_unknown}} =
             AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
               "client_message_id" => Ecto.UUID.generate()
             })

    assert still_unknown.status == "execution_unknown"
    assert scripted_executor_calls() == 1
  end

  test "project create reconciles a persisted result after its owner observed checkpoint failure",
       ctx do
    {:ok, _conversation, action} =
      create_mobile_action(
        ctx,
        %{
          "user_id" => ctx.user_id,
          "attrs" => %{"name" => "Checkpointed project", "summary" => "Created once"}
        },
        action_type: "project_create",
        target_type: "project"
      )

    Repo.query!("""
    CREATE FUNCTION maraithon_test_fail_project_create_executed_write()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.id = '#{action.id}' AND NEW.status = 'executed' THEN
        RAISE EXCEPTION 'injected project-create execution checkpoint failure';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER maraithon_test_fail_project_create_executed_write
    BEFORE UPDATE ON telegram_prepared_actions
    FOR EACH ROW
    EXECUTE FUNCTION maraithon_test_fail_project_create_executed_write()
    """)

    first_result =
      try do
        TelegramAssistant.confirm_and_execute(action, durable: true)
      after
        Repo.query!(
          "DROP TRIGGER maraithon_test_fail_project_create_executed_write " <>
            "ON telegram_prepared_actions"
        )

        Repo.query!("DROP FUNCTION maraithon_test_fail_project_create_executed_write()")
      end

    assert {:error, %PreparedAction{status: "confirmed"} = retryable, _checkpoint_reason} =
             first_result

    refute Map.has_key?(retryable.payload, "_maraithon_execution_token")

    created_projects = projects_created_for_action(ctx.user_id, action.id)
    assert [created_project] = created_projects

    assert {:ok, %PreparedAction{status: "executed"} = executed, result} =
             TelegramAssistant.confirm_and_execute(retryable, durable: true)

    assert result["message"] == "Created the project."
    assert executed.payload["_maraithon_execution_attempts"] == 2
    assert [reconciled_project] = projects_created_for_action(ctx.user_id, action.id)
    assert reconciled_project.id == created_project.id
  end

  test "frozen payload tampering fails closed before another provider call", ctx do
    configure_scripted_executor([
      {:return, {:error, {:http_error, 503, "provider unavailable"}}},
      {:return, {:ok, %{"message" => "must not run"}}}
    ])

    {:ok, _conversation, action} = create_mobile_action(ctx, %{"text" => "original"})

    assert {:error, {:prepared_action_execution_retryable, :transient}} =
             AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
               "client_message_id" => Ecto.UUID.generate()
             })

    retryable = Repo.get!(PreparedAction, action.id)
    assert is_binary(retryable.payload["_maraithon_confirmed_payload_sha256"])

    retryable
    |> Ecto.Changeset.change(payload: Map.put(retryable.payload, "text", "tampered"))
    |> Repo.update!()

    assert {:ok, %{prepared_action: failed}} =
             AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
               "client_message_id" => Ecto.UUID.generate()
             })

    assert failed.status == "failed"

    assert get_in(failed.payload, ["_maraithon_execution_error", "code"]) ==
             "prepared_action_payload_tampered"

    assert scripted_executor_calls() == 1
  end

  test "frozen draft update instruction cannot be flipped or deleted before retry", ctx do
    for mutation <- [:flip, :delete] do
      configure_scripted_executor([
        {:return, {:error, {:http_error, 503, "provider unavailable"}}},
        {:return, {:ok, %{"message" => "must not run"}}}
      ])

      {:ok, _conversation, action} =
        create_mobile_action(
          ctx,
          %{
            "user_id" => ctx.user_id,
            "draft_id" => "draft-#{mutation}",
            "body" => "frozen body",
            "_maraithon_update_draft_before_send" => true
          },
          action_type: "gmail_draft_send",
          target_type: "gmail_thread"
        )

      assert {:error, {:prepared_action_execution_retryable, :transient}} =
               AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
                 "client_message_id" => Ecto.UUID.generate()
               })

      retryable = Repo.get!(PreparedAction, action.id)

      tampered_payload =
        case mutation do
          :flip -> Map.put(retryable.payload, "_maraithon_update_draft_before_send", false)
          :delete -> Map.delete(retryable.payload, "_maraithon_update_draft_before_send")
        end

      retryable
      |> Ecto.Changeset.change(payload: tampered_payload)
      |> Repo.update!()

      assert {:ok, %{prepared_action: failed}} =
               AssistantChat.decide_prepared_action(ctx.user_id, action.id, "confirm", %{
                 "client_message_id" => Ecto.UUID.generate()
               })

      assert failed.status == "failed"

      assert get_in(failed.payload, ["_maraithon_execution_error", "code"]) ==
               "prepared_action_payload_tampered"

      assert scripted_executor_calls() == 1
    end
  end

  test "concurrent Telegram callbacks reserve one result send before dispatch", ctx do
    {:ok, action} =
      create_action(ctx,
        status: "executed",
        payload: %{
          "_maraithon_execution_result" => %{"message" => "Completed once."}
        }
      )

    parent = self()

    capture_config =
      Application.get_env(:maraithon, :capturing_telegram, [])
      |> Keyword.put(:send_result, fn _event ->
        send(parent, {:prepared_result_send_started, self()})

        receive do
          :release_prepared_result_send -> :ok
        after
          2_000 -> {:error, :result_send_test_timeout}
        end
      end)

    Application.put_env(:maraithon, :capturing_telegram, capture_config)

    event = fn callback_id ->
      %{
        type: "callback_query",
        source: "telegram",
        data: %{
          chat_id: ctx.chat_id,
          message_id: "result-source",
          callback_id: callback_id,
          data: "tgact:#{action.id}:confirm"
        }
      }
    end

    first =
      Task.async(fn ->
        InsightNotifications.process_telegram_event_durable(event.("result-callback-1"))
      end)

    assert_receive {:prepared_result_send_started, sender_pid}, 1_000

    second =
      Task.async(fn ->
        InsightNotifications.process_telegram_event_durable(event.("result-callback-2"))
      end)

    _ = Task.await(second, 1_000)
    refute_receive {:prepared_result_send_started, _other_sender}, 200

    send(sender_pid, :release_prepared_result_send)
    _ = Task.await(first, 2_000)

    assert count_telegram_events(:send) == 1
    delivered = Repo.get!(PreparedAction, action.id)
    assert delivered.payload["_maraithon_result_delivery_state"] == "delivered"
    assert delivered.payload["_maraithon_result_delivery_attempts"] == 1
  end

  defp configure_scripted_executor(script, extra_config \\ []) do
    Application.put_env(:maraithon, :prepared_action_executor_test_pid, self())

    config =
      Application.get_env(:maraithon, :telegram_assistant, [])
      |> Keyword.put(
        :prepared_action_executor,
        Maraithon.TelegramAssistant.PreparedActionStateTest.ScriptedExecutor
      )
      |> Keyword.merge(extra_config)

    Application.put_env(:maraithon, :telegram_assistant, config)
    Agent.update(:prepared_action_scripted_executor, &%{&1 | script: script, calls: 0})
  end

  defp scripted_executor_calls do
    Agent.get(:prepared_action_scripted_executor, & &1.calls)
  end

  defp create_mobile_action(ctx, payload, opts \\ []) do
    with {:ok, conversation} <-
           TelegramConversations.create_mobile_thread(ctx.user_id, %{
             "client_thread_id" => Ecto.UUID.generate()
           }),
         {:ok, run} <-
           create_run(ctx.user_id, conversation.chat_id, conversation.id, "mobile"),
         {:ok, action} <-
           TelegramAssistant.create_prepared_action(%{
             user_id: ctx.user_id,
             chat_id: conversation.chat_id,
             conversation_id: conversation.id,
             run_id: run.id,
             surface: "mobile",
             action_type: Keyword.get(opts, :action_type, "slack_post"),
             target_type: Keyword.get(opts, :target_type, "slack_channel"),
             target_id: Keyword.get(opts, :target_id, "C123"),
             payload: payload,
             preview_text: "Post the update",
             status: "awaiting_confirmation",
             expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
           }) do
      {:ok, conversation, action}
    end
  end

  defp create_action(ctx, opts) do
    TelegramAssistant.create_prepared_action(%{
      user_id: ctx.user_id,
      chat_id: ctx.chat_id,
      conversation_id: ctx.conversation.id,
      run_id: ctx.run.id,
      surface: "telegram",
      action_type: Keyword.get(opts, :action_type, "project_update"),
      target_type: "project",
      target_id: Keyword.get(opts, :target_id, Ecto.UUID.generate()),
      payload:
        Keyword.get(opts, :payload, %{
          "project_id" => Ecto.UUID.generate(),
          "attrs" => %{"summary" => "updated"}
        }),
      preview_text: "Update project",
      status: Keyword.get(opts, :status, "awaiting_confirmation"),
      expires_at: Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 600, :second))
    })
  end

  defp create_run(user_id, chat_id, conversation_id, surface) do
    now = DateTime.utc_now()

    TelegramAssistant.start_run(%{
      user_id: user_id,
      chat_id: chat_id,
      conversation_id: conversation_id,
      surface: surface,
      trigger_type: "inbound_message",
      status: "completed",
      model_provider: "test",
      model_name: "test",
      prompt_snapshot: %{},
      result_summary: %{},
      started_at: now,
      finished_at: now
    })
  end

  defp projects_created_for_action(user_id, prepared_action_id) do
    user_id
    |> then(&Projects.list_projects(user_id: &1))
    |> Enum.filter(fn project ->
      get_in(project.metadata || %{}, ["_maraithon_prepared_action_id"]) == prepared_action_id
    end)
  end

  defp count_telegram_events(type) do
    Agent.get(:capturing_telegram_recorder, fn events ->
      Enum.count(events, &(&1.type == type))
    end)
  end
end
