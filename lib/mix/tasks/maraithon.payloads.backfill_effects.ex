defmodule Mix.Tasks.Maraithon.Payloads.BackfillEffects do
  @moduledoc """
  Runs bounded Effect and Directive payload contraction only behind the exact
  stopped-fleet activation evidence recorded in PostgreSQL.
  """

  use Mix.Task

  alias Maraithon.DurablePayloadContraction

  @shortdoc "Evidence-bound Effect/Directive payload contraction"
  @switches [
    batch_size: :integer,
    max_batches: :integer,
    confirm: :boolean,
    evidence_id: :string,
    evidence_sha256: :string,
    operator: :string,
    revision: :string
  ]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: [b: :batch_size])

    if rest != [] or invalid != [] or not opts[:confirm], do: Mix.raise(usage())

    batch_size = Keyword.get(opts, :batch_size, 100)
    max_batches = Keyword.get(opts, :max_batches, 20)

    unless is_integer(batch_size) and batch_size in 1..500 and is_integer(max_batches) and
             max_batches in 1..1_000,
           do: Mix.raise(usage())

    evidence = [
      confirmation: "NON_ROLLING_FLEET_DRAINED",
      evidence_id: opts[:evidence_id],
      evidence_digest: decode_sha256(opts[:evidence_sha256]),
      operator: opts[:operator],
      revision: opts[:revision]
    ]

    start_storage_only!()

    case run_batches(evidence, batch_size, max_batches, %{batches: 0, effects: 0, directives: 0}) do
      {:ok, report} -> Mix.shell().info(Jason.encode!(report, pretty: true))
      {:error, reason} -> Mix.raise("payload contraction failed: #{inspect(reason)}")
    end
  end

  defp run_batches(_evidence, _limit, 0, report), do: {:ok, report}

  defp run_batches(evidence, limit, remaining, report) do
    case DurablePayloadContraction.transaction(evidence, fn ->
           effects = unwrap!(Maraithon.Effects.backfill_legacy_payload_encryption(limit))

           directives =
             unwrap!(Maraithon.Runtime.AgentDirectives.backfill_legacy_payload_encryption(limit))

           %{effects: effects, directives: directives}
         end) do
      {:ok, %{effects: 0, directives: 0}} ->
        {:ok, %{report | batches: report.batches + 1}}

      {:ok, batch} ->
        run_batches(evidence, limit, remaining - 1, %{
          batches: report.batches + 1,
          effects: report.effects + batch.effects,
          directives: report.directives + batch.directives
        })

      {:error, _reason} = error ->
        error
    end
  end

  defp unwrap!({:ok, count}), do: count
  defp unwrap!({:error, reason}), do: Maraithon.Repo.rollback(reason)

  defp start_storage_only! do
    Mix.Task.run("app.config")
    configure_activation_url!()

    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> Mix.raise("could not start Ecto SQL")
    end

    :ok = Maraithon.DurablePayloadBinding.validate_config!()
    start_once(Maraithon.Vault)
    start_once(Maraithon.Repo)
  end

  defp configure_activation_url! do
    url = System.get_env("MARAITHON_ACTIVATION_DATABASE_URL")

    if Mix.env() == :prod and (is_nil(url) or String.trim(url) == "") do
      Mix.raise("MARAITHON_ACTIVATION_DATABASE_URL is required in production")
    end

    if is_binary(url) and String.trim(url) != "" do
      if url == System.get_env("DATABASE_URL") do
        Mix.raise("MARAITHON_ACTIVATION_DATABASE_URL must be distinct from runtime DATABASE_URL")
      end

      :ok = Maraithon.DatabaseTLS.configure_repo!(url, "MARAITHON_ACTIVATION_DATABASE_URL")
    end
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
      {:error, _reason} -> Mix.raise("could not start payload contraction storage")
    end
  end

  defp usage do
    """
    Usage:
      mix maraithon.payloads.backfill_effects --confirm --evidence-id ID --evidence-sha256 SHA256 --operator OPERATOR --revision REV [--batch-size N] [--max-batches N]
    """
  end
end
