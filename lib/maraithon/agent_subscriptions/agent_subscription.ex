defmodule Maraithon.AgentSubscriptions.AgentSubscription do
  @moduledoc """
  Durable agent subscription declarations for pub/sub topics.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent
  alias Maraithon.Accounts.User
  alias Maraithon.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active inactive)

  schema "agent_subscriptions" do
    field :topic, :string
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    belongs_to :agent, Agent
    belongs_to :user, User, type: :string, foreign_key: :user_id
    belongs_to :project, Project

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:agent_id, :topic]
  @optional_fields [:user_id, :project_id, :status, :metadata]

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:topic, min: 2, max: 255)
    |> validate_change(:metadata, fn :metadata, value ->
      if is_map(value), do: [], else: [metadata: "must be a map"]
    end)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:agent_id, :topic], name: :agent_subscriptions_agent_id_topic_index)
  end
end
