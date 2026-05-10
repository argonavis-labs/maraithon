defmodule Mix.Tasks.Maraithon.Diagnostics.Export do
  use Mix.Task

  @shortdoc "Export a redacted Maraithon diagnostics bundle"

  @switches [
    output_dir: :string,
    user_id: :string,
    limit: :string
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

      opts =
        []
        |> maybe_put(:output_dir, opts[:output_dir])
        |> maybe_put(:user_id, opts[:user_id])
        |> maybe_put(:limit, opts[:limit])

      {:ok, result} = Maraithon.Diagnostics.Export.run(opts)
      Mix.shell().info(Jason.encode!(result, pretty: true))
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    """
    Usage:
      mix maraithon.diagnostics.export [--output-dir PATH] [--user-id USER_ID] [--limit N]

    Writes a redacted diagnostics directory. Raw prompts, webhook bodies, tool
    outputs, tokens, cookies, and authorization headers are excluded by default.
    """
  end
end
