defmodule Maraithon.Connectors.SourceCursorAdvancement do
  @moduledoc """
  Immutable compare-and-set proof for a production source cursor advancement.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "source_cursor_advancements" do
    field :advance_key, :binary
    field :agent_work_result_id, :binary_id
    field :acquisition_run_id, :binary_id
    field :source_cursor_id, :binary_id
    field :user_id, :string
    field :agent_id, :binary_id
    field :connected_account_id, :id
    field :provider, :string
    field :provider_account_key, :string
    field :cursor_kind, :string
    field :expected_value, :string
    field :advanced_value, :string
    field :advance_digest, :binary
    field :advanced_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(advancement, attrs) do
    advancement
    |> cast(attrs, [
      :id,
      :advance_key,
      :agent_work_result_id,
      :acquisition_run_id,
      :source_cursor_id,
      :user_id,
      :agent_id,
      :connected_account_id,
      :provider,
      :provider_account_key,
      :cursor_kind,
      :expected_value,
      :advanced_value,
      :advance_digest,
      :advanced_at,
      :inserted_at
    ])
    |> validate_required([
      :advance_key,
      :agent_work_result_id,
      :acquisition_run_id,
      :source_cursor_id,
      :user_id,
      :agent_id,
      :connected_account_id,
      :provider,
      :provider_account_key,
      :cursor_kind,
      :advanced_value,
      :advance_digest,
      :advanced_at,
      :inserted_at
    ])
    |> V.validate_digest(:advance_key)
    |> V.validate_digest(:advance_digest)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:provider, min: 1, max: 80)
    |> V.validate_bytes(:provider_account_key, min: 1, max: 255)
    |> V.validate_bytes(:cursor_kind, min: 1, max: 80)
    |> V.validate_bytes(:expected_value, min: 1, max: 4096)
    |> V.validate_bytes(:advanced_value, min: 1, max: 4096)
    |> unique_constraint(:advance_key,
      name: :source_cursor_advancements_advance_key_unique_index
    )
    |> unique_constraint([:acquisition_run_id, :source_cursor_id],
      name: :source_cursor_advancements_acquisition_cursor_unique_index
    )
    |> unique_constraint([:agent_work_result_id, :source_cursor_id],
      name: :source_cursor_advancements_result_cursor_unique_index
    )
    |> foreign_key_constraint(:agent_work_result_id,
      name: :source_cursor_advancements_result_owner_fkey
    )
    |> foreign_key_constraint(:acquisition_run_id,
      name: :source_cursor_advancements_acquisition_owner_fkey
    )
    |> foreign_key_constraint(:source_cursor_id,
      name: :source_cursor_advancements_cursor_owner_fkey
    )
    |> check_constraint(:advanced_value, name: :source_cursor_advancements_value_check)
    |> check_constraint(:advance_digest, name: :source_cursor_advancements_digest_check)
  end
end
