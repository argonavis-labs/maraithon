defmodule Maraithon.TodoBrowser.Command do
  @moduledoc "Encrypted, single-delivery browser command; a lost acknowledgement never authorizes replay."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "todo_browser_commands" do
    field :user_id, :string
    field :device_id, Ecto.UUID
    field :todo_id, Ecto.UUID
    field :operation, :string
    field :payload, Maraithon.Encrypted.Map, redact: true
    field :result, Maraithon.Encrypted.Map, redact: true
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
