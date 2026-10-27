defmodule Maraithon.MessageSend.Command do
  @moduledoc "Encrypted, single-delivery message command; a lost acknowledgement never authorizes replay."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "message_send_commands" do
    field :user_id, :string
    field :device_id, Ecto.UUID
    field :todo_id, Ecto.UUID
    field :payload, Maraithon.Encrypted.Map, redact: true
    field :result, Maraithon.Encrypted.Map, redact: true
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime_usec
    field :payload_purged_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
