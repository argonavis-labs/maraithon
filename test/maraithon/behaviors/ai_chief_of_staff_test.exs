defmodule Maraithon.Behaviors.AIChiefOfStaffTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Behaviors.AIChiefOfStaff
  alias Maraithon.ChiefOfStaff.Skills
  alias Maraithon.TestSupport.ChiefOfStaffTestSkill

  setup do
    Skills.put_process_override(
      skill_modules: %{
        "alpha" => ChiefOfStaffTestSkill,
        "beta" => ChiefOfStaffTestSkill
      },
      default_enabled_ids: ["alpha", "beta"]
    )

    on_exit(fn ->
      Skills.clear_process_override()
    end)

    context = %{
      agent_id: "chief-agent-1",
      user_id: "chief@example.com",
      timestamp: ~U[2026-03-16 00:00:00Z],
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      last_message: nil,
      last_message_metadata: %{},
      last_message_id: nil,
      trigger: nil,
      event: nil
    }

    %{context: context}
  end

  test "initializes the default skill pack and aggregates wakeups" do
    state =
      AIChiefOfStaff.init(%{
        "user_id" => "chief@example.com",
        "skill_configs" => %{
          "alpha" => %{"next_wakeup_ms" => 900_000},
          "beta" => %{"next_wakeup_ms" => 300_000}
        }
      })

    assert state.enabled_skill_ids == ["alpha", "beta"]
    assert Map.has_key?(state.skill_states, "alpha")
    assert Map.has_key?(state.skill_states, "beta")
    assert {:relative, 300_000} = AIChiefOfStaff.next_wakeup(state)
  end

  test "keeps an always-on scan floor even when skills only schedule daily work" do
    state =
      AIChiefOfStaff.init(%{
        "user_id" => "chief@example.com",
        "wakeup_interval_ms" => "600000",
        "skill_configs" => %{
          "alpha" => %{},
          "beta" => %{}
        }
      })

    assert {:relative, 600_000} = AIChiefOfStaff.next_wakeup(state)
  end

  test "can register additional compiled skills without replacing the built-in registry" do
    Skills.put_process_override(
      skill_modules: %{"alpha" => ChiefOfStaffTestSkill},
      extra_skill_modules: %{"gamma" => ChiefOfStaffTestSkill},
      default_enabled_ids: ["alpha", "gamma"]
    )

    assert "alpha" in Skills.list_ids()
    assert "gamma" in Skills.list_ids()
    assert Skills.enabled_ids(%{}) == ["alpha", "gamma"]
    assert Skills.label("gamma") == "Gamma"
    assert Skills.description("gamma") == "Runs as part of the Chief of Staff cycle."
  end

  test "merges emitted outputs from multiple skills in one wakeup", %{context: context} do
    state =
      AIChiefOfStaff.init(%{
        "user_id" => context.user_id,
        "skill_configs" => %{
          "alpha" => %{
            "wakeup_mode" => "emit",
            "wakeup_emit_type" => "insights_recorded",
            "wakeup_payload" => %{
              "count" => 1,
              "user_id" => context.user_id,
              "categories" => ["reply_urgent"]
            }
          },
          "beta" => %{
            "wakeup_mode" => "emit",
            "wakeup_emit_type" => "briefs_recorded",
            "wakeup_payload" => %{
              "count" => 1,
              "user_id" => context.user_id,
              "cadences" => ["morning"]
            }
          }
        }
      })

    assert {:emit, {:insights_recorded, payload}, next_state} =
             AIChiefOfStaff.handle_wakeup(state, context)

    assert payload["count"] == 1
    assert payload["user_id"] == context.user_id
    assert payload["categories"] == ["reply_urgent"]
    assert [%{"count" => 1, "cadences" => ["morning"]}] = payload["briefs"]
    assert next_state.pending_emit == nil
  end

  test "routes an effect result back to the originating skill and resumes later skills", %{
    context: context
  } do
    state =
      AIChiefOfStaff.init(%{
        "user_id" => context.user_id,
        "skill_configs" => %{
          "alpha" => %{
            "wakeup_mode" => "effect",
            "effect_kind" => "llm_call",
            "effect_params" => %{"messages" => [%{"role" => "user", "content" => "hi"}]},
            "effect_result_mode" => "emit",
            "effect_emit_type" => "insights_recorded",
            "effect_payload" => %{
              "count" => 1,
              "user_id" => context.user_id,
              "categories" => ["commitment_unresolved"]
            }
          },
          "beta" => %{
            "wakeup_mode" => "emit",
            "wakeup_emit_type" => "briefs_recorded",
            "wakeup_payload" => %{
              "count" => 1,
              "user_id" => context.user_id,
              "cadences" => ["weekly_review"]
            }
          }
        }
      })

    assert {:effect, {:llm_call, _params}, waiting_state} =
             AIChiefOfStaff.handle_wakeup(state, context)

    assert waiting_state.pending_effect_skill_id == "alpha"
    assert waiting_state.resume_index == 1

    assert {:emit, {:insights_recorded, payload}, next_state} =
             AIChiefOfStaff.handle_effect_result(
               {:llm_call, %{content: "ok"}},
               waiting_state,
               context
             )

    assert payload["categories"] == ["commitment_unresolved"]
    assert [%{"count" => 1, "cadences" => ["weekly_review"]}] = payload["briefs"]
    assert next_state.pending_effect_skill_id == nil
    assert next_state.resume_index == 0
  end

  test "runs only the skills interested in a pubsub trigger", %{context: context} do
    event_context = %{
      context
      | trigger: %{type: :pubsub_event, topic: "email:chief@example.com"},
        event: %{topic: "email:chief@example.com", payload: %{"history_id" => "123"}}
    }

    state =
      AIChiefOfStaff.init(%{
        "user_id" => context.user_id,
        "skill_configs" => %{
          "alpha" => %{
            "interest_mode" => "always",
            "wakeup_mode" => "emit",
            "wakeup_emit_type" => "insights_recorded",
            "wakeup_payload" => %{
              "count" => 1,
              "user_id" => context.user_id,
              "categories" => ["reply_urgent"]
            }
          },
          "beta" => %{
            "interest_mode" => "scheduled_only",
            "wakeup_mode" => "emit",
            "wakeup_emit_type" => "briefs_recorded",
            "wakeup_payload" => %{
              "count" => 1,
              "user_id" => context.user_id,
              "cadences" => ["morning"]
            }
          }
        }
      })

    assert {:emit, {:insights_recorded, payload}, next_state} =
             AIChiefOfStaff.handle_wakeup(state, event_context)

    assert payload["categories"] == ["reply_urgent"]
    refute Map.has_key?(payload, "briefs")
    assert next_state.cycle_skill_ids == nil
  end

  test "scheduled wakeups still run the full enabled skill pack", %{context: context} do
    scheduled_context = %{context | trigger: %{type: :wakeup, job_type: "wakeup"}}

    state =
      AIChiefOfStaff.init(%{
        "user_id" => context.user_id,
        "skill_configs" => %{
          "alpha" => %{
            "interest_mode" => "always",
            "wakeup_mode" => "emit",
            "wakeup_emit_type" => "insights_recorded",
            "wakeup_payload" => %{
              "count" => 1,
              "user_id" => context.user_id,
              "categories" => ["reply_urgent"]
            }
          },
          "beta" => %{
            "interest_mode" => "scheduled_only",
            "wakeup_mode" => "emit",
            "wakeup_emit_type" => "briefs_recorded",
            "wakeup_payload" => %{
              "count" => 1,
              "user_id" => context.user_id,
              "cadences" => ["morning"]
            }
          }
        }
      })

    assert {:emit, {:insights_recorded, payload}, _next_state} =
             AIChiefOfStaff.handle_wakeup(state, scheduled_context)

    assert payload["categories"] == ["reply_urgent"]
    assert [%{"count" => 1, "cadences" => ["morning"]}] = payload["briefs"]
  end

  test "builds one shared acquisition bundle and threads cycle metadata into skill context", %{
    context: context
  } do
    state =
      AIChiefOfStaff.init(%{
        "user_id" => context.user_id,
        "skill_configs" => %{
          "alpha" => %{
            "wakeup_mode" => "emit",
            "wakeup_emit_type" => "insights_recorded",
            "wakeup_payload" => %{"count" => 1, "user_id" => context.user_id, "categories" => []},
            "include_context_keys" => [
              "assistant_cycle_id",
              "assistant_origin_skill_id",
              "assistant_origin_skill_rank",
              "source_bundle_present",
              "assistant_fetch_telemetry"
            ]
          },
          "beta" => %{
            "wakeup_mode" => "idle"
          }
        }
      })

    assert {:emit, {:insights_recorded, payload}, _next_state} =
             AIChiefOfStaff.handle_wakeup(state, context)

    assert is_binary(payload["assistant_cycle_id"])
    assert payload["assistant_origin_skill_id"] == "alpha"
    assert payload["assistant_origin_skill_rank"] == 1
    assert payload["source_bundle_present"] == true
    assert is_map(payload["assistant_fetch_telemetry"])
  end
end
