defmodule Maraithon.ChiefOfStaff.Skills.LocalPatternReviewTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ChiefOfStaff.Skills.LocalPatternReview
  alias Maraithon.Insights

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
    context = %{user_id: user_id, agent_id: agent.id, timestamp: DateTime.utc_now(), trigger: %{type: :wakeup}}

    %{user_id: user_id, agent: agent, state: state, context: context}
  end

  defp candidate_insight(user_id, agent_id, suffix) do
    {:ok, [insight]} =
      Insights.record_many(
        user_id,
        agent_id,
        [
          %{
            "source" => "local_patterns",
            "category" => "general",
            "title" => "Candidate #{suffix}",
            "summary" => "A candidate insight #{suffix}",
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
    assert length(pending_state.pending_candidates) == 1
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
             LocalPatternReview.handle_effect_result({:llm_call, response}, pending_state, context)

    assert payload.count == 1
    assert next_state.pending_candidates == []

    assert Insights.list_candidates_for_user(user_id) == []
    assert [%{id: kept_id, status: "new"}] = Insights.list_open_for_user(user_id)
    assert kept_id == keep.id
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

    assert next_state.pending_candidates == []
    assert length(Insights.list_candidates_for_user(user_id)) == 1
  end
end
