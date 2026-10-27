defmodule Maraithon.CalendarLinks.CalendarLink do
  @moduledoc """
  A user-owned public scheduling link such as a Calendly event type.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  @contexts ~w(personal business)

  schema "user_calendar_links" do
    field :context, :string
    field :duration_minutes, :integer
    field :label, :string
    field :url, :string
    field :active, :boolean, default: true
    field :priority, :integer, default: 100
    field :metadata, :map, default: %{}

    belongs_to :user, Maraithon.Accounts.User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :context, :duration_minutes, :label, :url]
  @optional_fields [:active, :priority, :metadata]

  def changeset(link, attrs) do
    link
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:context, @contexts)
    |> validate_number(:duration_minutes,
      greater_than_or_equal_to: 5,
      less_than_or_equal_to: 180
    )
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 10_000)
    |> validate_length(:label, min: 2, max: 120)
    |> validate_length(:url, min: 12, max: 500)
    |> validate_format(:url, ~r/^https:\/\/calendly\.com\/[^\s]+$/i,
      message: "must be a Calendly https URL"
    )
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:url, name: :user_calendar_links_user_id_url_index)
  end
end
