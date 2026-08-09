defmodule Maraithon.Runtime.AgentWorkResultAcquisition do
  @moduledoc """
  Exact immutable acquisition proof attached to one terminal Agent work result.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "agent_work_result_acquisitions" do
    field :agent_work_result_id, :binary_id, primary_key: true
    field :acquisition_run_id, :binary_id, primary_key: true
    field :user_id, :string
    field :agent_id, :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :agent_work_result_id,
      :acquisition_run_id,
      :user_id,
      :agent_id,
      :inserted_at
    ])
    |> validate_required([
      :agent_work_result_id,
      :acquisition_run_id,
      :user_id,
      :agent_id,
      :inserted_at
    ])
    |> unique_constraint(:acquisition_run_id,
      name: :agent_work_result_acquisitions_run_unique_index
    )
    |> foreign_key_constraint(:agent_work_result_id,
      name: :agent_work_result_acquisitions_result_owner_fkey
    )
    |> foreign_key_constraint(:acquisition_run_id,
      name: :agent_work_result_acquisitions_acquisition_owner_fkey
    )
  end
end
