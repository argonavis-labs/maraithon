defmodule Maraithon.Delegations.AssistantIdentity do
  @moduledoc "The assistant's sending identity, separate from the user's identity."
  use Maraithon.Delegations.Record

  schema "assistant_identities" do
    payload_fields()
    field :gmail_connected_account_id, :integer
    field :gmail_mode, :string, default: "account"
  end

  def payload_binding_spec,
    do: Record.spec("assistant_identities", [:gmail_connected_account_id, :gmail_mode])

  def changeset(row, attrs) do
    Record.changeset(row, attrs, [:gmail_connected_account_id, :gmail_mode], [])
    |> validate_inclusion(:gmail_mode, ~w(account alias))
    |> foreign_key_constraint(:gmail_connected_account_id)
    |> unique_constraint(:user_id)
  end
end
