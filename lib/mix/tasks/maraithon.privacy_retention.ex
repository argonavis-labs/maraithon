defmodule Mix.Tasks.Maraithon.PrivacyRetention do
  use Mix.Task

  alias Maraithon.PrivacyRetention

  @shortdoc "Run bounded, content-free privacy retention operations"

  @moduledoc """
  Storage-only operator for retention preflight, cleanup, and bounded expiry.

      mix maraithon.privacy_retention preflight
      mix maraithon.privacy_retention run --batch-size 100 --per-tenant 5
      mix maraithon.privacy_retention handler effects --batch-size 25
      mix maraithon.privacy_retention cleanup-legacy --batch-size 100
      mix maraithon.privacy_retention finalize-constraints

  This task starts Ecto/Postgrex and the Repo only. It never boots the
  Maraithon supervision tree, Agents, schedulers, or background-job runner.
  Output contains counts, closed status/error codes, and timestamps only.
  """

  @switches [batch_size: :integer, per_tenant: :integer]
  @handlers %{
    "effects" => :effects,
    "directives" => :directives,
    "events" => :events,
    "run_steps" => :run_steps,
    "agent_runs" => :agent_runs,
    "assistant_runs" => :assistant_runs,
    "assistant_steps" => :assistant_steps,
    "prepared_actions" => :prepared_actions,
    "operator_events" => :operator_events,
    "background_jobs" => :background_jobs,
    "scheduled_jobs" => :scheduled_jobs,
    "ingress_receipts" => :ingress_receipts,
    "work_results" => :work_results,
    "snapshot_quarantines" => :snapshot_quarantines,
    "erasure_receipts" => :erasure_receipts,
    "telegram_conversations" => :telegram_conversations
  }

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("invalid privacy retention options")

    start_storage!()

    result =
      case argv do
        ["preflight"] -> PrivacyRetention.preflight()
        ["run"] -> PrivacyRetention.run_cycle(worker_opts(opts))
        ["handler", handler] -> run_handler(handler, opts)
        ["cleanup-legacy"] -> PrivacyRetention.cleanup_legacy_snapshot_reports(worker_opts(opts))
        ["finalize-constraints"] -> PrivacyRetention.finalize_constraints()
        _other -> Mix.raise(usage())
      end

    print_result!(result)
  end

  defp run_handler(handler, opts) do
    case Map.fetch(@handlers, handler) do
      {:ok, name} -> PrivacyRetention.run_handler(name, worker_opts(opts))
      :error -> {:error, :unknown_privacy_retention_handler}
    end
  end

  defp worker_opts(opts) do
    []
    |> maybe_put(:batch_size, opts[:batch_size])
    |> maybe_put(:per_tenant, opts[:per_tenant])
  end

  defp print_result!({:ok, result}) do
    result |> Jason.encode!(pretty: true) |> Mix.shell().info()
  end

  defp print_result!({:error, reason}) do
    Mix.raise("privacy retention failed: #{inspect(reason)}")
  end

  defp print_result!(other), do: print_result!({:ok, other})

  defp start_storage! do
    Mix.Task.run("app.config")

    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> Mix.raise("could not start privacy retention storage dependencies")
    end

    case Maraithon.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> Mix.raise("could not start privacy retention storage")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    """
    Usage:
      mix maraithon.privacy_retention preflight
      mix maraithon.privacy_retention run [--batch-size N] [--per-tenant N]
      mix maraithon.privacy_retention handler HANDLER [--batch-size N] [--per-tenant N]
      mix maraithon.privacy_retention cleanup-legacy [--batch-size N]
      mix maraithon.privacy_retention finalize-constraints
    """
  end
end
