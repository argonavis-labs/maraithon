defmodule Maraithon.ChiefOfStaff.AcquisitionRun do
  @moduledoc """
  Durable bounded acquisition attempt whose sealed state proves complete or incomplete coverage.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(fetching incomplete complete failed cancelled)
  @failure_codes ~w(page_limit budget_exhausted provider_retryable consent_revoked claim_lost invalid_page provider_failed)

  schema "chief_acquisition_runs" do
    field :acquisition_key, :binary
    field :user_id, :string
    field :agent_id, :binary_id
    field :agent_directive_id, :binary_id
    field :runtime_ingress_receipt_id, :binary_id
    field :connected_account_id, :id
    field :source_cursor_id, :binary_id
    field :cursor_kind, :string
    field :provider, :string
    field :source, :string
    field :scope_key, :string
    field :request_key, :string
    field :request_fingerprint, :binary
    field :contract_version, :integer, default: 1
    field :status, :string, default: "fetching"
    field :start_cursor, :string
    field :proposed_cursor, :string
    field :continuation, :map
    field :pagination_exhausted, :boolean, default: false
    field :page_count, :integer, default: 0
    field :item_count, :integer, default: 0
    field :manifest_digest, :binary
    field :failure_code, :string
    field :started_at, :utc_datetime_usec
    field :sealed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def failure_codes, do: @failure_codes

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :id,
      :acquisition_key,
      :user_id,
      :agent_id,
      :agent_directive_id,
      :runtime_ingress_receipt_id,
      :connected_account_id,
      :source_cursor_id,
      :cursor_kind,
      :provider,
      :source,
      :scope_key,
      :request_key,
      :request_fingerprint,
      :contract_version,
      :status,
      :start_cursor,
      :proposed_cursor,
      :continuation,
      :pagination_exhausted,
      :page_count,
      :item_count,
      :manifest_digest,
      :failure_code,
      :started_at,
      :sealed_at,
      :inserted_at,
      :updated_at
    ])
    |> validate_required([
      :acquisition_key,
      :user_id,
      :agent_id,
      :agent_directive_id,
      :runtime_ingress_receipt_id,
      :connected_account_id,
      :provider,
      :source,
      :scope_key,
      :request_key,
      :request_fingerprint,
      :contract_version,
      :status,
      :pagination_exhausted,
      :page_count,
      :item_count,
      :started_at,
      :inserted_at,
      :updated_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:failure_code, @failure_codes)
    |> validate_number(:contract_version, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_number(:page_count, greater_than_or_equal_to: 0)
    |> validate_number(:item_count, greater_than_or_equal_to: 0)
    |> V.validate_digest(:acquisition_key)
    |> V.validate_digest(:request_fingerprint)
    |> V.validate_digest(:manifest_digest)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:provider, min: 1, max: 80)
    |> V.validate_bytes(:source, min: 1, max: 80)
    |> V.validate_bytes(:cursor_kind, min: 1, max: 80)
    |> V.validate_bytes(:scope_key, min: 1, max: 255)
    |> V.validate_bytes(:request_key, min: 1, max: 255)
    |> V.validate_bytes(:start_cursor, min: 1, max: 4096)
    |> V.validate_bytes(:proposed_cursor, min: 1, max: 4096)
    |> V.validate_object(:continuation)
    |> unique_constraint(:acquisition_key,
      name: :chief_acquisition_runs_acquisition_key_unique_index
    )
    |> unique_constraint([:agent_directive_id, :request_key],
      name: :chief_acquisition_runs_directive_request_unique_index
    )
    |> foreign_key_constraint(:agent_id, name: :chief_acquisition_runs_agent_owner_fkey)
    |> foreign_key_constraint(:agent_directive_id,
      name: :chief_acquisition_runs_directive_owner_fkey
    )
    |> foreign_key_constraint(:runtime_ingress_receipt_id,
      name: :chief_acquisition_runs_ingress_owner_fkey
    )
    |> foreign_key_constraint(:source_cursor_id,
      name: :chief_acquisition_runs_cursor_owner_fkey
    )
    |> check_constraint(:status, name: :chief_acquisition_runs_state_check)
    |> check_constraint(:source_cursor_id, name: :chief_acquisition_runs_cursor_shape_check)
    |> check_constraint(:failure_code, name: :chief_acquisition_runs_failure_code_check)
    |> check_constraint(:continuation, name: :chief_acquisition_runs_continuation_check)
    |> check_constraint(:manifest_digest, name: :chief_acquisition_runs_digest_check)
  end
end
