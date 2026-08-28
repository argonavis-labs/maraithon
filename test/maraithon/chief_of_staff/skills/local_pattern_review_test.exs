defmodule Maraithon.ChiefOfStaff.Skills.LocalPatternReviewTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Behaviors.SnapshotBudget
  alias Maraithon.Agents
  alias Maraithon.ChiefOfStaff.Skills.LocalPatternReview
  alias Maraithon.Insights
  alias Maraithon.Runtime.SnapshotFormat

  setup do
    user_id = "local-pattern-review-#{Ecto.UUID.generate()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{"name" => "cos"}
      })

    state = LocalPatternReview.init(%{"user_id" => user_id})

    context = %{
      user_id: user_id,
      agent_id: agent.id,
      timestamp: DateTime.utc_now(),
      trigger: %{type: :wakeup}
    }

    %{user_id: user_id, agent: agent, state: state, context: context}
  end

  defp candidate_insight(user_id, agent_id, suffix, summary \\ nil) do
    {:ok, [insight]} =
      Insights.record_many(
        user_id,
        agent_id,
        [
          %{
            "source" => "local_patterns",
            "category" => "general",
            "title" => "Candidate #{suffix}",
            "summary" => summary || "A candidate insight #{suffix}",
            "recommended_action" => "Do something",
            "priority" => 50,
            "confidence" => 0.5,
            "tracking_key" => "local_patterns:test:#{suffix}",
            "dedupe_key" => "local_patterns:test:#{suffix}:2026-01-01",
            "metadata" => %{"detector" => "note_follow_up"}
          }
        ],
        status: "candidate"
      )

    insight
  end

  test "idles with no model call when there are no pending candidates", %{
    state: state,
    context: context
  } do
    assert {:idle, _state} = LocalPatternReview.handle_wakeup(state, context)
  end

  test "requests an llm_call review when candidates are pending", %{
    user_id: user_id,
    agent: agent,
    state: state,
    context: context
  } do
    candidate = candidate_insight(user_id, agent.id, "a")

    assert {:effect, {:llm_call, params}, pending_state} =
             LocalPatternReview.handle_wakeup(state, context)

    assert [message] = params["messages"]
    assert message["content"] =~ candidate.id
    assert length(pending_state.pending_candidate_refs) == 1
  end

  test "keeps only compact refs for realistic large candidate batches", %{
    user_id: user_id,
    agent: agent,
    state: state,
    context: context
  } do
    large_summary = String.duplicate("provider-derived detail ", 20)

    Enum.each(1..20, fn index ->
      candidate_insight(user_id, agent.id, "large-#{index}", large_summary)
    end)

    assert {:effect, {:llm_call, params}, pending_state} =
             LocalPatternReview.handle_wakeup(%{state | candidate_limit: 20}, context)

    assert length(pending_state.pending_candidate_refs) == 20

    assert Enum.all?(pending_state.pending_candidate_refs, fn ref ->
             Map.keys(ref) |> Enum.sort() == [:category, :id]
           end)

    assert get_in(params, ["messages", Access.at(0), "content"]) =~ "provider-derived detail"
    refute Jason.encode!(pending_state) =~ "provider-derived detail"

    assert {:ok, bytes} = SnapshotBudget.check(pending_state)
    assert bytes < 128 * 1_024
    assert {:ok, envelope, ^bytes} = SnapshotFormat.encode(pending_state)
    assert {:ok, ^pending_state} = SnapshotFormat.decode(envelope)
  end

  test "promotes kept candidates to \"new\" and dismisses the rest", %{
    user_id: user_id,
    agent: agent,
    state: state,
    context: context
  } do
    keep = candidate_insight(user_id, agent.id, "keep")
    discard = candidate_insight(user_id, agent.id, "discard")

    assert {:effect, {:llm_call, _params}, pending_state} =
             LocalPatternReview.handle_wakeup(state, context)

    response = %{
      "content" =>
        Jason.encode!(%{
          "decisions" => [
            %{"id" => keep.id, "decision" => "keep", "reason" => "worth surfacing"},
            %{"id" => discard.id, "decision" => "discard", "reason" => "stale"}
          ]
        })
    }

    assert {:emit, {:insights_recorded, payload}, next_state} =
             LocalPatternReview.handle_effect_result(
               {:llm_call, response},
               pending_state,
               context
             )

    assert payload.count == 1
    assert next_state.pending_candidate_refs == []

    # SPEC 07 R7: the discard decision carries the model's own reason into
    # the cross-cycle decision ledger contract; "keep" gets no entry (the
    # promoted Insight row is stronger state than the ledger).
    assert [entry] = payload["ledger_entries"]
    assert entry["item_id"] == to_string(discard.id)
    assert entry["item_type"] == "insight"
    assert entry["decision"] == "suppressed"
    assert entry["reason"] == "stale"

    assert Insights.list_candidates_for_user(user_id) == []
    assert [%{id: kept_id, status: "new"}] = Insights.list_open_for_user(user_id)
    assert kept_id == keep.id
  end

  test "a discard-only review still emits ledger entries, falling back to \"discarded\" when the model omits a reason",
       %{user_id: user_id, agent: agent, state: state, context: context} do
    discard = candidate_insight(user_id, agent.id, "only-discard")

    assert {:effect, {:llm_call, _params}, pending_state} =
             LocalPatternReview.handle_wakeup(state, context)

    response = %{
      "content" =>
        Jason.encode!(%{
          "decisions" => [%{"id" => discard.id, "decision" => "discard"}]
        })
    }

    assert {:emit, {:insights_recorded, payload}, _next_state} =
             LocalPatternReview.handle_effect_result(
               {:llm_call, response},
               pending_state,
               context
             )

    assert payload.count == 0
    assert [entry] = payload["ledger_entries"]
    assert entry["item_id"] == to_string(discard.id)
    assert entry["decision"] == "suppressed"
    assert entry["reason"] == "discarded"
    assert Insights.list_candidates_for_user(user_id) == []
  end

  test "renders prior insight ledger decisions into the review prompt (SPEC 07 R8)", %{
    user_id: user_id,
    agent: agent,
    state: state,
    context: context
  } do
    _candidate = candidate_insight(user_id, agent.id, "ledger-prompt")

    ledger_context =
      Map.put(context, :previous_decision_ledger, [
        %{
          "item_type" => "insight",
          "decision" => "suppressed",
          "reason" => "same cold-thread detector fired last cycle; noise",
          "updated_at" => "2026-07-01T00:00:00Z"
        },
        # Non-insight entries are filtered out of this skill's section.
        %{
          "item_type" => "todo",
          "decision" => "held",
          "reason" => "unrelated todo hold"
        }
      ])

    assert {:effect, {:llm_call, params}, _pending_state} =
             LocalPatternReview.handle_wakeup(state, ledger_context)

    assert [message] = params["messages"]
    assert message["content"] =~ "PREVIOUS DECISIONS ON PATTERN CANDIDATES"
    assert message["content"] =~ "same cold-thread detector fired last cycle; noise"
    assert message["content"] =~ "(as of 2026-07-01T00:00:00Z)"
    refute message["content"] =~ "unrelated todo hold"
  end

  test "relationship-drift candidates ride the same review batch and are promoted on keep (SPEC 03)",
       %{user_id: user_id, agent: agent, state: state, context: context} do
    pattern = candidate_insight(user_id, agent.id, "drift-batch")

    # A real drifted person: handle_wakeup's own RelationshipDrift gatherer
    # (not a hand-inserted row) must produce the candidate.
    {:ok, person} =
      Maraithon.Crm.create_person(user_id, %{
        "first_name" => "Charlie",
        "display_name" => "Charlie Beckwith",
        "metadata" => %{
          "communication_signals" => %{
            "overdue" => true,
            "days_since_last" => 18,
            "cadence_days" => 7,
            "computed_at" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      })

    # communication_score is system-owned; seed it so the person enters
    # ReconnectSuggestions' candidate pool.
    Maraithon.Repo.update_all(
      from(p in Maraithon.Crm.Person, where: p.id == ^person.id),
      set: [communication_score: 55]
    )

    assert {:effect, {:llm_call, params}, pending_state} =
             LocalPatternReview.handle_wakeup(state, context)

    drift =
      Enum.find(pending_state.pending_candidate_refs, &(&1.category == "relationship_drift"))

    assert drift
    assert Map.keys(drift) |> Enum.sort() == [:category, :id]

    drift_record = Enum.find(Insights.list_candidates_for_user(user_id), &(&1.id == drift.id))
    assert drift_record.status == "candidate"
    assert drift_record.tracking_key == "relationship_drift:#{person.id}"

    assert [message] = params["messages"]
    assert message["content"] =~ drift.id
    assert message["content"] =~ pattern.id

    response = %{
      "content" =>
        Jason.encode!(%{
          "decisions" => [
            %{"id" => drift.id, "decision" => "keep", "reason" => "important relationship"},
            %{"id" => pattern.id, "decision" => "discard", "reason" => "noise"}
          ]
        })
    }

    assert {:emit, {:insights_recorded, payload}, _next_state} =
             LocalPatternReview.handle_effect_result(
               {:llm_call, response},
               pending_state,
               context
             )

    assert payload.count == 1
    assert "relationship_drift" in payload.categories

    assert [open] = Insights.list_open_for_user(user_id)
    assert open.id == drift.id
    assert open.status == "new"
    assert open.category == "relationship_drift"
  end

  test "leaves candidates untouched when the model call fails", %{
    user_id: user_id,
    agent: agent,
    state: state,
    context: context
  } do
    _candidate = candidate_insight(user_id, agent.id, "err")

    assert {:effect, {:llm_call, _params}, pending_state} =
             LocalPatternReview.handle_wakeup(state, context)

    assert {:idle, next_state} =
             LocalPatternReview.handle_effect_error(:llm_call, "boom", pending_state, context)

    assert next_state.pending_candidate_refs == []
    assert length(Insights.list_candidates_for_user(user_id)) == 1
  end
end
