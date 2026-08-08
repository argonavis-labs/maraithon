defmodule Maraithon.EffectsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Effects
  alias Maraithon.Effects.Effect
  alias Maraithon.Agents

  setup do
    {:ok, agent} = Agents.create_agent(%{behavior: "prompt_agent", config: %{}})
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

      for effect_id <- [pending_id, claimed_id] do
        effect = Repo.get!(Effect, effect_id)
        assert effect.status == "cancelled"
        assert effect.claimed_by == nil
        assert effect.claimed_at == nil
        assert effect.retry_after == nil
        assert effect.error == "agent_recovered_without_effect_continuation"
      end

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
end
