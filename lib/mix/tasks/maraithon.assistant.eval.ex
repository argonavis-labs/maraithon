defmodule Mix.Tasks.Maraithon.Assistant.Eval do
  @moduledoc """
  Runs fixture-backed chief-of-staff assistant replay evaluations.
  """

  use Mix.Task

  @shortdoc "Run assistant replay eval fixtures"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          dir: :string,
          json: :boolean,
          fail_on_issues: :boolean,
          record_ledger: :boolean
        ]
      )

    if opts[:record_ledger] do
      Mix.Task.run("app.start")
    end

    scenarios =
      opts
      |> Keyword.get(:dir, "test/fixtures/assistant_scenarios")
      |> Maraithon.AssistantEvaluation.load_fixture_dir!()

    result =
      Maraithon.AssistantEvaluation.run_fixtures(scenarios,
        record_ledger?: opts[:record_ledger] == true
      )

    if opts[:json] do
      Mix.shell().info(Jason.encode!(result, pretty: true))
    else
      Mix.shell().info(format_summary(result))
    end

    if opts[:fail_on_issues] == true and result.status != "passed" do
      Mix.raise("assistant eval failed")
    end
  end

  defp format_summary(%{summary: summary, status: status, results: results}) do
    failing =
      results
      |> Enum.filter(&(&1.status != "passed"))
      |> Enum.map(fn result ->
        "- #{result.id}: #{Enum.map_join(result.diffs, "; ", &format_diff/1)}"
      end)
      |> Enum.join("\n")

    """
    assistant_eval=#{status}
    total=#{summary.total} passed=#{summary.passed} failed=#{summary.failed}
    #{failing}
    """
  end

  defp format_diff(%{path: path, expected: expected, actual: actual}) do
    "#{path} expected #{inspect(expected)} got #{inspect(actual)}"
  end

  defp format_diff(diff), do: inspect(diff)
end
