defmodule Mix.Tasks.Maraithon.MorningBriefing.Verify do
  use Mix.Task

  @shortdoc "Verify morning briefing generation readiness"

  @switches [
    agent_id: :string,
    user_id: :string,
    limit: :string,
    fail_on_issues: :boolean
  ]

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise(
        "Invalid options: #{Enum.map_join(invalid, ", ", fn {key, _value} -> "--#{key}" end)}"
      )
    end

    if argv not in [[], ["help"]] do
      Mix.raise(usage())
    end

    if argv == ["help"] do
      Mix.shell().info(usage())
    else
      Mix.Task.run("app.start")

      report =
        Maraithon.ChiefOfStaff.MorningBriefingVerifier.verify(
          []
          |> maybe_put(:agent_id, opts[:agent_id])
          |> maybe_put(:user_id, opts[:user_id])
          |> maybe_put(:recent_limit, opts[:limit])
        )

      Mix.shell().info(Jason.encode!(report, pretty: true))

      if opts[:fail_on_issues] && report["status"] != "ok" do
        exit({:shutdown, 1})
      end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    """
    Usage:
      mix maraithon.morning_briefing.verify [--agent-id ID] [--user-id USER_ID] [--limit N] [--fail-on-issues]

    Checks active Chief of Staff morning briefing configuration and recent
    persisted brief failures. The task never calls an LLM or prints API keys.
    """
  end
end
