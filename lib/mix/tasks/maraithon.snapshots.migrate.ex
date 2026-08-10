defmodule Mix.Tasks.Maraithon.Snapshots.Migrate do
  @moduledoc """
  Bounded, resumable migration of Agent snapshots to tagged JSON v1.

      mix maraithon.snapshots.migrate --preflight
      mix maraithon.snapshots.migrate --batch-size 25 --max-batches 100
      mix maraithon.snapshots.migrate --after-id 12345 --max-batches 100
      mix maraithon.snapshots.migrate --finalize

  Each conversion result prints `next_cursor`. Reusing that cursor resumes after
  the last committed row; restarting at zero is also safe and revalidates v1
  rows. `--finalize` only succeeds after conversion and global retention counts
  are zero, and is the step that validates the tagged-v1 database constraint.

  Production releases do not contain Mix. The same safe functions are callable
  through release RPC: `Maraithon.Runtime.SnapshotMigration.preflight/0`,
  `migrate/1`, and `finalize/0`.
  """

  use Mix.Task

  alias Maraithon.Runtime.SnapshotMigration

  @shortdoc "Migrate legacy Agent snapshots to bounded tagged JSON v1"
  @switches [
    preflight: :boolean,
    finalize: :boolean,
    batch_size: :integer,
    prune_batch_size: :integer,
    max_batches: :integer,
    after_id: :integer,
    json: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {parsed, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] or argv != [] or (parsed[:preflight] == true and parsed[:finalize] == true) do
      Mix.raise(usage())
    end

    # An operator migration process must not boot periodic producers or Agent
    # workers alongside the already-running production node.
    Application.put_env(:maraithon, :start_background_workers, false)
    Mix.Task.run("app.start")

    opts =
      []
      |> maybe_put(:batch_size, parsed[:batch_size])
      |> maybe_put(:prune_batch_size, parsed[:prune_batch_size])
      |> maybe_put(:max_batches, parsed[:max_batches])
      |> maybe_put(:after_id, parsed[:after_id])

    result =
      cond do
        parsed[:preflight] == true -> SnapshotMigration.preflight(opts)
        parsed[:finalize] == true -> SnapshotMigration.finalize(opts)
        true -> SnapshotMigration.migrate(opts)
      end

    case result do
      {:ok, report} ->
        print_report(report, parsed[:json] == true)

      {:error, {:snapshot_preflight_not_clean, report}} ->
        print_report(report, parsed[:json] == true)
        Mix.raise("Snapshot format proof is not clean; rerun the bounded migration.")

      {:error, reason} ->
        Mix.raise("Snapshot migration failed: #{Maraithon.Redaction.error_class(reason)}")
    end
  end

  defp print_report(report, _json?) do
    Mix.shell().info(Jason.encode!(report, pretty: true))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    """
    Usage:
      mix maraithon.snapshots.migrate --preflight [--batch-size N]
      mix maraithon.snapshots.migrate [--after-id ID] [--batch-size N] [--max-batches N]
      mix maraithon.snapshots.migrate --finalize [--batch-size N]
    """
  end
end
