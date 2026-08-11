defmodule Maraithon.Runtime.AgentWorkResult do
  @moduledoc """
  Transaction-local provisional then committed terminal proof for one exact directive claim.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.DurablePayload
  alias Maraithon.DurablePayloadBinding
  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(provisional committed)
  @outcomes ~w(completed failed dead_letter cancelled)

  schema "agent_work_results" do
    field :result_key, :binary
    field :agent_directive_id, :binary_id
    field :agent_id, :binary_id
    field :user_id, :string
    field :agent_run_id, :binary_id
    field :claim_generation, Ecto.UUID
    field :claim_token, Ecto.UUID
    field :status, :string, default: "provisional"
    field :outcome, :string
    field :terminal_event, :string
    field :result, Maraithon.Encrypted.Map, source: :result_ciphertext, redact: true
    field :legacy_result, :map, source: :result, default: %{}, redact: true
    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :result_purged_at, :utc_datetime_usec
    field :result_digest, :binary
    field :result_content_digest, :binary
    field :result_content_digest_version, :integer
    field :result_digest_version, :integer
    field :result_digest_key_tag, :string
    field :provisional_at, :utc_datetime_usec
    field :committed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def outcomes, do: @outcomes

  @doc false
  def payload_binding_spec do
    %{
      table: "agent_work_results",
      identity_fields: [:id],
      scope_fields: [:user_id, :agent_id, :agent_directive_id, :agent_run_id],
      fields: [:result],
      purge_field: :result_purged_at
    }
  end

  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :status,
      :outcome,
      :terminal_event,
      :result,
      :committed_at
    ])
    |> DurablePayload.put_bounded_map(:result, 128_000,
      max_binary_bytes: 100_000,
      max_depth: 12,
      max_nodes: 20_000,
      max_map_entries: 2_000,
      max_list_items: 5_000
    )
    |> mirror_legacy_result()
    |> put_payload_encryption_version()
    |> reactivate_result()
    |> put_authority_digest()
    |> validate_required([
      :result_key,
      :agent_directive_id,
      :agent_id,
      :user_id,
      :agent_run_id,
      :claim_generation,
      :claim_token,
      :status,
      :outcome,
      :terminal_event,
      :result,
      :result_digest,
      :provisional_at,
      :inserted_at,
      :updated_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:outcome, @outcomes)
    |> V.validate_digest(:result_key)
    |> V.validate_digest(:result_digest)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:terminal_event, min: 1, max: 80)
    |> V.validate_object(:result)
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
    |> unique_constraint(:result_key, name: :agent_work_results_result_key_unique_index)
    |> unique_constraint(:agent_directive_id,
      name: :agent_work_results_directive_unique_index
    )
    |> foreign_key_constraint(:agent_id, name: :agent_work_results_agent_owner_fkey)
    |> foreign_key_constraint(:agent_run_id, name: :agent_work_results_run_owner_fkey)
    |> foreign_key_constraint(:agent_directive_id,
      name: :agent_work_results_terminal_claim_fkey
    )
    |> check_constraint(:status, name: :agent_work_results_state_check)
    |> check_constraint(:result, name: :agent_work_results_result_check)
    |> check_constraint(:result_digest, name: :agent_work_results_digest_check)
  end

  @doc false
  def hydrate_result(work_result, mode \\ DurablePayload.mode!())

  def hydrate_result(%__MODULE__{} = work_result, mode) do
    :ok = DurablePayload.verify_binding!(work_result, payload_binding_spec(), mode)
    result = read_result!(work_result, mode)
    :ok = verify_authority_digest!(work_result, result, mode)
    %{work_result | result: result}
  end

  def hydrate_result(other, _mode), do: other

  def read_result!(%__MODULE__{result_purged_at: %DateTime{}, status: "committed"} = row, _mode) do
    if is_nil(row.result) and row.legacy_result == %{},
      do: %{},
      else: raise(ArgumentError, "purged AgentWorkResult is corrupt or inconsistent")
  end

  def read_result!(%__MODULE__{} = row, :legacy) do
    result = row.result || legacy_map(row.legacy_result)

    if json_map?(result),
      do: result,
      else: raise(ArgumentError, "AgentWorkResult is corrupt or inconsistent")
  end

  def read_result!(%__MODULE__{} = row, :exact) do
    if row.payload_encryption_version == 1 and json_map?(row.result) and
         row.legacy_result == %{} do
      row.result
    else
      raise ArgumentError, "exact AgentWorkResult is not ciphertext-only"
    end
  end

  defp put_authority_digest(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp put_authority_digest(changeset) do
    with true <- Map.has_key?(changeset.changes, :result),
         id when is_binary(id) <- get_field(changeset, :id) do
      scope =
        DurablePayload.context_identity([
          get_field(changeset, :user_id),
          get_field(changeset, :agent_id),
          get_field(changeset, :agent_directive_id),
          get_field(changeset, :agent_run_id)
        ])

      digest =
        DurablePayloadBinding.sign(
          "agent_work_result_authority",
          id,
          scope,
          [{"result", get_field(changeset, :result)}]
        )

      changeset
      |> put_change(:result_digest, digest.mac)
      |> put_change(:result_digest_version, digest.version)
      |> put_change(:result_digest_key_tag, digest.key_tag)
    else
      false -> changeset
      _missing_id -> add_error(changeset, :id, "must be generated before signing")
    end
  end

  defp verify_authority_digest!(
         %__MODULE__{
           status: "committed",
           result_purged_at: %DateTime{},
           result_digest: nil,
           result_digest_version: nil,
           result_digest_key_tag: nil,
           result_content_digest: content_digest,
           result_content_digest_version: content_digest_version
         },
         %{},
         mode
       )
       when mode in [:legacy, :exact] and content_digest_version == 0 and
              is_binary(content_digest) and byte_size(content_digest) == 32,
       do: :ok

  defp verify_authority_digest!(row, _result, :legacy)
       when is_nil(row.result_digest_version) and is_nil(row.result_digest_key_tag),
       do: :ok

  defp verify_authority_digest!(row, result, mode) when mode in [:legacy, :exact] do
    scope =
      DurablePayload.context_identity([
        row.user_id,
        row.agent_id,
        row.agent_directive_id,
        row.agent_run_id
      ])

    case Maraithon.DurablePayloadBinding.verify(
           "agent_work_result_authority",
           row.id,
           scope,
           [{"result", result}],
           row.result_digest_version,
           row.result_digest_key_tag,
           row.result_digest
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "AgentWorkResult authority digest failed: #{reason}"
    end
  end

  defp mirror_legacy_result(changeset) do
    case fetch_change(changeset, :result) do
      {:ok, result} ->
        put_change(
          changeset,
          :legacy_result,
          if(DurablePayload.legacy_write?(), do: result, else: %{})
        )

      :error ->
        changeset
    end
  end

  defp put_payload_encryption_version(changeset) do
    if Map.has_key?(changeset.changes, :result),
      do: put_change(changeset, :payload_encryption_version, 1),
      else: changeset
  end

  defp reactivate_result(changeset) do
    if changeset.data.result_purged_at && Map.has_key?(changeset.changes, :result),
      do: put_change(changeset, :result_purged_at, nil),
      else: changeset
  end

  defp legacy_map(value) when is_map(value) and not is_struct(value), do: value
  defp legacy_map(_value), do: nil
  defp json_map?(value), do: is_map(value) and not is_struct(value)
end
