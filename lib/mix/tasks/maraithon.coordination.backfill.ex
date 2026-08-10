defmodule Mix.Tasks.Maraithon.Coordination.Backfill do
  use Mix.Task
  alias Maraithon.Runtime.Coordination.Backfill
  @shortdoc "Backfills runtime partitions in bounded SKIP LOCKED batches"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [batch_size: :integer])
    if rest != [] or invalid != [], do: Mix.raise("unexpected backfill arguments")
    limit = opts[:batch_size] || 100

    result = Ecto.Migrator.with_repo(Maraithon.Repo, fn _ -> drain(limit, 0) end)

    case result do
      {:ok, summary, _} ->
        Mix.shell().info("Runtime partition backfill complete: #{inspect(summary)}")

      {:error, reason} ->
        Mix.raise("Runtime partition backfill failed: #{inspect(reason)}")
    end
  end

  defp drain(limit, batches) do
    case Backfill.run_batch(limit) do
      {:ok, %{background_jobs: 0, scheduled_jobs: 0}} ->
        case Backfill.remaining() do
          {:ok, %{background_jobs: 0, scheduled_jobs: 0} = remaining} ->
            case Backfill.finalize() do
              {:ok, :finalized} ->
                %{batches: batches, remaining: remaining, catalog_finalized: true}

              {:error, reason} ->
                Mix.raise("partition catalog finalization failed: #{inspect(reason)}")
            end

          {:ok, remaining} ->
            Mix.raise("partition backfill made no progress: #{inspect(remaining)}")

          {:error, reason} ->
            Mix.raise("partition backfill inspection failed: #{inspect(reason)}")
        end

      {:ok, _counts} ->
        drain(limit, batches + 1)

      {:error, reason} ->
        Mix.raise("partition backfill batch failed: #{inspect(reason)}")
    end
  end
end
