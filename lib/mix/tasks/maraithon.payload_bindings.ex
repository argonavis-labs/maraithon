defmodule Mix.Tasks.Maraithon.PayloadBindings do
  @moduledoc """
  Rotates authenticated durable-payload binding metadata in bounded,
  evidence-bound batches, or performs a read-only global preflight.

  Production uses `VAULT_ROTATION_DATABASE_URL`, authenticated as the canonical
  incident-operator role. Vault ciphertext rotation is a separate operation;
  rotate both lifecycles as required before beginning key retirement.

  ## Usage

      mix maraithon.payload_bindings --old-tag TAG --preflight
      mix maraithon.payload_bindings --old-tag TAG --evidence-id ID \\
        --evidence-sha256 SHA256 --operator OPERATOR --revision REV \\
        [--batch-size N] [--max-batches N] [--table TABLE] \\
        [--binding payload|authority]
  """

  use Mix.Task

  alias Maraithon.DurablePayloadBindingRotation

  @shortdoc "Rotate authenticated durable-payload bindings"
  @switches [
    old_tag: :string,
    preflight: :boolean,
    batch_size: :integer,
    max_batches: :integer,
    table: :string,
    binding: :string,
    evidence_id: :string,
    evidence_sha256: :string,
    operator: :string,
    revision: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if argv != [] or invalid != [] or not is_binary(opts[:old_tag]), do: Mix.raise(usage())

    start_storage!()

    result =
      if opts[:preflight] do
        DurablePayloadBindingRotation.preflight(opts[:old_tag])
      else
        DurablePayloadBindingRotation.rotate(opts[:old_tag], rotation_opts(opts))
      end

    case result do
      {:ok, report} -> Mix.shell().info(Jason.encode!(report, pretty: true))
      {:error, reason} -> Mix.raise("binding-key operation failed: #{inspect(reason)}")
    end
  end

  defp rotation_opts(opts) do
    [
      evidence_id: opts[:evidence_id],
      evidence_digest: decode_sha256(opts[:evidence_sha256]),
      operator: opts[:operator],
      revision: opts[:revision]
    ]
    |> maybe_put(:limit, opts[:batch_size])
    |> maybe_put(:max_batches, opts[:max_batches])
    |> maybe_put(:table, opts[:table])
    |> maybe_put(:binding, opts[:binding])
  end

  defp start_storage! do
    Mix.Task.run("app.config")

    Maraithon.DatabaseTLS.configure_operator_repo_from_env!(
      "VAULT_ROTATION_DATABASE_URL",
      Mix.env() == :prod
    )

    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> Mix.raise("could not start binding rotation dependencies")
    end

    :ok = Maraithon.DurablePayloadBinding.validate_config!()
    start_once(Maraithon.Vault)
    start_once(Maraithon.Repo)
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
      {:error, _reason} -> Mix.raise("could not start binding rotation storage")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    """
    Usage:
      mix maraithon.payload_bindings --old-tag TAG --preflight
      mix maraithon.payload_bindings --old-tag TAG --evidence-id ID --evidence-sha256 SHA256 --operator OPERATOR --revision REV [--batch-size N] [--max-batches N] [--table TABLE] [--binding payload|authority]
    """
  end
end
