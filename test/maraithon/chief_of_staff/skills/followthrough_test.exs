defmodule Maraithon.ChiefOfStaff.Skills.FollowthroughTest do
  use ExUnit.Case, async: true

  alias Maraithon.ChiefOfStaff.Skills.Followthrough

  # SPEC 07 R2: Followthrough must expose a real, emit-preserving error path
  # that delegates to InboxCalendarAdvisor.handle_effect_error/4 (the only
  # sub-behavior that ever originates an effect), mirroring the unconditional
  # delegation handle_effect_result/3 already uses — so a Gmail/Slack LLM
  # error no longer falls through to AIChiefOfStaff's generic skip.

  setup do
    %{
      state: Followthrough.init(%{"user_id" => "chief@example.com"}),
      context: %{user_id: "chief@example.com", timestamp: DateTime.utc_now()}
    }
  end

  test "handle_effect_error/4 is exported and delegates to InboxCalendarAdvisor", %{
    state: state,
    context: context
  } do
    assert function_exported?(Followthrough, :handle_effect_error, 4)

    # The advisor's pending emit survives the failed effect: it re-emits
    # with its own relationship_learning error annotation — proof the call
    # actually reached InboxCalendarAdvisor's error path.
    pending = {:insights_recorded, %{count: 1, user_id: "chief@example.com", categories: []}}
    state = put_in(state, [:inbox_state, :pending_emit], pending)

    assert {:emit, {:insights_recorded, payload}, next_state} =
             Followthrough.handle_effect_error(:llm_call, :rate_limited, state, context)

    assert payload.count == 1
    assert [%{type: "llm_call"}] = payload.relationship_learning.errors
    assert next_state.inbox_state.pending_emit == nil
  end

  test "a Followthrough-level pending Slack emit survives an inbox effect error", %{
    state: state,
    context: context
  } do
    pending =
      {:insights_recorded,
       %{count: 2, user_id: "chief@example.com", categories: ["reply_urgent"]}}

    state = %{state | pending_emit: pending}

    assert {:emit, {:insights_recorded, payload}, next_state} =
             Followthrough.handle_effect_error(:llm_call, :rate_limited, state, context)

    assert payload.count == 2
    assert payload.categories == ["reply_urgent"]
    assert next_state.pending_emit == nil
  end

  test "with nothing pending, an effect error resolves to idle with reset sub-state", %{
    state: state,
    context: context
  } do
    assert {:idle, next_state} =
             Followthrough.handle_effect_error(:llm_call, :rate_limited, state, context)

    assert next_state.pending_emit == nil
    assert next_state.inbox_state.pending_emit == nil
  end
end
