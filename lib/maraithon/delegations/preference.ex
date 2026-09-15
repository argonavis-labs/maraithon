defmodule Maraithon.Delegations.Preference do
  @moduledoc false
  use Maraithon.Delegations.Record

  schema "delegation_preferences" do
    payload_fields()
  end

  def payload_binding_spec, do: Record.spec("delegation_preferences", [])

  def changeset(row, attrs) do
    Record.changeset(row, attrs, [], []) |> unique_constraint(:user_id)
  end
end
