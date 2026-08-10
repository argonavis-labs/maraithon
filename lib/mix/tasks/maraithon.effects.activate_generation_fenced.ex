defmodule Mix.Tasks.Maraithon.Effects.ActivateGenerationFenced do
  use Mix.Task

  alias Maraithon.Effects.ProtocolCutover

  @shortdoc "Irreversibly activates generation-fenced Effect execution"

  @moduledoc """
  Performs the stopped-fleet, database-authoritative Effect protocol cutover:

      mix maraithon.effects.activate_generation_fenced \
        --confirm NON_ROLLING_FLEET_DRAINED \
        --evidence-id drain-2026-08-10 \
        --evidence-sha256 <64-lowercase-hex> \
        --revision <exact-release-git-sha>

  This canonical task starts only Ecto migration dependencies and
  `Maraithon.Repo`—never `Maraithon.Application` or its runtime workers. The
  barrier takes writer-blocking, reader-compatible locks, revalidates the
  recorded exact-index migration and definitions, and has no downgrade path.

  `--lock-timeout-ms` may override the bounded 15-second lock wait. A timeout
  refuses activation and is safe to retry after investigating the blocker.
  """

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          confirm: :string,
          lock_timeout_ms: :integer,
          evidence_id: :string,
          evidence_sha256: :string,
          revision: :string
        ],
        aliases: [c: :confirm]
      )

    if rest != [] or invalid != [] do
      Mix.raise("unexpected activation arguments")
    end

    activation_opts =
      [confirmation: opts[:confirm]]
      |> maybe_put(:lock_timeout_ms, opts[:lock_timeout_ms])
      |> maybe_put(:evidence_id, opts[:evidence_id])
      |> maybe_put(:evidence_digest, decode_sha256(opts[:evidence_sha256]))
      |> maybe_put(:revision, opts[:revision])

    result =
      case Ecto.Migrator.with_repo(Maraithon.Repo, fn _repo ->
             ProtocolCutover.activate(activation_opts)
           end) do
        {:ok, activation_result, _started_apps} -> activation_result
        {:error, reason} -> {:error, {:repository_start_failed, reason}}
      end

    case result do
      {:ok, :activated} ->
        Mix.shell().info("Generation-fenced Effect execution activated")

      {:ok, :already_active} ->
        Mix.shell().info("Generation-fenced Effect execution already active")

      {:error, reason} ->
        Mix.raise("Effect protocol activation refused: #{inspect(reason)}")
    end
  end

  defp decode_sha256(nil), do: nil

  defp decode_sha256(value) when is_binary(value) do
    case Base.decode16(value, case: :lower) do
      {:ok, digest} when byte_size(digest) == 32 ->
        digest

      _invalid ->
        Mix.raise("--evidence-sha256 must be exactly 64 lowercase hexadecimal characters")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
