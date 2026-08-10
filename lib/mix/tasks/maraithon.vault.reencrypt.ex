defmodule Mix.Tasks.Maraithon.Vault.Reencrypt do
  use Mix.Task

  alias Maraithon.VaultReencryption

  @shortdoc "Bounded global Vault key rotation and old-tag-zero proof"
  @switches [
    old_tag: :string,
    preflight: :boolean,
    retire: :boolean,
    batch_size: :integer,
    max_batches: :integer,
    target: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if argv != [] or invalid != [] or not is_binary(opts[:old_tag]) do
      Mix.raise(usage())
    end

    start_storage_only!()

    result =
      cond do
        opts[:retire] -> VaultReencryption.retirement_preflight(opts[:old_tag])
        opts[:preflight] -> VaultReencryption.preflight(opts[:old_tag])
        true -> VaultReencryption.reencrypt(opts[:old_tag], reencryption_opts(opts))
      end

    case result do
      {:ok, report} -> Mix.shell().info(Jason.encode!(report, pretty: true))
      {:error, reason} -> Mix.raise("Vault operation failed: #{inspect(reason)}")
    end
  end

  defp reencryption_opts(opts) do
    []
    |> maybe_put(:limit, opts[:batch_size])
    |> maybe_put(:max_batches, opts[:max_batches])
    |> maybe_put(:target, parse_target(opts[:target]))
  end

  defp parse_target(nil), do: nil

  defp parse_target(value) when is_binary(value) do
    case String.split(value, ".", parts: 2) do
      [table, column] when table != "" and column != "" -> {table, column}
      _invalid -> Mix.raise(usage())
    end
  end

  defp start_storage_only! do
    Mix.Task.run("app.config")
    configure_operator_url!()

    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> Mix.raise("could not start Vault rotation dependencies")
    end

    start_once(Maraithon.Vault)
    start_once(Maraithon.Repo)
  end

  defp configure_operator_url! do
    Maraithon.DatabaseTLS.configure_operator_repo_from_env!(
      "VAULT_ROTATION_DATABASE_URL",
      Mix.env() == :prod
    )
  end

  defp start_once(module) do
    case module.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> Mix.raise("could not start Vault rotation storage")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    """
    Usage:
      mix maraithon.vault.reencrypt --old-tag TAG [--batch-size N] [--max-batches N]
      mix maraithon.vault.reencrypt --old-tag TAG --target table.column
      mix maraithon.vault.reencrypt --old-tag TAG --preflight
      mix maraithon.vault.reencrypt --old-tag TAG --retire
    """
  end
end
