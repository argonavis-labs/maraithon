defmodule Maraithon.Todos.OutcomeWorkflowTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.{Accounts, AssistantChat, ConnectedAccounts, TelegramAssistant, Todos}
  alias Maraithon.Crm.Person
  alias Maraithon.TelegramAssistant.{ActionReconciliation, PreparedAction}
  alias Maraithon.Todos.{ActionHandoff, Todo, Workflow}

  @outcome "Kent, Christina and Michael have the meeting"

  setup do
    original = Application.get_env(:maraithon, :telegram_assistant, [])
    observers = Application.get_env(:maraithon, ActionReconciliation, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.put(
        original,
        :prepared_action_executor,
        Maraithon.TestSupport.ActionReconciliationExecutor
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :telegram_assistant, original)
      Application.put_env(:maraithon, ActionReconciliation, observers)
      Application.delete_env(:maraithon, :action_reconciliation_executor)
    end)

    user_id = "controlled-meeting-#{System.unique_integer([:positive])}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _} =
      ConnectedAccounts.upsert_manual(user_id, "google", %{
        external_account_id: "controlled-mailbox"
      })

    {:ok, conversation} = AssistantChat.create_thread(user_id, %{"title" => "Controlled meeting"})

    {:ok, run} =
      TelegramAssistant.start_run(%{
        user_id: user_id,
        chat_id: conversation.chat_id,
        conversation_id: conversation.id,
        surface: "mobile",
        trigger_type: "inbound_message",
        status: "completed",
        started_at: DateTime.utc_now(),
        model_provider: "test",
        model_name: "test",
        prompt_snapshot: %{},
        result_summary: %{}
      })

    todo =
      Repo.insert!(%Todo{
        user_id: user_id,
        owner_user_id: user_id,
        source: "controlled_outcome",
        kind: "general",
        title: @outcome,
        summary: "Synthetic participants and provider responses",
        next_action: "Coordinate availability",
        dedupe_key: Ecto.UUID.generate(),
        status: "open"
      })

    people =
      Map.new(["Christina", "Michael"], fn name ->
        {name, Repo.insert!(%Person{user_id: user_id, display_name: name})}
      end)

    %{
      user_id: user_id,
      conversation: conversation,
      run: run,
      todo: todo,
      people: people,
      supervisor: start_supervised!({Task.Supervisor, []})
    }
  end

  for interrupted? <- [false, true] do
    @interrupted interrupted?
    test "meeting handoffs preserve the outcome, interrupted=#{interrupted?}", ctx do
      interrupted? = @interrupted
      assert_state(ctx.todo, "you_own", "Your move", 0)

      todo = move!(ctx.todo, "working", %{"kind" => "user"}, "Ask Christina for availability")
      assert_state(todo, "working", "Your move", 1)

      # Preparing a supporting email does not transfer ownership or close the goal.
      first = mail_action!(ctx, todo, "Christina")
      assert_state(reload_todo(todo), "working", "Your move", 1)
      assert first.status == "awaiting_confirmation"

      if interrupted? do
        parent = self()

        executor(fn action ->
          send(parent, {:mutation, action.id})
          {:error, :timeout}
        end)

        worker =
          Task.Supervisor.async_nolink(ctx.supervisor, fn ->
            result = TelegramAssistant.confirm_and_execute(reload_action(first), durable: true)
            send(parent, {:lost_response, result})
            receive do: (:finish -> :ok)
          end)

        assert_receive {:lost_response, {:error, unknown, _, :manual_reconciliation}}, 5_000
        assert unknown.status == "execution_unknown"
        assert_receive {:mutation, id} when id == first.id
        assert_state(reload_todo(todo), "working", "Your move", 1)

        Process.exit(worker.pid, :kill)
        assert_receive {:DOWN, ref, :process, _, :killed} when ref == worker.ref

        # A fresh worker only has the durable ID. A disconnected mailbox cannot
        # prove delivery and must neither resend nor hand the ball to Christina.
        Application.put_env(:maraithon, ActionReconciliation,
          gmail_request: fn _, _ -> {:error, :reauth_required} end
        )

        assert {:pending, _} = fresh_reconcile(ctx, first.id)
        assert_state(reload_todo(todo), "working", "Your move", 1)

        gmail_receipt(first)
        assert {:ok, _, :executed} = fresh_reconcile(ctx, first.id)
        refute_received {:mutation, _}
      else
        succeed(ctx, first)
      end

      todo = reload_todo(todo)
      assert_state(todo, "they_own", "Christina’s move", 2)
      assert todo.workflow["owner"]["id"] == ctx.people["Christina"].id
      assert reload_action(first).workflow_handoff_state == "applied"

      # Duplicate approval and late receipt replay have the same identity.
      executor(fn _ -> flunk("a completed email was sent twice") end)

      assert {:ok, _, _, :already_executed} =
               TelegramAssistant.confirm_and_execute(reload_action(first), durable: true)

      ActionHandoff.recover_for_user(ctx.user_id)
      assert_state(reload_todo(todo), "they_own", "Christina’s move", 2)

      todo =
        move!(todo, "you_own", %{"kind" => "user"}, "Offer Christina's time to Michael", %{
          "reason" => "Controlled source receipt: Christina confirms Tuesday at 10."
        })

      assert_state(todo, "you_own", "Your move", 3)

      second = mail_action!(ctx, todo, "Michael")
      succeed(ctx, second)
      todo = reload_todo(todo)
      assert_state(todo, "they_own", "Michael’s move", 4)

      # A delayed acknowledgement from the first handoff cannot overwrite Michael.
      ActionHandoff.apply_safely(reload_action(first))
      assert_state(reload_todo(todo), "they_own", "Michael’s move", 4)

      todo =
        move!(todo, "you_own", %{"kind" => "user"}, "Confirm the time and book the meeting", %{
          "reason" => "Controlled source receipt: Michael accepts Tuesday at 10."
        })

      assert_state(todo, "you_own", "Your move", 5)

      booking =
        action!(
          ctx,
          todo,
          "calendar_create_event",
          %{
            "title" => @outcome,
            "description" => "Controlled meeting agenda",
            "start_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3_600)),
            "end_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 7_200)),
            "timezone" => "UTC"
          },
          "working",
          %{"kind" => "user"},
          "Attend the meeting"
        )

      succeed(ctx, booking)
      todo = reload_todo(todo)
      assert_state(todo, "working", "Your move", 6)

      attrs = transition(todo, "done", %{"kind" => "user"}, "Meeting completed")

      assert {:error, :outcome_not_confirmed} =
               Todos.transition_workflow(ctx.user_id, todo.id, attrs)

      assert_state(reload_todo(todo), "working", "Your move", 6)

      # This is explicit synthetic user confirmation, not an inference from a
      # sent email, a calendar booking, or the passage of the meeting's end time.
      {:ok, finished} =
        Todos.transition_workflow(
          ctx.user_id,
          todo.id,
          Map.merge(attrs, %{
            "outcome_confirmed" => true,
            "reason" =>
              "Controlled user confirmation: all three attended and completed the meeting."
          }), actor_type: "user", actor_label: "Kent")

      assert_state(finished, "done", "Owner: You", 7)
      assert finished.status == "done"
      assert finished.closed_at
    end
  end

  test "waiting dates return follow-up ownership without claiming the meeting happened", ctx do
    due = DateTime.add(DateTime.utc_now(), -60)

    todo =
      move!(ctx.todo, "waiting", %{"kind" => "user"}, "Check whether Michael has replied", %{
        "waiting_until" => DateTime.to_iso8601(due)
      })

    assert_state(todo, "waiting", "You own follow-up", 1)
    Todos.review_waiting_workflows(ctx.user_id, DateTime.utc_now())
    assert_state(reload_todo(todo), "you_own", "Your move", 2)
  end

  test "stale approvals and another user's person cannot take ownership", ctx do
    todo = move!(ctx.todo, "working", %{"kind" => "user"}, "Coordinate with Christina")
    action = mail_action!(ctx, todo, "Christina")
    newer = move!(todo, "they_own", person(ctx, "Michael"), "Michael proposes a time")
    succeed(ctx, action)
    assert_state(reload_todo(newer), "they_own", "Michael’s move", 2)
    assert reload_action(action).workflow_handoff_state == "superseded"

    other_id = "other-#{System.unique_integer([:positive])}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(other_id)
    stranger = Repo.insert!(%Person{user_id: other_id, display_name: "Christina"})

    assert {:error, :invalid_workflow_owner} =
             Todos.transition_workflow(
               ctx.user_id,
               todo.id,
               transition(newer, "they_own", %{"kind" => "person", "id" => stranger.id}, "Reply")
             )

    attrs = transition(newer, "you_own", %{"kind" => "user"}, "Confirm time")
    assert {:ok, changed} = Todos.transition_workflow(ctx.user_id, todo.id, attrs)
    assert {:ok, replayed} = Todos.transition_workflow(ctx.user_id, todo.id, attrs)
    assert changed.workflow == replayed.workflow

    assert {:error, :workflow_request_conflict} =
             Todos.transition_workflow(
               ctx.user_id,
               todo.id,
               Map.put(attrs, "next_action", "A conflicting action")
             )

    assert {:error, :stale_workflow} =
             Todos.transition_workflow(
               ctx.user_id,
               todo.id,
               Map.put(attrs, "request_id", Ecto.UUID.generate())
             )
  end

  defp assert_state(todo, state, ball, revision) do
    workflow = Workflow.current(todo)
    assert workflow["state"] == state
    assert workflow["revision"] == revision
    assert workflow["outcome"] == @outcome
    assert Workflow.ball_label(workflow) == ball
    assert is_binary(workflow["owner"]["id"])
    assert is_binary(workflow["next_action"])
    assert MaraithonWeb.MobileJSON.todo(todo, related_people_by_todo_id: %{}).workflow == workflow
    assert Todos.serialize_for_prompt(todo).workflow == workflow
    if state != "done", do: assert(todo.status == "open" and is_nil(todo.closed_at))
  end

  defp transition(todo, state, owner, next) do
    %{
      "state" => state,
      "owner" => owner,
      "next_action" => next,
      "outcome" => @outcome,
      "reason" => "Controlled scenario instruction",
      "expected_revision" => Workflow.current(todo)["revision"],
      "request_id" => Ecto.UUID.generate()
    }
  end

  defp move!(todo, state, owner, next, extra \\ %{}) do
    {:ok, updated} =
      Todos.transition_workflow(
        todo.user_id,
        todo.id,
        Map.merge(transition(todo, state, owner, next), extra),
        actor_type: "user",
        actor_label: "Kent"
      )

    updated
  end

  defp mail_action!(ctx, todo, name) do
    action!(
      ctx,
      todo,
      "gmail_send",
      %{
        "to" => String.downcase(name) <> "@example.invalid",
        "subject" => "Meeting time",
        "body" => "Does Tuesday at 10 work?"
      },
      "they_own",
      person(ctx, name),
      "#{name} confirms availability"
    )
  end

  defp action!(ctx, todo, type, payload, state, owner, next) do
    {:ok, payload} =
      ActionHandoff.prepare(
        ctx.user_id,
        type,
        Map.merge(payload, %{
          "user_id" => ctx.user_id,
          "todo_id" => todo.id,
          "keep_todo_open" => true,
          "workflow_transition" => transition(todo, state, owner, next)
        })
      )

    {:ok, action} =
      TelegramAssistant.create_prepared_action(%{
        user_id: ctx.user_id,
        chat_id: ctx.conversation.chat_id,
        conversation_id: ctx.conversation.id,
        run_id: ctx.run.id,
        surface: "mobile",
        action_type: type,
        target_type: "controlled",
        target_id: "controlled",
        payload: payload,
        preview_text: "Controlled scenario action",
        status: "awaiting_confirmation",
        expires_at: DateTime.add(DateTime.utc_now(), 600)
      })

    action
  end

  defp succeed(_ctx, action) do
    executor(fn current -> {:ok, %{"id" => "controlled-" <> current.id}} end)

    assert {:ok, _, _} =
             TelegramAssistant.confirm_and_execute(reload_action(action), durable: true)
  end

  defp fresh_reconcile(ctx, id) do
    Task.Supervisor.async_nolink(ctx.supervisor, fn ->
      TelegramAssistant.reconcile_prepared_action(reload_action(%{id: id}))
    end)
    |> Task.await(5_000)
  end

  defp gmail_receipt(action) do
    action = reload_action(action)

    mail = %{
      "id" => "controlled-" <> action.id,
      "labelIds" => ["SENT"],
      "payload" => %{
        "headers" => [
          %{"name" => "Message-ID", "value" => ActionReconciliation.message_id(action)},
          %{"name" => "To", "value" => action.payload["to"]},
          %{"name" => "Subject", "value" => action.payload["subject"]}
        ]
      }
    }

    Application.put_env(:maraithon, ActionReconciliation,
      gmail_request: fn _, path ->
        if String.contains?(path, "/messages?"),
          do: {:ok, %{"messages" => [%{"id" => mail["id"]}]}},
          else: {:ok, mail}
      end
    )
  end

  defp person(ctx, name), do: %{"kind" => "person", "id" => ctx.people[name].id}
  defp executor(fun), do: Application.put_env(:maraithon, :action_reconciliation_executor, fun)
  defp reload_todo(todo), do: Todos.get_for_user(todo.user_id, todo.id)

  defp reload_action(action),
    do: Repo.get!(PreparedAction, action.id) |> PreparedAction.hydrate_payload()
end
