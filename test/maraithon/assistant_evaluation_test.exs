defmodule Maraithon.AssistantEvaluationTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.AssistantEvaluation

  test "loads and passes the seed assistant trust fixtures" do
    scenarios = AssistantEvaluation.load_fixture_dir!()

    assert length(scenarios) == 50

    result = AssistantEvaluation.run_fixtures(scenarios, record_ledger?: true)

    assert result.status == "passed"
    assert result.summary.total == 50
    assert result.summary.failed == 0
    assert result.summary.by_category["gmail_triage"].total == 10
    assert result.summary.by_category["relationship_learning"].total == 10
    assert result.summary.by_category["proactive_send_hold"].total == 10
    assert result.summary.by_category["correction_to_memory"].total == 10
    assert result.summary.by_category["confirmation_required"].total == 10
  end

  test "reports behavior diffs with concrete paths" do
    [scenario | _] =
      AssistantEvaluation.load_fixture!("test/fixtures/assistant_scenarios/gmail_triage.json")

    broken =
      put_in(
        scenario,
        ["mock_output", "decision"],
        "ignore_noise"
      )

    result = AssistantEvaluation.run_fixture(broken)

    assert result.status == "failed"

    assert [%{path: "$.decision", expected: "create_todo", actual: "ignore_noise"} | _] =
             result.diffs
  end
end
