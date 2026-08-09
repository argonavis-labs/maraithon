defmodule Maraithon.Runtime.AgentWorkResult do
  @moduledoc """
  Transaction-local provisional then committed terminal proof for one exact directive claim.
  """

  use Ecto.Schema
  import Ecto.Changeset

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
    field :result, :map
    field :result_digest, :binary
    field :provisional_at, :utc_datetime_usec
    field :committed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def outcomes, do: @outcomes

  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :id,
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
      :committed_at,
      :inserted_at,
      :updated_at
    ])
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
end
