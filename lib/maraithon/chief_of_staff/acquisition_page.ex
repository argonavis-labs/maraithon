defmodule Maraithon.ChiefOfStaff.AcquisitionPage do
  @moduledoc """
  Immutable proof for one contiguous provider page in a Chief acquisition.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chief_acquisition_pages" do
    field :acquisition_run_id, :binary_id
    field :ordinal, :integer
    field :request_cursor, :string
    field :next_cursor, :string
    field :terminal, :boolean, default: false
    field :item_count, :integer, default: 0
    field :request_fingerprint, :binary
    field :response_digest, :binary
    field :fetched_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(page, attrs) do
    page
    |> cast(attrs, [
      :id,
      :acquisition_run_id,
      :ordinal,
      :request_cursor,
      :next_cursor,
      :terminal,
      :item_count,
      :request_fingerprint,
      :response_digest,
      :fetched_at,
      :inserted_at
    ])
    |> validate_required([
      :acquisition_run_id,
      :ordinal,
      :terminal,
      :item_count,
      :request_fingerprint,
      :response_digest,
      :fetched_at,
      :inserted_at
    ])
    |> validate_number(:ordinal, greater_than_or_equal_to: 0)
    |> validate_number(:item_count, greater_than_or_equal_to: 0)
    |> V.validate_digest(:request_fingerprint)
    |> V.validate_digest(:response_digest)
    |> V.validate_bytes(:request_cursor, min: 1, max: 4096)
    |> V.validate_bytes(:next_cursor, min: 1, max: 4096)
    |> unique_constraint([:acquisition_run_id, :ordinal])
    |> foreign_key_constraint(:acquisition_run_id)
    |> check_constraint(:terminal, name: :chief_acquisition_pages_terminal_check)
  end
end
