defmodule Maraithon.Behaviors.ManifestAgentTest do
  use ExUnit.Case, async: true

  alias Maraithon.Behaviors.ManifestAgent

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

    assert payload.error =~ "model_not_configured"
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

    assert next_state.pending_tool_call.tool == "calendar.list"
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

    assert payload.error == "tool_not_allowed: gmail.read"
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
