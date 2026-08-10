defmodule Mix.Tasks.Maraithon.Payloads.Verify do
  @moduledoc """
  Authenticates and proves bounded durable ciphertext batches without starting
  the runtime fleet.

      mix maraithon.payloads.verify --preflight
      mix maraithon.payloads.verify --table events --batch-size 25 --max-batches 20

  Production releases can invoke `Maraithon.DurablePayloadVerification`
  through the same storage-only operator environment. Reports contain only
  counts, row IDs, key tags, and closed failure classes.
  """

  use Mix.Task

  alias Maraithon.DurablePayloadVerification

  @shortdoc "Authenticate and prove encrypted durable payloads"
  @switches [preflight: :boolean, table: :string, batch_size: :integer, max_batches: :integer]

  @impl Mix.Task
  def run(args) do
    {parsed, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] or argv != [] do
      Mix.raise(usage())
    end

    start_storage_only!()

    result =
      if parsed[:preflight] do
        DurablePayloadVerification.preflight()
      else
        opts =
          []
          |> maybe_put(:limit, parsed[:batch_size])
          |> maybe_put(:max_batches, parsed[:max_batches])
          |> maybe_put_tables(parsed[:table])

        DurablePayloadVerification.verify(opts)
      end

    case result do
      {:ok, report} -> Mix.shell().info(Jason.encode!(report, pretty: true))
      {:error, reason} -> Mix.raise("Payload verification failed: #{inspect(reason)}")
    end
  end

  defp start_storage_only! do
    Mix.Task.run("app.config")

    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> Mix.raise("could not start payload verification dependencies")
    end

    start_once(Maraithon.Vault)
    start_once(Maraithon.Repo)
  end

  defp start_once(module) do
    case module.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> Mix.raise("could not start payload verification storage")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
  defp maybe_put_tables(opts, nil), do: opts

  defp maybe_put_tables(opts, table) do
    if table in DurablePayloadVerification.tables(),
      do: Keyword.put(opts, :tables, [table]),
      else: Mix.raise(usage())
  end

  defp usage do
    """
    Usage:
      mix maraithon.payloads.verify --preflight
      mix maraithon.payloads.verify [--table TABLE] [--batch-size N] [--max-batches N]
    """
  end
end
