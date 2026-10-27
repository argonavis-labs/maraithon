defmodule Mix.Tasks.Maraithon.PayloadPrivacy do
  use Mix.Task

  alias Maraithon.DurablePayloadPrivacy

  @shortdoc "Evidence-bound Event/RunStep/Snapshot payload contraction"
  @switches [
    batch_size: :integer,
    max_batches: :integer,
    dry_run: :boolean,
    confirm: :boolean,
    evidence_id: :string,
    evidence_sha256: :string,
    operator: :string,
    revision: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [], do: Mix.raise("invalid payload privacy options")

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
    unless opts[:confirm],
      do: Mix.raise("backfill requires --confirm after the non-rolling fleet is drained")

    backfill_opts =
      [
        confirmation: "NON_ROLLING_FLEET_DRAINED",
        evidence_id: opts[:evidence_id],
        evidence_digest: decode_sha256(opts[:evidence_sha256]),
        operator: opts[:operator],
        revision: opts[:revision]
      ]
      |> maybe_put(:batch_size, opts[:batch_size])
      |> maybe_put(:max_batches, opts[:max_batches])

    case DurablePayloadPrivacy.backfill(backfill_opts) do
      {:ok, result} -> Mix.shell().info(Jason.encode!(result, pretty: true))
      {:error, reason} -> Mix.raise("durable payload backfill failed: #{inspect(reason)}")
    end
  end

  defp start_storage! do
    Mix.Task.run("app.config")
    configure_activation_url!()

    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> Mix.raise("could not start durable payload storage dependencies")
    end

    :ok = Maraithon.DurablePayloadBinding.validate_config!()
    start_once(Maraithon.Vault)
    start_once(Maraithon.Repo)
  end

  defp configure_activation_url! do
    Maraithon.DatabaseTLS.configure_operator_repo_from_env!(
      "MARAITHON_ACTIVATION_DATABASE_URL",
      Mix.env() == :prod
    )
  end

  defp decode_sha256(nil), do: nil

  defp decode_sha256(value) do
    case Base.decode16(value, case: :lower) do
      {:ok, digest} when byte_size(digest) == 32 -> digest
      _invalid -> Mix.raise("--evidence-sha256 must be 64 lowercase hexadecimal characters")
    end
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
      mix maraithon.payload_privacy backfill --confirm --evidence-id ID --evidence-sha256 SHA256 --operator OPERATOR --revision REV [--batch-size N] [--max-batches N]
      mix maraithon.payload_privacy backfill --dry-run
    """
  end
end
