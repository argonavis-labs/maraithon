defmodule Maraithon.Delegations.Delegation do
  @moduledoc "A todo's durable, account-bound conversation."
  use Maraithon.Delegations.Record

  @terminal ~w(completed stopped expired)
  @states ~w(ready syncing deciding sending reconciling waiting_reply waiting_capacity needs_user paused completed stopped expired)
  @fields ~w(todo_id agent_id kind actor provider connected_account_id provider_thread_id slack_channel state current_grant_id revision source_revision workflow_revision next_wake_at follow_up_at deadline_at last_action_id reminder_count_cycle lifetime_sends lifetime_micro_usd schema_version)a

  schema "delegations" do
    payload_fields()
    field :todo_id, :binary_id
    field :agent_id, :binary_id
    field :kind, :string, default: "information"
    field :actor, :string, default: "as_user"
    field :provider, :string
    field :connected_account_id, :integer
    field :provider_thread_id, :string
    field :slack_channel, :string
    field :state, :string, default: "ready"
    field :current_grant_id, :binary_id
    field :revision, :integer, default: 1
    field :source_revision, :integer, default: 0
    field :workflow_revision, :integer, default: 0
    field :next_wake_at, :utc_datetime_usec
    field :follow_up_at, :utc_datetime_usec
    field :deadline_at, :utc_datetime_usec
    field :last_action_id, :binary_id
    field :reminder_count_cycle, :integer, default: 0
    field :lifetime_sends, :integer, default: 0
    field :lifetime_micro_usd, :integer, default: 0
    field :schema_version, :integer, default: 1
  end

  def terminal_states, do: @terminal
  def live?(%{state: state}), do: state not in @terminal
  def payload_binding_spec, do: Record.spec("delegations", @fields)

  def changeset(row, attrs) do
    Record.changeset(row, attrs, @fields, [:todo_id, :actor, :provider, :connected_account_id])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:kind, ~w(information scheduling coordination))
    |> validate_inclusion(:actor, ~w(as_user as_assistant))
    |> validate_inclusion(:provider, ~w(gmail slack))
    |> validate_number(:schema_version, equal_to: 1)
    |> validate_number(:revision, greater_than: 0)
    |> foreign_key_constraint(:todo_id)
    |> foreign_key_constraint(:connected_account_id)
    |> unique_constraint(:todo_id, name: :delegations_live_todo)
    |> unique_constraint(:provider_thread_id, name: :delegations_live_thread)
  end
end
