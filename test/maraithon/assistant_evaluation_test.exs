defmodule Maraithon.AssistantEvaluationTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.AssistantEvaluation

  test "loads and passes the seed assistant trust fixtures" do
    scenarios = AssistantEvaluation.load_fixture_dir!()

    assert length(scenarios) == 60

    result = AssistantEvaluation.run_fixtures(scenarios, record_ledger?: true)

    assert result.status == "passed"
    assert result.summary.total == 60
    assert result.summary.failed == 0
    assert result.summary.by_category["gmail_triage"].total == 10
    assert result.summary.by_category["relationship_learning"].total == 10
    assert result.summary.by_category["proactive_send_hold"].total == 10
    assert result.summary.by_category["correction_to_memory"].total == 10
    assert result.summary.by_category["confirmation_required"].total == 10
    assert result.summary.by_category["chief_of_staff_replay"].total == 10
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

  test "reports weak assistant reply quality when a fixture requires useful copy" do
    scenario = %{
      "id" => "weak_reply",
      "category" => "chief_of_staff_replay",
      "mock_output" => %{
        "message_class" => "assistant_reply",
        "assistant_message" => "Here is a clearer version.",
        "tool_calls" => []
      },
      "expected" => %{
        "output" => %{"message_class" => "assistant_reply"},
        "assistant_message_quality" => %{
          "min_length" => 80,
          "required_phrases" => ["send me the sentence", "audience or tone"],
          "forbidden_phrases" => ["here is a clearer version"]
        }
      }
    }

    result = AssistantEvaluation.run_fixture(scenario)

    assert result.status == "failed"
    assert Enum.any?(result.diffs, &(&1.path == "assistant_message.min_length"))
    assert Enum.any?(result.diffs, &(&1.path == "assistant_message.required_phrases"))
    assert Enum.any?(result.diffs, &(&1.path == "assistant_message.forbidden_phrases"))
  end
end
