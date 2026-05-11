defmodule Maraithon.LocalBrowserHistory.LocalVisit do
  @moduledoc """
  Append-only mirror of a browser visit synced from a companion device's
  Chrome / Safari / Arc / Brave history database. The `title` field is
  stored encrypted at rest via the Cloak vault
  (`Maraithon.Encrypted.Binary`); `url` and `host` are plain text so we
  can index and filter on them, and the ingest layer drops rows whose
  host matches the private-host deny-list documented in the migration.

  `guid` is the browser's native id (Chromium's `urls.id` or Safari's
  `history_items.id`) namespaced by browser so cross-browser collisions
  can't happen; `local_id` is the same id without the namespace prefix.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @browsers ~w(chrome safari arc brave)

  schema "local_browser_visits" do
    field :user_id, :string
    field :device_id, Ecto.UUID
    field :source, :string, default: "browser_history"
    field :browser, :string
    field :guid, :string
    field :local_id, :string
    field :url, :string
    field :title, Maraithon.Encrypted.Binary
    field :host, :string
    field :visit_count, :integer, default: 1
    field :last_visited_at, :utc_datetime_usec
    field :is_typed_url, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :device_id, :source, :browser, :url]
  @optional_fields [
    :guid,
    :local_id,
    :title,
    :host,
    :visit_count,
    :last_visited_at,
    :is_typed_url
  ]

  def changeset(visit, attrs) do
    visit
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:browser, @browsers)
    |> validate_length(:source, max: 64)
    |> validate_length(:browser, max: 32)
    |> unique_constraint([:user_id, :device_id, :source, :guid],
      name: :local_browser_visits_user_device_source_guid_index
    )
  end

  def supported_browsers, do: @browsers
end
