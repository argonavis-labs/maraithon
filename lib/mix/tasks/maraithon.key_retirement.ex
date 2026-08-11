defmodule Mix.Tasks.Maraithon.KeyRetirement do
  @moduledoc """
  Establishes evidence-bound, backup-aware authorization to retire a Vault or
  payload-binding key tag.

  The lifecycle is deliberately separate from rotation: record a zero-reference
  proof, attest backup/WAL/PITR and restore-drill evidence, run preflight, then
  persist final authorization with `authorize --confirm`. Preflight alone never
  authorizes removal.

  Production uses `VAULT_ROTATION_DATABASE_URL`, authenticated as the canonical
  incident-operator role. Run `mix help maraithon.key_retirement` together with
  the durable-payload operations guide for the required evidence arguments.
  """

  use Mix.Task

  alias Maraithon.KeyRetirement

  @shortdoc "Prove, attest, preflight, and authorize backup-aware key retirement"
  @switches [
    kind: :string,
    old_tag: :string,
    confirm: :boolean,
    proof_id: :string,
    backup_evidence_id: :string,
    evidence_id: :string,
    evidence_sha256: :string,
    operator: :string,
    revision: :string,
    backup_catalog_sha256: :string,
    backup_catalog_captured_at: :string,
    backup_oldest_recoverable_at: :string,
    wal_catalog_sha256: :string,
    wal_catalog_captured_at: :string,
    wal_oldest_recoverable_at: :string,
    pitr_catalog_sha256: :string,
    pitr_catalog_captured_at: :string,
    pitr_oldest_recoverable_at: :string,
    restore_drill_sha256: :string,
    restore_drill_completed_at: :string,
    restore_drill_recovered_through_at: :string,
    evidence_expires_at: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    with [operation] <- argv,
         true <- invalid == [],
         {:ok, kind} <- parse_kind(opts[:kind]),
         old_tag when is_binary(old_tag) <- opts[:old_tag] do
      start_storage!()
      run_operation(operation, kind, old_tag, opts)
    else
      _invalid -> Mix.raise(usage())
    end
  end

  defp run_operation("prove-zero", kind, old_tag, opts) do
    require_confirmation!(opts)
    print_result(KeyRetirement.prove_live_zero(kind, old_tag, evidence_opts(opts)))
  end

  defp run_operation("attest-backup", kind, old_tag, opts) do
    require_confirmation!(opts)

    print_result(KeyRetirement.attest_backup_evidence(kind, old_tag, backup_opts(opts)))
  end

  defp run_operation("preflight", kind, old_tag, opts) do
    print_result(KeyRetirement.retirement_preflight(kind, old_tag, preflight_opts(opts)))
  end

  defp run_operation("authorize", kind, old_tag, opts) do
    require_confirmation!(opts)

    retirement_opts =
      preflight_opts(opts) ++ [confirmation: "AUTHORIZE_EXTERNAL_KEY_REMOVAL"]

    print_result(KeyRetirement.authorize_retirement(kind, old_tag, retirement_opts))
  end

  defp run_operation(_operation, _kind, _old_tag, _opts), do: Mix.raise(usage())

  defp evidence_opts(opts) do
    [
      evidence_id: opts[:evidence_id],
      evidence_digest: decode_sha256(opts[:evidence_sha256], "--evidence-sha256"),
      operator: opts[:operator],
      revision: opts[:revision]
    ]
  end

  defp preflight_opts(opts) do
    evidence_opts(opts) ++
      [proof_id: opts[:proof_id], backup_evidence_id: opts[:backup_evidence_id]]
  end

  defp backup_opts(opts) do
    evidence_opts(opts) ++
      [
        proof_id: opts[:proof_id],
        backup_catalog_digest:
          decode_sha256(opts[:backup_catalog_sha256], "--backup-catalog-sha256"),
        backup_catalog_captured_at:
          parse_datetime(opts[:backup_catalog_captured_at], "--backup-catalog-captured-at"),
        backup_oldest_recoverable_at:
          parse_datetime(
            opts[:backup_oldest_recoverable_at],
            "--backup-oldest-recoverable-at"
          ),
        wal_catalog_digest: decode_sha256(opts[:wal_catalog_sha256], "--wal-catalog-sha256"),
        wal_catalog_captured_at:
          parse_datetime(opts[:wal_catalog_captured_at], "--wal-catalog-captured-at"),
        wal_oldest_recoverable_at:
          parse_datetime(opts[:wal_oldest_recoverable_at], "--wal-oldest-recoverable-at"),
        pitr_catalog_digest: decode_sha256(opts[:pitr_catalog_sha256], "--pitr-catalog-sha256"),
        pitr_catalog_captured_at:
          parse_datetime(opts[:pitr_catalog_captured_at], "--pitr-catalog-captured-at"),
        pitr_oldest_recoverable_at:
          parse_datetime(opts[:pitr_oldest_recoverable_at], "--pitr-oldest-recoverable-at"),
        restore_drill_digest:
          decode_sha256(opts[:restore_drill_sha256], "--restore-drill-sha256"),
        restore_drill_completed_at:
          parse_datetime(opts[:restore_drill_completed_at], "--restore-drill-completed-at"),
        restore_drill_recovered_through_at:
          parse_datetime(
            opts[:restore_drill_recovered_through_at],
            "--restore-drill-recovered-through-at"
          ),
        evidence_expires_at: parse_datetime(opts[:evidence_expires_at], "--evidence-expires-at")
      ]
  end

  defp parse_kind("vault"), do: {:ok, :vault}
  defp parse_kind("binding"), do: {:ok, :binding}
  defp parse_kind(_kind), do: :error

  defp decode_sha256(nil, _flag), do: nil

  defp decode_sha256(value, flag) do
    case Base.decode16(value, case: :lower) do
      {:ok, digest} when byte_size(digest) == 32 -> digest
      _invalid -> Mix.raise("#{flag} must be 64 lowercase hexadecimal characters")
    end
  end

  defp parse_datetime(nil, _flag), do: nil

  defp parse_datetime(value, flag) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> datetime
      _invalid -> Mix.raise("#{flag} must be an ISO 8601 UTC timestamp")
    end
  end

  defp require_confirmation!(opts) do
    unless opts[:confirm], do: Mix.raise("operation requires --confirm")
  end

  defp print_result({:ok, report}), do: Mix.shell().info(Jason.encode!(report, pretty: true))
  defp print_result({:error, reason}), do: Mix.raise("key retirement failed: #{inspect(reason)}")

  defp start_storage! do
    Mix.Task.run("app.config")

    Maraithon.DatabaseTLS.configure_operator_repo_from_env!(
      "VAULT_ROTATION_DATABASE_URL",
      Mix.env() == :prod
    )

    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> Mix.raise("could not start key-retirement dependencies")
    end

    :ok = Maraithon.DurablePayloadBinding.validate_config!()
    start_once(Maraithon.Vault)
    start_once(Maraithon.Repo)
  end

  defp start_once(module) do
    case module.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> Mix.raise("could not start key-retirement storage")
    end
  end

  defp usage do
    """
    Usage:
      mix maraithon.key_retirement prove-zero --confirm --kind vault|binding --old-tag TAG --evidence-id ID --evidence-sha256 SHA256 --operator OPERATOR --revision REV
      mix maraithon.key_retirement attest-backup --confirm --kind vault|binding --old-tag TAG --proof-id UUID --evidence-id ID --evidence-sha256 SHA256 --operator OPERATOR --revision REV --backup-catalog-sha256 SHA256 --backup-catalog-captured-at UTC --backup-oldest-recoverable-at UTC --wal-catalog-sha256 SHA256 --wal-catalog-captured-at UTC --wal-oldest-recoverable-at UTC --pitr-catalog-sha256 SHA256 --pitr-catalog-captured-at UTC --pitr-oldest-recoverable-at UTC --restore-drill-sha256 SHA256 --restore-drill-completed-at UTC --restore-drill-recovered-through-at UTC --evidence-expires-at UTC
      mix maraithon.key_retirement preflight --kind vault|binding --old-tag TAG --proof-id UUID --backup-evidence-id ID --evidence-id ID --evidence-sha256 SHA256 --operator OPERATOR --revision REV
      mix maraithon.key_retirement authorize --confirm --kind vault|binding --old-tag TAG --proof-id UUID --backup-evidence-id ID --evidence-id ID --evidence-sha256 SHA256 --operator OPERATOR --revision REV
    """
  end
end
