defmodule Maraithon.Runtime.Snapshot do
  @moduledoc """
  Point-in-time snapshot of an agent's behavior state.

  Written on every checkpoint wakeup and loaded when an agent (re)starts, so a
  restarted agent resumes with its accumulated context instead of a blank
  behavior state. The snapshot is the recovery boundary — events emitted
  between the last checkpoint and a crash are *not* replayed, because replaying
  behavior handlers would re-run their side effects.

  `behavior_state` and `budget` are arbitrary Elixir terms (maps with atom
  keys, nested structures), so they are stored as base64-encoded ETF inside the
  JSONB columns. A plain JSON round-trip would silently turn atoms into strings
  and break the behavior on restore.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Maraithon.Repo

  schema "snapshots" do
    field :agent_id, :binary_id
    field :sequence_num, :integer
    field :state_name, :string
    field :state_data, :map
    field :budget, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w(agent_id sequence_num state_name state_data budget)a

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @required)
    |> validate_required(@required)
  end

  @doc """
  Persist a checkpoint snapshot of an agent's behavior state and budget.
  """
  @spec persist(binary(), integer(), atom() | String.t(), term(), term()) ::
          {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def persist(agent_id, sequence_num, state_name, behavior_state, budget) do
    %__MODULE__{}
    |> changeset(%{
      agent_id: agent_id,
      sequence_num: sequence_num,
      state_name: to_string(state_name),
      state_data: wrap_term(behavior_state),
      budget: wrap_term(budget)
    })
    |> Repo.insert()
  end

  @doc """
  Load the most recent snapshot for an agent.

  Returns `%{sequence_num, state_name, behavior_state, budget}` with the terms
  decoded back to their original Elixir form, or `nil` when the agent has never
  been checkpointed.
  """
  @spec latest(binary()) ::
          %{
            sequence_num: integer(),
            state_name: String.t(),
            behavior_state: term(),
            budget: term()
          }
          | nil
  def latest(agent_id) do
    from(s in __MODULE__,
      where: s.agent_id == ^agent_id,
      order_by: [desc: s.sequence_num],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil ->
        nil

      %__MODULE__{} = snapshot ->
        %{
          sequence_num: snapshot.sequence_num,
          state_name: snapshot.state_name,
          behavior_state: unwrap_term(snapshot.state_data),
          budget: unwrap_term(snapshot.budget)
        }
    end
  end

  # Store any term as base64-encoded ETF inside the JSONB column so atom keys
  # and nested structures survive the round-trip losslessly.
  defp wrap_term(term) do
    %{"format" => "etf_base64", "data" => Base.encode64(:erlang.term_to_binary(term))}
  end

  defp unwrap_term(%{"format" => "etf_base64", "data" => data}) when is_binary(data) do
    data |> Base.decode64!() |> :erlang.binary_to_term()
  end

  # Defensive: an unrecognized shape (hand-written row, future format) is
  # returned as-is rather than crashing the caller.
  defp unwrap_term(other), do: other
end
