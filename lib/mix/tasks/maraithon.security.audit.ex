defmodule Mix.Tasks.Maraithon.Security.Audit do
  use Mix.Task

  @shortdoc "Audit Maraithon trust-layer security settings"

  @switches [
    env: :string,
    no_fail: :boolean
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

      audit_opts =
        []
        |> maybe_put(:env, opts[:env])

      result = Maraithon.SecurityAudit.run(audit_opts)
      Mix.shell().info(Jason.encode!(result, pretty: true))

      if result.status == "fail" and opts[:no_fail] != true do
        Mix.raise("Security audit failed.")
      end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    """
    Usage:
      mix maraithon.security.audit [--env dev|test|prod] [--no-fail]

    Prints severity, finding id, and remediation guidance. By default the task
    exits non-zero when high or critical findings are present.
    """
  end
end
