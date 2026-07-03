defmodule Maraithon.Connectors.SourceCursor do
  @moduledoc """
  Durable per-(connected_account, kind) sync cursor.

  Backs incremental sync for push/poll connectors: a Gmail `historyId`, a
  Calendar `nextSyncToken`, a Slack poll watermark, and so on. The same row
  also carries the push-watch bookkeeping (`watch_channel_id`,
  `watch_resource_id`, `watch_expires_at`) so `Maraithon.Runtime.WatchRenewer`
  can find watches that need to be re-issued before they expire.

  Exactly one row per `(connected_account_id, kind)` is allowed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "source_cursors" do
    field :user_id, :string
    field :connected_account_id, :id
    field :provider, :string
    field :kind, :string
    field :value, :string
    field :watch_channel_id, :string
    field :watch_resource_id, :string
    field :watch_expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :connected_account_id, :provider, :kind]
  @optional_fields [:value, :watch_channel_id, :watch_resource_id, :watch_expires_at]

  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:kind, min: 1, max: 80)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:connected_account_id)
    |> unique_constraint([:connected_account_id, :kind],
      name: :source_cursors_connected_account_id_kind_index
    )
  end
end
