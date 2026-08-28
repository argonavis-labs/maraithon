defmodule Maraithon.Behaviors.AIChiefOfStaffTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Behaviors.AIChiefOfStaff
  alias Maraithon.ChiefOfStaff.Skills
  alias Maraithon.OperatorEvents
  alias Maraithon.TestSupport.ChiefOfStaffTestSkill

  # SPEC 04 R3: once every skill in a cycle has run, `finalize_cycle/1` first
  # requests a short model-written cross-cycle memo (an `{:effect,
  # {:llm_call, ...}}` keyed by the `:cycle_memo` sentinel) before returning
  # the cycle's real emit. Tests exercising the end of a cycle need to drive
  # that extra round-trip; this helper does so transparently and is a no-op
  # when the cycle had nothing worth memo-ing (memo generation skipped).
  defp resolve_cycle_result(
         {:effect, {:llm_call, _params}, %{pending_effect_skill_id: :cycle_memo} = state},
         context
       ) do
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

  test "handle_wakeup tolerates a restored snapshot missing newer state keys", %{
    context: context
  } do
    state =
      AIChiefOfStaff.init(%{
        "user_id" => "chief@example.com",
        "skill_configs" => %{}
      })

    # A behavior_state snapshot written by an older release has none of the
    # keys added since (pending_watermarks, cycle_memory, ...). Restore hands
    # that map to handle_wakeup verbatim; it must not KeyError (prod outage
    # 2026-07-03).
    legacy_state =
      Map.drop(state, [
        :pending_watermarks,
        :last_watermarks,
        :last_cycle_stats,
        :cycle_memory,
        :cycle_memo_generated,
        :decision_ledger
      ])

    assert {_directive, _state_or_effect, _next} =
             (case AIChiefOfStaff.handle_wakeup(legacy_state, context) do
                {a, b} -> {a, b, nil}
                {a, b, c} -> {a, b, c}
              end)
  end

  test "declares payload-diet snapshot schema_version 2" do
    assert AIChiefOfStaff.schema_version() == 2
  end

  test "migrates version 1 by dropping cycle payloads and pending prompt inputs" do
    legacy = %{
      source_bundle: %{"gmail" => %{"messages" => [%{"body" => "raw"}]}},
      assistant_fetch_telemetry: %{"sources" => %{}},
      cycle_skill_ids: ["commitment_tracker"],
      assistant_cycle_id: "cycle-1",
      pending_effect_skill_id: "commitment_tracker",
      resume_index: 1,
      pending_watermarks: [%{kind: "history"}],
      pending_emit: {:briefs_recorded, %{count: 1}},
      pending_emits: [%{skill_id: "commitment_tracker"}],
      cycle_memo_generated: true,
      skill_states: %{
        "commitment_tracker" => %{
          pending_tracker_input: %{"gmail" => %{"body" => "raw"}},
          pending_dedupe_key: "old"
        },
        "calendar_check_in" => %{pending_check_in_input: %{"prompt" => "raw"}},
        "holiday_radar" => %{
          pending_holidays: %{
            "h" => %{
              "id" => "h",
              "name" => "Labor Day",
              "date" => "2026-09-07",
              "region" => "US",
              "planning_note" => "raw"
            }
          }
        },
        "morning_briefing" => %{pending_brief_input: %{"gmail" => %{"body" => "raw"}}},
        "inbox_calendar_advisor" => %{pending_candidates: [%{"body" => "raw"}]}
      }
    }

    migrated = AIChiefOfStaff.migrate_state(1, legacy, %{})

    refute Map.has_key?(migrated, :source_bundle)
    refute Map.has_key?(migrated, :assistant_fetch_telemetry)
    assert migrated.cycle_skill_ids == nil
    assert migrated.assistant_cycle_id == nil
    assert migrated.resume_index == 0
    assert migrated.pending_watermarks == []
    assert migrated.skill_states["commitment_tracker"].pending_effect == nil
    refute Map.has_key?(migrated.skill_states["commitment_tracker"], :pending_tracker_input)
    assert migrated.skill_states["calendar_check_in"].pending_effect == nil

    assert migrated.skill_states["holiday_radar"].pending_holidays == %{
             "h" => %{
               "id" => "h",
               "name" => "Labor Day",
               "date" => "2026-09-07",
               "region" => "US"
             }
           }

    assert migrated.skill_states["morning_briefing"].pending_brief_input == nil
    assert migrated.skill_states["inbox_calendar_advisor"].pending_candidates == []
  end

  test "moves source acquisition into transient cycle context" do
    state = AIChiefOfStaff.init(%{"user_id" => "chief@example.com"})
    bundle = %{"gmail" => %{"messages" => [%{"message_id" => "m1", "body" => "raw"}]}}

    hydrated =
      AIChiefOfStaff.put_cycle_context(state, %{
        source_bundle: bundle,
        assistant_fetch_telemetry: %{"sources" => %{}}
      })

    {durable, cycle_context} = AIChiefOfStaff.pop_cycle_context(hydrated)

    refute Map.has_key?(durable, :source_bundle)
    refute Map.has_key?(durable, :assistant_fetch_telemetry)
    assert cycle_context.source_bundle == bundle
  end

  describe "reconcile_restored_state/2 (SPEC 08 R6)" do
    test "adds a newly-shipped skill to a stale snapshot list without re-initing existing skills" do
      # Snapshot era: only "alpha" existed/enabled.
      Skills.put_process_override(
        skill_modules: %{"alpha" => ChiefOfStaffTestSkill},
        default_enabled_ids: ["alpha"]
      )

      config = %{"user_id" => "chief@example.com"}
      old_state = AIChiefOfStaff.init(config)
      # Real accumulated per-skill history that must survive reconciliation.
      old_state = put_in(old_state, [:skill_states, "alpha", :accumulated_marker], 42)

      # Current release: "local_pattern_review" shipped and enabled by
      # default — the motivating frozen-skill-list case.
      Skills.put_process_override(
        skill_modules: %{
          "alpha" => ChiefOfStaffTestSkill,
          "local_pattern_review" => ChiefOfStaffTestSkill
        },
        default_enabled_ids: ["alpha", "local_pattern_review"]
      )

      reconciled = AIChiefOfStaff.reconcile_restored_state(old_state, config)

      assert reconciled.enabled_skill_ids == ["alpha", "local_pattern_review"]
      assert Map.has_key?(reconciled.skill_states, "local_pattern_review")
      assert Map.has_key?(reconciled.skill_configs, "local_pattern_review")
      # An id already present in skill_states is never re-init'd.
      assert reconciled.skill_states["alpha"].accumulated_marker == 42
    end

    test "restarts an in-flight restored cycle while preserving accumulated memory" do
      Skills.put_process_override(
        skill_modules: %{"alpha" => ChiefOfStaffTestSkill},
        default_enabled_ids: ["alpha"]
      )

      config = %{"user_id" => "chief@example.com"}

      mid_cycle_state = %{
        AIChiefOfStaff.init(config)
        | cycle_skill_ids: ["alpha"],
          resume_index: 1,
          pending_effect_skill_id: "alpha",
          pending_watermarks: [%{kind: "history"}],
          last_watermarks: %{"gmail:history" => "123"},
          cycle_memory: %{"memo" => "held two threads", "updated_at" => "t", "cycle_id" => "c1"}
      }

      Skills.put_process_override(
        skill_modules: %{"alpha" => ChiefOfStaffTestSkill, "beta" => ChiefOfStaffTestSkill},
        default_enabled_ids: ["alpha", "beta"]
      )

      reconciled = AIChiefOfStaff.reconcile_restored_state(mid_cycle_state, config)

      # Effect continuation and its cycle-local acquisition context are not
      # durable. Recovery starts a fresh cycle from the last durable memory.
      assert reconciled.cycle_skill_ids == nil
      assert reconciled.resume_index == 0
      assert reconciled.pending_effect_skill_id == nil
      assert reconciled.pending_watermarks == []
      # Accumulated keys survive the restart.
      assert reconciled.last_watermarks == %{"gmail:history" => "123"}
      assert reconciled.cycle_memory["memo"] == "held two threads"
      # Config-derived keys reflect the live config immediately.
      assert reconciled.enabled_skill_ids == ["alpha", "beta"]
      assert Map.has_key?(reconciled.skill_states, "beta")
    end

    test "prunes disabled skill state after the restored cycle is restarted" do
      Skills.put_process_override(
        skill_modules: %{"alpha" => ChiefOfStaffTestSkill, "beta" => ChiefOfStaffTestSkill},
        default_enabled_ids: ["alpha", "beta"]
      )

      config = %{}
      old_state = %{AIChiefOfStaff.init(config) | cycle_skill_ids: ["beta"]}

      # "beta" disabled since the snapshot — a light trim (1 of 2 remains),
      # not a degenerate collapse, so config wins for enabled_skill_ids...
      Skills.put_process_override(
        skill_modules: %{"alpha" => ChiefOfStaffTestSkill, "beta" => ChiefOfStaffTestSkill},
        default_enabled_ids: ["alpha"]
      )

      reconciled = AIChiefOfStaff.reconcile_restored_state(old_state, config)

      assert reconciled.enabled_skill_ids == ["alpha"]
      refute Map.has_key?(reconciled.skill_states, "beta")
      refute Map.has_key?(reconciled.skill_configs, "beta")
      assert reconciled.cycle_skill_ids == nil
    end

    test "degenerate config guard: a collapsed live skill list defers to the snapshot, dropping nothing" do
      five = ["s1", "s2", "s3", "s4", "s5"]
      modules = Map.new(five, &{&1, ChiefOfStaffTestSkill})

      Skills.put_process_override(skill_modules: modules, default_enabled_ids: five)

      config = %{}
      old_state = AIChiefOfStaff.init(config)

      old_state =
        Enum.reduce(five, old_state, fn id, acc ->
          put_in(acc, [:skill_states, id, :accumulated_marker], id)
        end)

      # Transient blip: the enabled list collapses to 2 of 5 (2 < 5/2) while
      # the modules themselves are still compiled and registered. Trusting it
      # would permanently discard three skills' accumulated skill_states on
      # the next checkpoint — snapshot wins instead, for this restore.
      Skills.put_process_override(skill_modules: modules, default_enabled_ids: ["s1", "s2"])

      reconciled = AIChiefOfStaff.reconcile_restored_state(old_state, config)

      assert reconciled.enabled_skill_ids == five

      for id <- five do
        assert reconciled.skill_states[id].accumulated_marker == id
      end
    end
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
             AIChiefOfStaff.handle_wakeup(continued_state, context)
             |> resolve_cycle_result(context)

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
             AIChiefOfStaff.handle_wakeup(state, event_context)
             |> resolve_cycle_result(event_context)

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

      assert {:effect, {:llm_call, params}, waiting_state} =
               AIChiefOfStaff.handle_wakeup(state, context)

      assert params["max_tokens"] == 400
      assert params["reasoning_effort"] == "none"
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

  describe "skill effect error isolation (SPEC 07 R1)" do
    test "a skill lacking handle_effect_error/4 no longer aborts the cycle: later skills run, finalize_cycle runs, and an operator event is recorded",
         %{context: context} do
      # OperatorEvents.record/1 enforces a user FK.
      {:ok, _user} = Accounts.get_or_create_user_by_email(context.user_id)

      state =
        AIChiefOfStaff.init(%{
          "user_id" => context.user_id,
          "skill_configs" => %{
            # ChiefOfStaffTestSkill exports no handle_effect_error/4 — the
            # exact class of skill (followthrough/travel_logistics/...) this
            # generic path exists for.
            "alpha" => %{
              "wakeup_mode" => "effect",
              "effect_kind" => "llm_call",
              "effect_params" => %{"messages" => [%{"role" => "user", "content" => "hi"}]}
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

      assert {:effect, {:llm_call, _params}, waiting_state} =
               AIChiefOfStaff.handle_wakeup(state, context)

      assert waiting_state.pending_effect_skill_id == "alpha"
      assert waiting_state.resume_index == 1
      cycle_id = waiting_state.assistant_cycle_id

      # Alpha's effect fails; the cycle must continue at beta and reach
      # finalize_cycle/1 (via the memo round-trip) instead of returning a
      # terminal {:idle, ...} with a frozen cycle_skill_ids/resume_index.
      assert {:emit, {:briefs_recorded, payload}, next_state} =
               AIChiefOfStaff.handle_effect_error(
                 :llm_call,
                 {:rate_limited, 429},
                 waiting_state,
                 context
               )
               |> resolve_cycle_result(context)

      assert payload["cadences"] == ["morning"]
      assert next_state.cycle_skill_ids == nil
      assert next_state.resume_index == 0
      assert next_state.pending_effect_skill_id == nil

      assert [event] =
               OperatorEvents.list_events(
                 user_id: context.user_id,
                 event_type: "cycle.skill_effect_error"
               )

      assert event.source == "chief_of_staff"
      assert event.source_item_id == "alpha"
      assert event.dedupe_key == "cos_skill_effect_error:#{cycle_id}:alpha"
      assert event.payload["effect_type"] == "llm_call"
      assert event.payload["reason"] =~ "rate_limited"
      assert event.payload["resume_index"] == 1
    end
  end

  defp pubsub_context(context, topic) do
    %{
      context
      | trigger: %{type: :pubsub_event, topic: topic},
        event: %{topic: topic, payload: %{"history_id" => "123"}}
    }
  end

  defp ledger_emitting_state(context, ledger_entries, extra_alpha_config \\ %{}) do
    AIChiefOfStaff.init(%{
      "user_id" => context.user_id,
      "skill_configs" => %{
        "alpha" =>
          Map.merge(
            %{
              "interest_mode" => "always",
              "wakeup_mode" => "emit",
              "wakeup_emit_type" => "insights_recorded",
              "wakeup_payload" => %{
                "count" => 1,
                "user_id" => context.user_id,
                "categories" => ["general"],
                "ledger_entries" => ledger_entries
              }
            },
            extra_alpha_config
          ),
        "beta" => %{"interest_mode" => "scheduled_only", "wakeup_mode" => "idle"}
      }
    })
  end

  describe "decision ledger + scheduled-only memo (SPEC 07 R5/R6/R8/R9)" do
    test "a pubsub cycle skips the memo LLM call, leaves cycle_memory untouched, and still merges ledger entries",
         %{context: context} do
      event_context = pubsub_context(context, "slack:T123")

      previous_memory = %{
        "memo" => "Rich scheduled-scan memo.",
        "updated_at" => "2026-03-15T00:00:00Z",
        "cycle_id" => "prior-cycle"
      }

      state = %{
        ledger_emitting_state(context, [
          %{
            "item_id" => "insight-1",
            "item_type" => "insight",
            "decision" => "suppressed",
            "reason" => "recurring detector noise"
          },
          # Malformed entries are dropped, never crash the cycle (R6).
          %{"item_id" => "", "decision" => "bogus"},
          "not-a-map"
        ])
        | cycle_memory: previous_memory
      }

      # R9: the emit comes back directly — no `{:effect, {:llm_call, ...}}`
      # memo round-trip for a non-scheduled cycle.
      assert {:emit, {:insights_recorded, payload}, next_state} =
               AIChiefOfStaff.handle_wakeup(state, event_context)

      # R6: the internal bookkeeping key never reaches the outgoing emit.
      refute Map.has_key?(payload, "ledger_entries")
      refute Map.has_key?(payload, :ledger_entries)

      # cycle_memory is byte-for-byte unchanged; the ledger still updated.
      assert next_state.cycle_memory == previous_memory
      assert next_state.cycle_memo_generated == false
      assert next_state.cycle_skill_ids == nil

      assert %{
               "item_type" => "insight",
               "decision" => "suppressed",
               "reason" => "recurring detector noise",
               "skill_id" => "alpha"
             } = next_state.decision_ledger["insight-1"]

      assert is_binary(next_state.decision_ledger["insight-1"]["first_seen_cycle"])
      assert map_size(next_state.decision_ledger) == 1
    end

    test "ledger upserts preserve first_seen_cycle and overwrite decision/reason", %{
      context: context
    } do
      event_context = pubsub_context(context, "email:chief@example.com")

      state =
        ledger_emitting_state(context, [
          %{
            "item_id" => "todo-9",
            "item_type" => "todo",
            "decision" => "held",
            "reason" => "waiting on reply"
          }
        ])

      assert {:emit, _emit, first_state} = AIChiefOfStaff.handle_wakeup(state, event_context)
      first_entry = first_state.decision_ledger["todo-9"]
      assert first_entry["decision"] == "held"
      assert is_binary(first_entry["first_seen_cycle"])

      second_state =
        put_in(first_state, [:skill_states, "alpha", :wakeup_payload, "ledger_entries"], [
          %{
            "item_id" => "todo-9",
            "item_type" => "todo",
            "decision" => "watch",
            "reason" => "they just replied"
          }
        ])

      assert {:emit, _emit, next_state} =
               AIChiefOfStaff.handle_wakeup(second_state, event_context)

      entry = next_state.decision_ledger["todo-9"]
      assert entry["decision"] == "watch"
      assert entry["reason"] == "they just replied"
      # first_seen_cycle survives the upsert; last_seen_cycle moves.
      assert entry["first_seen_cycle"] == first_entry["first_seen_cycle"]
      refute entry["last_seen_cycle"] == first_entry["last_seen_cycle"]
    end

    test "the ledger caps at 40 entries, dropping oldest resolved entries first", %{
      context: context
    } do
      event_context = pubsub_context(context, "email:chief@example.com")

      seeded_ledger =
        Map.new(1..40, fn n ->
          decision = if n == 1, do: "resolved", else: "held"

          {"seed-#{n}",
           %{
             "item_type" => "todo",
             "decision" => decision,
             "reason" => "seed #{n}",
             "skill_id" => "alpha",
             "first_seen_cycle" => "c0",
             "last_seen_cycle" => "c0",
             "updated_at" => "2026-01-01T00:00:#{String.pad_leading("#{n}", 2, "0")}Z"
           }}
        end)

      state = %{
        ledger_emitting_state(context, [
          %{
            "item_id" => "fresh-1",
            "item_type" => "insight",
            "decision" => "suppressed",
            "reason" => "noise"
          }
        ])
        | decision_ledger: seeded_ledger
      }

      assert {:emit, _emit, next_state} = AIChiefOfStaff.handle_wakeup(state, event_context)

      assert map_size(next_state.decision_ledger) == 40
      assert Map.has_key?(next_state.decision_ledger, "fresh-1")
      # "seed-1" is the only resolved entry — dropped first despite not being
      # the oldest overall (all seeds share the same date prefix; resolved
      # status outranks recency for eviction).
      refute Map.has_key?(next_state.decision_ledger, "seed-1")
    end

    test "skill context carries the ledger newest-first (R8)", %{context: context} do
      event_context = pubsub_context(context, "email:chief@example.com")

      state = %{
        ledger_emitting_state(context, [], %{
          "include_context_keys" => ["previous_decision_ledger"]
        })
        | decision_ledger: %{
            "old-item" => %{
              "item_type" => "insight",
              "decision" => "suppressed",
              "reason" => "older decision",
              "skill_id" => "alpha",
              "first_seen_cycle" => "c1",
              "last_seen_cycle" => "c1",
              "updated_at" => "2026-01-01T00:00:00Z"
            },
            "new-item" => %{
              "item_type" => "insight",
              "decision" => "watch",
              "reason" => "newer decision",
              "skill_id" => "alpha",
              "first_seen_cycle" => "c2",
              "last_seen_cycle" => "c2",
              "updated_at" => "2026-02-01T00:00:00Z"
            }
          }
      }

      assert {:emit, {:insights_recorded, payload}, _next_state} =
               AIChiefOfStaff.handle_wakeup(state, event_context)

      assert [%{"reason" => "newer decision"}, %{"reason" => "older decision"}] =
               payload["previous_decision_ledger"]
    end
  end
end
