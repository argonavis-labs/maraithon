defmodule Maraithon.Behaviors.ManifestAgentTest do
  use ExUnit.Case, async: true

  alias Maraithon.Behaviors.{AIChiefOfStaff, ManifestAgent}

  test "requests a model call from a hydrated manifest and markdown skill context" do
    state =
      ManifestAgent.init(%{
        "_harness_manifest" => %{
          model: "gpt-5.4",
          intelligence: "high",
          system_prompt: "You are a package-defined assistant.",
          goals: ["Answer the operator"],
          skills: [
            %{
              name: "Test Skill",
              instructions: "Use connected context and answer succinctly."
            }
          ],
          tool_allowlist: ["llm.complete"],
          mcp_allowlist: [],
          required_connectors: %{}
        }
      })

    context = %{
      agent_id: Ecto.UUID.generate(),
      user_id: nil,
      timestamp: DateTime.utc_now(),
      budget: %{llm_calls: 5, tool_calls: 5},
      recent_events: [],
      user_memory: %{},
      last_message: "What matters today?",
      last_message_metadata: %{"correlation_id" => "corr-1"},
      last_message_id: "msg-1",
      trigger: %{type: :message},
      event: nil
    }

    assert {:effect, {:llm_call, params}, _state} = ManifestAgent.handle_wakeup(state, context)
    assert params["model"] == "gpt-5.4"
    assert params["reasoning_effort"] == "high"
    assert [%{"role" => "system"}, %{"role" => "user"}] = params["messages"]
    assert hd(params["messages"])["content"] =~ "Test Skill"
  end

  test "emits an explicit error when model or intelligence is missing" do
    state = ManifestAgent.init(%{"_harness_manifest" => %{system_prompt: "No model"}})

    assert {:emit, {:agent_error, payload}, _state} =
             ManifestAgent.handle_wakeup(state, %{last_message_metadata: %{}})

    assert payload.error == "That automation is missing model configuration."
  end

  test "turns structured model tool requests into allowlisted tool effects" do
    state =
      ManifestAgent.init(%{
        "_harness_manifest" => %{
          model: "gpt-5.4",
          intelligence: "high",
          system_prompt: "Use tools when needed.",
          goals: [],
          skills: [],
          tool_allowlist: ["calendar.list"]
        }
      })

    response = %{content: Jason.encode!(%{tool_call: %{name: "calendar.list", args: %{}}})}

    assert {:effect, {:tool_call, "calendar.list", %{}}, next_state} =
             ManifestAgent.handle_effect_result({:llm_call, response}, state, %{
               last_message_metadata: %{}
             })

    assert next_state.pending_tool_call == %{tool: "calendar.list"}
  end

  test "stores only bounded summaries of tool results and converts restored legacy entries" do
    state =
      ManifestAgent.init(%{
        "_harness_manifest" => %{
          model: "gpt-5.4",
          intelligence: "high",
          system_prompt: "Use tools when needed.",
          goals: [],
          skills: [],
          tool_allowlist: ["calendar.list"]
        }
      })
      |> Map.put(:pending_tool_call, %{tool: "calendar.list"})

    context = %{user_id: nil, timestamp: ~U[2026-08-28 12:00:00Z]}
    raw_result = String.duplicate("calendar output ", 1_000)

    assert {:effect, {:llm_call, _params}, next_state} =
             ManifestAgent.handle_effect_result({:tool_call, raw_result}, state, context)

    [summary] = next_state.tool_results
    assert summary.tool == "calendar.list"
    assert summary.status == :ok
    assert byte_size(summary.summary) <= 2_048
    assert summary.bytes > byte_size(summary.summary)
    assert summary.at == "2026-08-28T12:00:00Z"
    refute Map.has_key?(summary, :result)

    restored =
      ManifestAgent.reconcile_restored_state(
        %{next_state | tool_results: [{"search", raw_result}]},
        %{}
      )

    [converted] = restored.tool_results
    assert converted.tool == "search"
    assert byte_size(converted.summary) <= 2_048
  end

  test "omits reconstructable manifest prompts from checkpoints and restores them from config" do
    config = %{
      "_harness_manifest" => %{
        model: "gpt-5.4",
        intelligence: "high",
        system_prompt: String.duplicate("prompt ", 4_000),
        skills: [%{name: "Large", instructions: String.duplicate("instructions ", 4_000)}]
      }
    }

    state = ManifestAgent.init(config)
    checkpoint_state = ManifestAgent.snapshot_state(state)
    refute Map.has_key?(checkpoint_state, :manifest)

    snapshot = %{
      behavior_state: checkpoint_state,
      budget: %{llm_calls: 3, tool_calls: 4},
      schema_version: 0
    }

    {restored, _budget} =
      Maraithon.Runtime.Agent.restore_from_snapshot(ManifestAgent, config, snapshot, "agent-1")

    assert restored.manifest.system_prompt == state.manifest.system_prompt
    assert hd(restored.manifest.skills).instructions == hd(state.manifest.skills).instructions
  end

  test "delegates transient cycle context and source-state recovery" do
    source_state =
      AIChiefOfStaff.init(%{"user_id" => "manifest-chief@example.com"})
      |> Map.put(:source_bundle, %{"gmail" => %{"messages" => [%{"body" => "raw"}]}})
      |> Map.put(:assistant_fetch_telemetry, %{"sources" => %{}})
      |> Map.put(:cycle_skill_ids, ["commitment_tracker"])

    wrapper = %{
      manifest: %{},
      source_behavior: "ai_chief_of_staff",
      source_module: AIChiefOfStaff,
      source_state: source_state,
      pending_source_effect?: true,
      last_message_id: nil,
      pending_tool_call: nil,
      tool_results: [],
      runs: 0
    }

    {durable, cycle_context} = ManifestAgent.pop_cycle_context(wrapper)
    refute Map.has_key?(durable.source_state, :source_bundle)
    assert cycle_context.source_bundle["gmail"]["messages"] != []

    hydrated = ManifestAgent.put_cycle_context(durable, cycle_context)
    assert hydrated.source_state.source_bundle == cycle_context.source_bundle

    restored =
      ManifestAgent.reconcile_restored_state(hydrated, %{
        "user_id" => "manifest-chief@example.com"
      })

    refute Map.has_key?(restored.source_state, :source_bundle)
    assert restored.source_state.cycle_skill_ids == nil
    assert restored.source_state.resume_index == 0
  end

  test "rejects structured model tool requests outside the allowlist" do
    state =
      ManifestAgent.init(%{
        "_harness_manifest" => %{
          model: "gpt-5.4",
          intelligence: "high",
          system_prompt: "Use tools when needed.",
          goals: [],
          skills: [],
          tool_allowlist: ["calendar.list"]
        }
      })

    response = %{content: Jason.encode!(%{tool_call: %{name: "gmail.read", args: %{}}})}

    assert {:emit, {:agent_error, payload}, _state} =
             ManifestAgent.handle_effect_result({:llm_call, response}, state, %{
               last_message_metadata: %{}
             })

    assert payload.error == "That automation is not allowed to use that action."
  end

  test "delegates scheduled work to a source behavior shim when configured" do
    state =
      ManifestAgent.init(%{
        "source_behavior" => "watchdog_summarizer",
        "wakeup_interval_ms" => 30_000,
        "_harness_manifest" => %{
          model: "gpt-5.4",
          intelligence: "high",
          tool_allowlist: ["llm.complete"]
        }
      })

    assert ManifestAgent.next_wakeup(state) == {:relative, 30_000}

    assert {:emit, {:note_appended, note}, next_state} =
             ManifestAgent.handle_wakeup(state, %{
               agent_id: Ecto.UUID.generate(),
               timestamp: DateTime.utc_now(),
               budget: %{llm_calls: 5, tool_calls: 5}
             })

    assert note =~ "Monitoring check 1"
    assert note =~ "no new issues"
    assert next_state.source_behavior == "watchdog_summarizer"
    assert next_state.source_state.iteration == 1
  end

  test "routes source behavior effects and results back through the shim state" do
    state =
      ManifestAgent.init(%{
        "source_behavior" => "watchdog_summarizer",
        "wakeup_interval_ms" => 30_000,
        "_harness_manifest" => %{
          model: "gpt-5.4",
          intelligence: "high",
          tool_allowlist: ["llm.complete"]
        }
      })

    context = %{
      agent_id: Ecto.UUID.generate(),
      timestamp: DateTime.utc_now(),
      budget: %{llm_calls: 5, tool_calls: 5}
    }

    assert {:emit, {:note_appended, _note}, state} = ManifestAgent.handle_wakeup(state, context)

    assert {:effect, {:llm_call, params}, state} = ManifestAgent.handle_wakeup(state, context)
    assert state.pending_source_effect? == true
    assert [%{"role" => "user", "content" => prompt}] = params["messages"]
    assert prompt =~ "operator-facing monitoring updates"
    refute prompt =~ "Agent ID"
    refute prompt =~ "Budget remaining"

    response = %{content: "System healthy. No urgent operator action."}

    assert {:emit, {:note_appended, note}, state} =
             ManifestAgent.handle_effect_result({:llm_call, response}, state, context)

    assert note == "Monitoring update: System healthy. No urgent operator action."
    assert state.pending_source_effect? == false
    assert state.source_state.summaries == ["System healthy. No urgent operator action."]
  end
end
