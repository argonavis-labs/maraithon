defmodule Maraithon.Behaviors.AIChiefOfStaffTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Behaviors.AIChiefOfStaff
  alias Maraithon.ChiefOfStaff.Skills
  alias Maraithon.TestSupport.ChiefOfStaffTestSkill

  # SPEC 04 R3: once every skill in a cycle has run, `finalize_cycle/1` first
  # requests a short model-written cross-cycle memo (an `{:effect,
  # {:llm_call, ...}}` keyed by the `:cycle_memo` sentinel) before returning
  # the cycle's real emit. Tests exercising the end of a cycle need to drive
  # that extra round-trip; this helper does so transparently and is a no-op
  # when the cycle had nothing worth memo-ing (memo generation skipped).
  defp resolve_cycle_result({:effect, {:llm_call, _params}, %{pending_effect_skill_id: :cycle_memo} = state}, context) do
    AIChiefOfStaff.handle_effect_result({:llm_call, %{"content" => "noted."}}, state, context)
  end

  defp resolve_cycle_result(result, _context), do: result

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
        "timezone" => "America/Toronto",
        "timezone_name" => "America/Toronto",
        "timezone_offset_hours" => "-5",
        "skill_configs" => %{
          "alpha" => %{"next_wakeup_ms" => 900_000},
          "beta" => %{"next_wakeup_ms" => 300_000}
        }
      })

    assert state.enabled_skill_ids == ["alpha", "beta"]
    assert Map.has_key?(state.skill_states, "alpha")
    assert Map.has_key?(state.skill_states, "beta")
    assert get_in(state.skill_configs, ["alpha", "timezone"]) == "America/Toronto"
    assert get_in(state.skill_configs, ["alpha", "timezone_name"]) == "America/Toronto"
    assert get_in(state.skill_configs, ["alpha", "timezone_offset_hours"]) == -5
    # R1 (SPEC 04): the fastest-requesting skill wins, floored at 5 minutes —
    # not clamped back up to an hourly loop.
    assert {:relative, 300_000} = AIChiefOfStaff.next_wakeup(state)
  end

  test "honors a faster configured cadence, floored at 5 minutes (not clamped to hourly)" do
    state =
      AIChiefOfStaff.init(%{
        "user_id" => "chief@example.com",
        "wakeup_interval_ms" => "600000",
        "skill_configs" => %{
          "alpha" => %{},
          "beta" => %{}
        }
      })

    # R1 (SPEC 04): config may make cadence *faster* than the 10-minute
    # default — the old `max(config, 1hr)` clamp is gone.
    assert {:relative, 600_000} = AIChiefOfStaff.next_wakeup(state)

    floored_state =
      AIChiefOfStaff.init(%{
        "user_id" => "chief@example.com",
        "wakeup_interval_ms" => "60000",
        "skill_configs" => %{
          "alpha" => %{},
          "beta" => %{}
        }
      })

    # But it cannot go below the 5-minute floor.
    assert {:relative, 300_000} = AIChiefOfStaff.next_wakeup(floored_state)
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
             AIChiefOfStaff.handle_wakeup(state, context) |> resolve_cycle_result(context)

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
             |> resolve_cycle_result(context)

    assert payload["categories"] == ["commitment_unresolved"]
    assert [%{"count" => 1, "cadences" => ["weekly_review"]}] = payload["briefs"]
    assert next_state.pending_effect_skill_id == nil
    assert next_state.resume_index == 0
  end

  test "routes continue from an effect result back to the originating skill", %{
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
            "effect_result_mode" => "continue",
            "effect_continue_wakeup_mode" => "emit",
            "wakeup_emit_type" => "briefs_recorded",
            "wakeup_payload" => %{
              "count" => 1,
              "user_id" => context.user_id,
              "cadences" => ["morning"]
            }
          },
          "beta" => %{"wakeup_mode" => "idle"}
        }
      })

    assert {:effect, {:llm_call, _params}, waiting_state} =
             AIChiefOfStaff.handle_wakeup(state, context)

    assert waiting_state.pending_effect_skill_id == "alpha"
    assert waiting_state.resume_index == 1

    assert {:continue, continued_state} =
             AIChiefOfStaff.handle_effect_result(
               {:llm_call, %{content: "ok"}},
               waiting_state,
               context
             )

    assert continued_state.pending_effect_skill_id == nil
    assert continued_state.resume_index == 0
    assert get_in(continued_state.skill_states, ["alpha", :wakeup_mode]) == "emit"

    assert {:emit, {:briefs_recorded, payload}, next_state} =
             AIChiefOfStaff.handle_wakeup(continued_state, context) |> resolve_cycle_result(context)

    assert payload["cadences"] == ["morning"]
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
             AIChiefOfStaff.handle_wakeup(state, event_context) |> resolve_cycle_result(event_context)

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
             |> resolve_cycle_result(scheduled_context)

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
             AIChiefOfStaff.handle_wakeup(state, context) |> resolve_cycle_result(context)

    assert is_binary(payload["assistant_cycle_id"])
    assert payload["assistant_origin_skill_id"] == "alpha"
    assert payload["assistant_origin_skill_rank"] == 1
    assert payload["source_bundle_present"] == true
    assert is_map(payload["assistant_fetch_telemetry"])
  end

  describe "cross-cycle memo (SPEC 04 R3)" do
    test "persists a model-written memo in behavior_state and injects it into the next cycle's skill context",
         %{context: context} do
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
                "categories" => []
              },
              "include_context_keys" => ["previous_cycle_memo"]
            },
            "beta" => %{"wakeup_mode" => "idle"}
          }
        })

      assert is_nil(get_in(state.cycle_memory, ["memo"]))

      assert {:effect, {:llm_call, _params}, waiting_state} =
               AIChiefOfStaff.handle_wakeup(state, context)

      assert waiting_state.pending_effect_skill_id == :cycle_memo

      assert {:emit, {:insights_recorded, payload}, next_state} =
               AIChiefOfStaff.handle_effect_result(
                 {:llm_call, %{"content" => "Quiet cycle. Watching thread with Alex."}},
                 waiting_state,
                 context
               )

      # R3: the previous cycle had no memo yet, so it's absent from this
      # cycle's own context (there is nothing before cycle 1).
      refute Map.has_key?(payload, "previous_cycle_memo")

      # R3: the model-written memo is now in behavior_state (persisted /
      # snapshotted across restarts), capped well under 1500 chars.
      assert next_state.cycle_memory["memo"] == "Quiet cycle. Watching thread with Alex."
      assert String.length(next_state.cycle_memory["memo"]) <= 1500
      assert is_map(next_state.last_watermarks)

      # R3: the next wakeup (same agent, restored state) sees last cycle's
      # memo injected into the skill context.
      assert {:effect, {:llm_call, _params}, waiting_state_2} =
               AIChiefOfStaff.handle_wakeup(next_state, context)

      assert {:emit, {:insights_recorded, payload_2}, _next_state_2} =
               AIChiefOfStaff.handle_effect_result(
                 {:llm_call, %{"content" => "Alex replied; nothing else new."}},
                 waiting_state_2,
                 context
               )

      assert payload_2["previous_cycle_memo"] == "Quiet cycle. Watching thread with Alex."
    end

    test "skips the memo llm_call on a quiet repeat cycle with no deltas or emits", %{
      context: context
    } do
      state =
        AIChiefOfStaff.init(%{
          "user_id" => context.user_id,
          "skill_configs" => %{
            "alpha" => %{"wakeup_mode" => "idle"},
            "beta" => %{"wakeup_mode" => "idle"}
          }
        })

      # Simulate a prior cycle that already wrote a memo — this cycle has no
      # new deltas or emits, so R3's near-zero-spend goal means no llm_call.
      state = %{
        state
        | cycle_memory: %{
            "memo" => "Nothing outstanding as of last check.",
            "updated_at" => "2026-03-15T00:00:00Z",
            "cycle_id" => "prior-cycle"
          }
      }

      assert {:idle, next_state} = AIChiefOfStaff.handle_wakeup(state, context)
      assert next_state.pending_effect_skill_id == nil
      assert next_state.cycle_memo_generated == false
      # The memo carries forward unchanged since this cycle had nothing new.
      assert next_state.cycle_memory["memo"] == "Nothing outstanding as of last check."
    end
  end
end
