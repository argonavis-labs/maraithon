defmodule Maraithon.AssistantEvaluation do
  @moduledoc """
  Fixture-driven evaluation harness for core assistant trust behaviors.

  The harness starts with mocked model outputs. It is designed to make product
  behavior repeatable before adding more live model or connector surface area.
  """

  alias Maraithon.ActionLedger
  alias Maraithon.Todos.SurfaceQuality
  alias Maraithon.ToolPolicy
  alias Maraithon.ToolPolicy.Decision

  @fixture_dir "test/fixtures/assistant_scenarios"

  def load_fixture!(path) when is_binary(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> List.wrap()
  end

  def load_fixture_dir!(dir \\ @fixture_dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&load_fixture!/1)
  end

  def run_fixture(scenario, opts \\ [])

  def run_fixture(scenario, opts) when is_map(scenario) and is_list(opts) do
    expected = Map.get(scenario, "expected", %{})
    observed = Map.get(scenario, "mock_output", %{})

    output_diffs = diff(Map.get(expected, "output", %{}), observed)
    policy_result = evaluate_policy(Map.get(expected, "policy"), scenario)
    tool_result = evaluate_tool_usage(expected, observed)
    surface_result = evaluate_surface_quality(Map.get(expected, "surface_quality"), observed)
    ledger_result = maybe_record_ledger(expected, scenario, policy_result, opts)

    diffs =
      output_diffs
      |> Enum.concat(policy_result.diffs)
      |> Enum.concat(tool_result.diffs)
      |> Enum.concat(surface_result.diffs)
      |> Enum.concat(ledger_result.diffs)

    %{
      id: Map.get(scenario, "id"),
      category: Map.get(scenario, "category"),
      status: if(diffs == [], do: "passed", else: "failed"),
      diffs: diffs,
      observed: %{
        output: observed,
        policy: Map.take(policy_result, [:status, :reason_code]),
        tools: Map.take(tool_result, [:tools]),
        surface_quality: Map.get(surface_result, :quality),
        ledger: Map.take(ledger_result, [:event_type, :status, :action_id])
      }
    }
  end

  def run_fixture(_scenario, _opts) do
    %{
      id: nil,
      category: nil,
      status: "failed",
      diffs: [%{path: "$", expected: "scenario map", actual: "invalid"}],
      observed: %{}
    }
  end

  def run_fixtures(scenarios, opts \\ []) when is_list(scenarios) do
    scenarios
    |> Enum.map(&run_fixture(&1, opts))
    |> then(fn results ->
      %{
        status: if(Enum.all?(results, &(&1.status == "passed")), do: "passed", else: "failed"),
        summary: summarize(results),
        results: results
      }
    end)
  end

  def summarize(results) when is_list(results) do
    %{
      total: length(results),
      passed: Enum.count(results, &(&1.status == "passed")),
      failed: Enum.count(results, &(&1.status == "failed")),
      by_category:
        results
        |> Enum.group_by(& &1.category)
        |> Map.new(fn {category, category_results} ->
          {category,
           %{
             total: length(category_results),
             passed: Enum.count(category_results, &(&1.status == "passed")),
             failed: Enum.count(category_results, &(&1.status == "failed"))
           }}
        end)
    }
  end

  defp evaluate_policy(nil, _scenario), do: %{status: nil, reason_code: nil, diffs: []}

  defp evaluate_policy(%{} = expected_policy, scenario) do
    policy_input =
      scenario
      |> Map.get("policy_input", %{})
      |> Map.merge(Map.take(expected_policy, ["surface", "tool_name", "user_id", "arguments"]))
      |> maybe_put_confirmed(expected_policy)

    decision = ToolPolicy.authorize(policy_input)
    decision_map = Decision.to_map(decision)
    expected_status = Map.get(expected_policy, "expected_status")
    expected_reason = Map.get(expected_policy, "expected_reason_code")

    diffs =
      []
      |> maybe_diff("policy.status", expected_status, decision_map["status"])
      |> maybe_diff("policy.reason_code", expected_reason, decision_map["reason_code"])

    %{
      status: decision_map["status"],
      reason_code: decision_map["reason_code"],
      decision: decision_map,
      diffs: diffs
    }
  end

  defp maybe_record_ledger(expected, scenario, policy_result, opts) do
    ledger = Map.get(expected, "ledger")

    cond do
      ledger == nil ->
        %{event_type: nil, status: nil, action_id: nil, diffs: []}

      Keyword.get(opts, :record_ledger?, false) != true ->
        %{
          event_type: Map.get(ledger, "event_type"),
          status: Map.get(ledger, "status"),
          action_id: nil,
          diffs: []
        }

      true ->
        attrs = %{
          user_id: Map.get(ledger, "user_id") || scenario_user_id(scenario),
          surface: Map.get(ledger, "surface", "evaluation"),
          event_type: Map.fetch!(ledger, "event_type"),
          status: Map.fetch!(ledger, "status"),
          source_evidence: Map.get(scenario, "input", %{}),
          policy_decision: Map.get(policy_result, :decision, %{}),
          model_summary: Map.get(scenario, "summary") || Map.get(scenario, "id"),
          result_object_refs: Map.get(ledger, "result_object_refs", %{}),
          metadata: %{
            evaluation_id: Map.get(scenario, "id"),
            category: Map.get(scenario, "category")
          }
        }

        case ActionLedger.record(attrs) do
          {:ok, action} ->
            %{
              event_type: action.event_type,
              status: action.status,
              action_id: action.id,
              diffs: []
            }

          {:error, reason} ->
            %{
              event_type: Map.get(ledger, "event_type"),
              status: Map.get(ledger, "status"),
              action_id: nil,
              diffs: [%{path: "ledger", expected: "recorded", actual: inspect(reason)}]
            }
        end
    end
  end

  defp evaluate_tool_usage(expected, observed) when is_map(expected) and is_map(observed) do
    tools = observed_tools(observed)
    required = Map.get(expected, "required_tools", [])
    forbidden = Map.get(expected, "forbidden_tools", [])

    missing = Enum.reject(required, &(&1 in tools))
    present_forbidden = Enum.filter(forbidden, &(&1 in tools))

    diffs =
      []
      |> maybe_tool_diff("tools.required", missing, [])
      |> maybe_tool_diff("tools.forbidden", present_forbidden, [])

    %{tools: tools, diffs: diffs}
  end

  defp evaluate_tool_usage(_expected, _observed), do: %{tools: [], diffs: []}

  defp evaluate_surface_quality(nil, _observed), do: %{quality: nil, diffs: []}

  defp evaluate_surface_quality(expected, observed)
       when is_map(expected) and is_map(observed) do
    todo = Map.get(observed, "todo") || Map.get(observed, "linked_todo") || observed
    quality = SurfaceQuality.assess(todo)

    expected_surfaceable = Map.get(expected, "surfaceable")
    minimum_score = Map.get(expected, "minimum_score")

    diffs =
      []
      |> maybe_diff("surface_quality.surfaceable", expected_surfaceable, quality["surfaceable"])
      |> maybe_minimum_score_diff(minimum_score, quality["score"])

    %{quality: quality, diffs: diffs}
  end

  defp evaluate_surface_quality(_expected, _observed), do: %{quality: nil, diffs: []}

  defp observed_tools(observed) do
    direct =
      observed
      |> Map.get("tool_calls", [])
      |> List.wrap()
      |> Enum.map(fn
        %{"tool" => tool} when is_binary(tool) -> tool
        %{"name" => tool} when is_binary(tool) -> tool
        tool when is_binary(tool) -> tool
        _other -> nil
      end)

    sequence =
      observed
      |> Map.get("tool_sequence", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    (direct ++ sequence)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp maybe_tool_diff(diffs, _path, [], _expected), do: diffs

  defp maybe_tool_diff(diffs, path, actual, expected) do
    [%{path: path, expected: expected, actual: actual} | diffs]
  end

  defp maybe_minimum_score_diff(diffs, nil, _actual), do: diffs

  defp maybe_minimum_score_diff(diffs, minimum_score, actual)
       when is_integer(minimum_score) and is_integer(actual) do
    if actual >= minimum_score do
      diffs
    else
      [%{path: "surface_quality.score", expected: ">= #{minimum_score}", actual: actual} | diffs]
    end
  end

  defp maybe_minimum_score_diff(diffs, _minimum_score, _actual), do: diffs

  defp diff(expected, actual, path \\ "$")
  defp diff(nil, _actual, _path), do: []

  defp diff(%{} = expected, %{} = actual, path) do
    expected
    |> Enum.flat_map(fn {key, expected_value} ->
      diff(expected_value, Map.get(actual, key), "#{path}.#{key}")
    end)
  end

  defp diff(expected, actual, path) when is_list(expected) and is_list(actual) do
    if expected == actual do
      []
    else
      [%{path: path, expected: expected, actual: actual}]
    end
  end

  defp diff(expected, actual, path) do
    if expected == actual do
      []
    else
      [%{path: path, expected: expected, actual: actual}]
    end
  end

  defp maybe_diff(diffs, _path, nil, _actual), do: diffs
  defp maybe_diff(diffs, _path, _expected, nil), do: diffs

  defp maybe_diff(diffs, path, expected, actual) do
    if expected == actual do
      diffs
    else
      [%{path: path, expected: expected, actual: actual} | diffs]
    end
  end

  defp maybe_put_confirmed(policy_input, %{"confirmed" => confirmed}) do
    Map.put(policy_input, "confirmed?", confirmed)
  end

  defp maybe_put_confirmed(policy_input, _expected_policy), do: policy_input

  defp scenario_user_id(scenario) do
    get_in(scenario, ["input", "user_id"]) ||
      get_in(scenario, ["policy_input", "user_id"]) ||
      "assistant-evaluation@example.com"
  end
end
