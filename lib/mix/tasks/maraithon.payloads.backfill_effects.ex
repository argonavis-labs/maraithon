defmodule Mix.Tasks.Maraithon.Payloads.BackfillEffects do
  @moduledoc """
  Resumably encrypts and redacts legacy Effect payload columns before exact
  Effect protocol activation.

      mix maraithon.payloads.backfill_effects --batch-size 100
  """

  use Mix.Task

  @shortdoc "Backfills encrypted Effect payloads in bounded batches"

  @impl true
  def run(args) do
    start_storage_only!()

    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [batch_size: :integer], aliases: [b: :batch_size])

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix maraithon.payloads.backfill_effects [--batch-size N]")
    end

    batch_size = Keyword.get(opts, :batch_size, 100)

    unless is_integer(batch_size) and batch_size in 1..500 do
      Mix.raise("batch size must be between 1 and 500")
    end

    effect_total = backfill_all(batch_size, 0)
    directive_total = backfill_directives(batch_size, 0)

    Mix.shell().info(
      "Encrypted and redacted #{effect_total} Effect and #{directive_total} Directive payload row(s)."
    )
  end

  defp start_storage_only! do
    Mix.Task.run("app.config")

    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} -> :ok
      {:error, reason} -> Mix.raise("could not start Ecto SQL: #{inspect(reason)}")
    end

    case Maraithon.Vault.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> Mix.raise("could not start payload vault: #{inspect(reason)}")
    end

    case Maraithon.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> Mix.raise("could not start repository: #{inspect(reason)}")
    end
  end

  defp backfill_all(batch_size, total) do
    case Maraithon.Effects.backfill_legacy_payload_encryption(batch_size) do
      {:ok, 0} ->
        total

      {:ok, count} ->
        Mix.shell().info("Backfilled #{count} Effect payload row(s).")
        backfill_all(batch_size, total + count)

      {:error, reason} ->
        Mix.raise("Effect payload backfill failed: #{inspect(reason)}")
    end
  end

  defp backfill_directives(batch_size, total) do
    case Maraithon.Runtime.AgentDirectives.backfill_legacy_payload_encryption(batch_size) do
      {:ok, 0} ->
        total

      {:ok, count} ->
        Mix.shell().info("Backfilled #{count} Directive payload row(s).")
        backfill_directives(batch_size, total + count)

      {:error, reason} ->
        Mix.raise("Directive payload backfill failed: #{inspect(reason)}")
    end
  end
end
