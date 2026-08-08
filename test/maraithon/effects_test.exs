defmodule Maraithon.EffectsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Effects
  alias Maraithon.Effects.Effect
  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.LLM

  setup do
    {:ok, agent} =
      Agents.create_agent(%{behavior: "prompt_agent", config: %{}, status: "running"})

    %{agent_id: agent.id}
  end

  describe "request/5" do
    test "creates pending effect", %{agent_id: agent_id} do
      {:ok, effect_id} = Effects.request(agent_id, :tool_call, "read_file", %{path: "/tmp/test"})

      effect = Repo.get!(Effect, effect_id)
      assert effect.agent_id == agent_id
      assert effect.effect_type == "tool_call"
      assert effect.params["args"]["path"] == "/tmp/test"
      assert effect.params["tool"] == "read_file"
      refute Map.has_key?(effect.params, "path")
      assert effect.status == "pending"
    end

    test "derives a trusted LLM execution lane instead of accepting caller metadata", %{
      agent_id: agent_id
    } do
      params = %{
        "__maraithon_execution_lane" => "not-a-lane",
        "messages" => [%{"role" => "user", "content" => "Classify safely"}],
        "max_tokens" => 100
      }

      {:ok, effect_id} = Effects.request(agent_id, :llm_call, nil, params)

      effect = Repo.get!(Effect, effect_id)

      assert effect.params["__maraithon_execution_lane"] ==
               to_string(LLM.execution_bucket(params))
    end

    test "uses provided effect_id", %{agent_id: agent_id} do
      custom_id = Ecto.UUID.generate()

      {:ok, effect_id} =
        Effects.request(agent_id, :test, nil, %{}, %{effect_id: custom_id})

      assert effect_id == custom_id
    end

    test "uses provided idempotency_key", %{agent_id: agent_id} do
      key = Ecto.UUID.generate()

      {:ok, effect_id} =
        Effects.request(agent_id, :test, nil, %{}, %{idempotency_key: key})

      effect = Repo.get!(Effect, effect_id)
      assert effect.idempotency_key == key
    end

    test "rejects unbounded or non-JSON params before persistence", %{agent_id: agent_id} do
      assert {:error, :invalid_effect_params} =
               Effects.request(agent_id, :tool_call, "http_get", %{
                 "body" => String.duplicate("x", 128_001)
               })

      assert {:error, :invalid_effect_params} =
               Effects.request(agent_id, :tool_call, "http_get", %{"callback" => fn -> :ok end})

      assert {:error, :invalid_effect_params} =
               Effects.request(agent_id, :tool_call, "http_get", %{
                 "url" => "https://example.com/" <> <<0>>
               })

      assert {:error, :invalid_effect_params} =
               Effects.request(agent_id, :llm_call, nil, DateTime.utc_now())

      assert Repo.aggregate(Effect, :count) == 0
    end

    test "rejects recursive JSON key aliases before persistence", %{agent_id: agent_id} do
      params = %{
        "messages" => [
          %{:role => "system", "role" => "user", "content" => "must not collapse"}
        ]
      }

      assert {:error, :invalid_effect_params} =
               Effects.request(agent_id, :llm_call, nil, params)

      assert Repo.aggregate(Effect, :count) == 0
    end

    test "does not include tool key when tool_name is nil", %{agent_id: agent_id} do
      {:ok, effect_id} = Effects.request(agent_id, :send_message, nil, %{text: "hello"})

      effect = Repo.get!(Effect, effect_id)
      refute Map.has_key?(effect.params, "tool")
      assert effect.params["text"] == "hello"
    end

    test "rejects non-map, oversized, and key-colliding results" do
      assert {:error, :invalid_effect_result} = Effects.prepare_result(fn -> :ok end)

      assert {:error, :invalid_effect_result} =
               Effects.prepare_result(%{"content" => String.duplicate("x", 256_001)})

      assert {:error, :invalid_effect_result} =
               Effects.prepare_result(%{:status => "ok", "status" => "failed"})

      assert {:error, :invalid_effect_result} =
               Effects.prepare_result(%{"content" => "contains" <> <<0>> <> "nul"})

      assert {:error, :invalid_effect_result} = Effects.prepare_result(DateTime.utc_now())
    end
  end

  describe "mixed-version owner stamping" do
    test "database stamps an old writer's active effect with the persisted owner" do
      {:ok, user} =
        Accounts.get_or_create_user_by_email(
          "effect-owner-#{System.unique_integer([:positive])}@example.com"
        )

      {:ok, agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{},
          status: "running",
          user_id: user.id
        })

      legacy_effect =
        %Effect{}
        |> Effect.changeset(%{
          id: Ecto.UUID.generate(),
          agent_id: agent.id,
          idempotency_key: Ecto.UUID.generate(),
          effect_type: "tool_call",
          params: %{"tool" => "time", "args" => %{}},
          status: "pending"
        })
        |> Repo.insert!()
        |> Repo.reload!()

      assert legacy_effect.owner_user_id == user.id
    end
  end

  describe "cancel_active_for_agent/2" do
    test "cancels only the agent's pending and claimed effects", %{agent_id: agent_id} do
      {:ok, other_agent} = Agents.create_agent(%{behavior: "prompt_agent", config: %{}})

      {:ok, pending_id} = Effects.request(agent_id, :tool_call, "time", %{})
      {:ok, claimed_id} = Effects.request(agent_id, :llm_call, nil, %{})
      {:ok, completed_id} = Effects.request(agent_id, :tool_call, "time", %{})
      {:ok, failed_id} = Effects.request(agent_id, :tool_call, "time", %{})
      {:ok, cancelled_id} = Effects.request(agent_id, :tool_call, "time", %{})
      {:ok, other_pending_id} = Effects.request(other_agent.id, :tool_call, "time", %{})

      claimed_at = DateTime.utc_now()
      retry_after = DateTime.add(claimed_at, 60, :second)

      Repo.update_all(
        from(effect in Effect, where: effect.id == ^pending_id),
        set: [retry_after: retry_after]
      )

      Repo.update_all(
        from(effect in Effect, where: effect.id == ^claimed_id),
        set: [
          status: "claimed",
          claimed_by: "old@node",
          claimed_at: claimed_at,
          retry_after: retry_after
        ]
      )

      Repo.update_all(
        from(effect in Effect, where: effect.id == ^completed_id),
        set: [status: "completed", result: %{ok: true}]
      )

      Repo.update_all(
        from(effect in Effect, where: effect.id == ^failed_id),
        set: [status: "failed", error: "original failure"]
      )

      Repo.update_all(
        from(effect in Effect, where: effect.id == ^cancelled_id),
        set: [status: "cancelled", error: "already cancelled"]
      )

      assert {:ok, 2} =
               Effects.cancel_active_for_agent(
                 agent_id,
                 "agent_recovered_without_effect_continuation"
               )

      pending = Repo.get!(Effect, pending_id)
      assert pending.status == "cancelled"
      assert pending.claimed_by == nil
      assert pending.claimed_at == nil
      assert pending.retry_after == nil
      assert pending.error == "agent_recovered_without_effect_continuation"

      claimed = Repo.get!(Effect, claimed_id)
      assert claimed.status == "failed"
      assert claimed.error == "effect_outcome_ambiguous"
      assert claimed.result_envelope["status"] == "error"
      assert claimed.claimed_by == nil
      assert claimed.claimed_at == nil
      assert claimed.retry_after == nil

      completed = Repo.get!(Effect, completed_id)
      assert completed.status == "completed"
      assert completed.result == %{"ok" => true}

      failed = Repo.get!(Effect, failed_id)
      assert failed.status == "failed"
      assert failed.error == "original failure"

      cancelled = Repo.get!(Effect, cancelled_id)
      assert cancelled.status == "cancelled"
      assert cancelled.error == "already cancelled"

      assert Repo.get!(Effect, other_pending_id).status == "pending"
      assert {:ok, 0} = Effects.cancel_active_for_agent(agent_id)
    end

    test "keeps an unfinished cancellation discoverable across reason changes", %{
      agent_id: agent_id
    } do
      {:ok, effect_id} = Effects.request(agent_id, :llm_call, nil, %{})
      claimed_at = DateTime.utc_now()

      Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
        set: [status: "claimed", claimed_by: "claim@node", claimed_at: claimed_at]
      )

      assert {:ok, first} =
               Effects.begin_cancel_active_for_agent(agent_id, "first_cancellation_reason")

      assert [%{id: ^effect_id, claimed_by: "claim@node", claimed_at: ^claimed_at}] =
               first.claims

      assert Repo.get!(Effect, effect_id).status == "cancelling"

      assert {:ok, second} =
               Effects.begin_cancel_active_for_agent(agent_id, "different_retry_reason")

      assert second.claims == first.claims

      assert {:ok, %{ambiguous: 1}} =
               Effects.finish_cancel_active_for_agent(agent_id, second.claims)

      terminal = Repo.get!(Effect, effect_id)
      assert terminal.status == "failed"
      assert terminal.error == "effect_outcome_ambiguous"
    end
  end

  describe "check_idempotency/1" do
    test "returns :not_found when no matching effect" do
      assert Effects.check_idempotency(Ecto.UUID.generate()) == :not_found
    end

    test "returns cached result for completed effect", %{agent_id: agent_id} do
      key = Ecto.UUID.generate()

      %Effect{}
      |> Effect.changeset(%{
        id: Ecto.UUID.generate(),
        agent_id: agent_id,
        idempotency_key: key,
        effect_type: "test",
        status: "completed",
        result: %{success: true}
      })
      |> Repo.insert!()

      assert {:cached, %{"success" => true}} = Effects.check_idempotency(key)
    end

    test "returns cached error for failed effect", %{agent_id: agent_id} do
      key = Ecto.UUID.generate()

      %Effect{}
      |> Effect.changeset(%{
        id: Ecto.UUID.generate(),
        agent_id: agent_id,
        idempotency_key: key,
        effect_type: "test",
        status: "failed",
        error: "Something went wrong"
      })
      |> Repo.insert!()

      assert {:cached_error, "Something went wrong"} = Effects.check_idempotency(key)
    end

    test "returns :not_found for pending effect", %{agent_id: agent_id} do
      key = Ecto.UUID.generate()

      %Effect{}
      |> Effect.changeset(%{
        id: Ecto.UUID.generate(),
        agent_id: agent_id,
        idempotency_key: key,
        effect_type: "test",
        status: "pending"
      })
      |> Repo.insert!()

      assert Effects.check_idempotency(key) == :not_found
    end
  end

  describe "run linkage" do
    test "accepts only a step owned by the same agent and running run", %{agent_id: agent_id} do
      agent = Repo.get!(Maraithon.Agents.Agent, agent_id)

      {:ok, other_agent} =
        Agents.create_agent(%{behavior: "prompt_agent", config: %{}, status: "running"})

      {:ok, run} =
        Agents.start_runtime_agent_run(agent, %{
          trigger_type: "message",
          trigger: %{"type" => "message"}
        })

      {:ok, step} =
        Agents.record_agent_run_step(run.id, agent.id, %{
          step_type: "llm_call",
          status: "requested"
        })

      {:ok, other_run} =
        Agents.start_runtime_agent_run(other_agent, %{
          trigger_type: "message",
          trigger: %{"type" => "message"}
        })

      {:ok, other_step} =
        Agents.record_agent_run_step(other_run.id, other_agent.id, %{
          step_type: "llm_call",
          status: "requested"
        })

      params = %{"messages" => [%{"role" => "user", "content" => "linked"}]}

      assert {:ok, _effect_id} =
               Effects.request_prepared(agent.id, "llm_call", nil, params, %{
                 agent_run_id: run.id,
                 agent_run_step_id: step.id
               })

      assert {:error, :invalid_effect_run_context} =
               Effects.request_prepared(agent.id, "llm_call", nil, params, %{
                 agent_run_id: other_run.id,
                 agent_run_step_id: other_step.id
               })

      Repo.update_all(
        from(stored_step in Maraithon.Agents.AgentRunStep, where: stored_step.id == ^step.id),
        set: [agent_id: other_agent.id]
      )

      assert {:error, :invalid_effect_run_context} =
               Effects.request_prepared(agent.id, "llm_call", nil, params, %{
                 agent_run_id: run.id,
                 agent_run_step_id: step.id
               })
    end
  end

  describe "terminal result delivery" do
    test "leases retries once, backs off, and stops after durable acknowledgement", %{
      agent_id: agent_id
    } do
      agent = Repo.get!(Maraithon.Agents.Agent, agent_id)
      {:ok, _agent} = Agents.update_agent(agent, %{status: "running"})

      effect =
        %Effect{}
        |> Effect.changeset(%{
          id: Ecto.UUID.generate(),
          agent_id: agent_id,
          idempotency_key: Ecto.UUID.generate(),
          effect_type: "llm_call",
          status: "completed",
          result: %{"content" => "done"},
          result_envelope: %{"status" => "ok", "version" => 1}
        })
        |> Repo.insert!()

      assert [listed] = Effects.list_terminal_results_for_dispatch()
      assert listed.id == effect.id

      assert {:ok, true} = Effects.reserve_terminal_result_dispatch(effect)
      reserved = Repo.get!(Effect, effect.id)
      assert reserved.result_dispatch_attempts == 1
      assert %DateTime{} = reserved.result_dispatched_at
      assert %DateTime{} = reserved.result_dispatch_after

      assert {:ok, false} = Effects.reserve_terminal_result_dispatch(reserved)

      Repo.update_all(
        from(stored in Effect,
          where: stored.id == ^effect.id,
          update: [set: [result_dispatch_after: fragment("NOW() - INTERVAL '1 second'")]]
        ),
        []
      )

      retryable = Repo.get!(Effect, effect.id)
      assert {:ok, true} = Effects.reserve_terminal_result_dispatch(retryable)
      assert Repo.get!(Effect, effect.id).result_dispatch_attempts == 2

      assert {:ok, 1} = Effects.acknowledge_terminal_result(effect.id, agent_id)
      assert Effects.get_terminal_result(effect.id, agent_id) == nil
      assert Effects.list_terminal_results_for_dispatch() == []
    end

    test "excludes pre-outbox legacy rows and stopped agents", %{agent_id: agent_id} do
      legacy =
        %Effect{}
        |> Effect.changeset(%{
          id: Ecto.UUID.generate(),
          agent_id: agent_id,
          idempotency_key: Ecto.UUID.generate(),
          effect_type: "llm_call",
          status: "completed",
          result: %{"content" => "legacy"}
        })
        |> Repo.insert!()

      pending_delivery =
        %Effect{}
        |> Effect.changeset(%{
          id: Ecto.UUID.generate(),
          agent_id: agent_id,
          idempotency_key: Ecto.UUID.generate(),
          effect_type: "llm_call",
          status: "failed",
          error: "effect_outcome_ambiguous",
          result_envelope: %{
            "status" => "error",
            "reason" => %{"type" => "atom", "value" => "effect_outcome_ambiguous"}
          }
        })
        |> Repo.insert!()

      agent = Repo.get!(Maraithon.Agents.Agent, agent_id)
      {:ok, _agent} = Agents.update_agent(agent, %{status: "stopped"})

      assert Effects.list_terminal_results_for_dispatch() == []
      assert Effects.get_terminal_result(legacy.id, agent_id) == nil
      assert %Effect{id: id} = Effects.get_terminal_result(pending_delivery.id, agent_id)
      assert id == pending_delivery.id
    end
  end
end
