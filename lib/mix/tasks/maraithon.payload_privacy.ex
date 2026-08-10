defmodule Mix.Tasks.Maraithon.PayloadPrivacy do
  use Mix.Task

  alias Maraithon.DurablePayloadPrivacy

  @shortdoc "Preflight or backfill durable Event/RunStep payload encryption"

  @moduledoc """
  Runs the content-free Event and AgentRunStep payload encryption operator.

      mix maraithon.payload_privacy preflight
      mix maraithon.payload_privacy backfill --batch-size 25 --max-batches 20

  This task deliberately starts only Cloak's Vault and the Repo, not the
  Maraithon application/runtime fleet. Run it only in the stopped-legacy-fleet
  backfill phase. A production release can invoke the same content-free API
  from a controlled RPC:

      bin/maraithon rpc 'IO.inspect(Maraithon.DurablePayloadPrivacy.preflight())'
  """

  @switches [batch_size: :integer, max_batches: :integer, dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid payload privacy options")
    end

    start_storage!()

    case {argv, Keyword.get(opts, :dry_run, false)} do
      {[], true} -> print_preflight()
      {["preflight"], _dry_run} -> print_preflight()
      {["backfill"], true} -> print_preflight()
      {["backfill"], false} -> run_backfill(opts)
      _other -> Mix.raise(usage())
    end
  end

  defp print_preflight do
    DurablePayloadPrivacy.preflight()
    |> Jason.encode!(pretty: true)
    |> Mix.shell().info()
  end

  defp run_backfill(opts) do
    backfill_opts =
      []
      |> maybe_put(:batch_size, opts[:batch_size])
      |> maybe_put(:max_batches, opts[:max_batches])

    case DurablePayloadPrivacy.backfill(backfill_opts) do
      {:ok, result} ->
        result
        |> Jason.encode!(pretty: true)
        |> Mix.shell().info()

      {:error, reason} ->
        Mix.raise("durable payload backfill failed: #{inspect(reason)}")
    end
  end

  defp start_storage! do
    Mix.Task.run("app.config")

    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> Mix.raise("could not start durable payload storage dependencies")
    end

    start_once(Maraithon.Vault)
    start_once(Maraithon.Repo)
  end

  defp start_once(module) do
    case module.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> Mix.raise("could not start durable payload storage")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    """
    Usage:
      mix maraithon.payload_privacy preflight
      mix maraithon.payload_privacy backfill [--batch-size N] [--max-batches N]
      mix maraithon.payload_privacy backfill --dry-run
    """
  end
end
