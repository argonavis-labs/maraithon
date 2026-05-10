defmodule Maraithon.Crm.Observation do
  @moduledoc """
  Durable record of a single inbound source event involving a real human contact.

  Adapters call `new/1` with normalized fields to build a changeset that
  `Maraithon.Crm.Ingest.observe/2` then persists. Once flushed, the
  `relationship_ingestion` job converts the row to the loose-map shape
  `Maraithon.RelationshipIntelligence` consumes via `to_intelligence_input/1`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Crm.Ingest.Window

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @directions ~w(inbound outbound)
  @sources Window.sources()

  schema "crm_observations" do
    field :source, :string
    field :source_account, :string
    field :source_item_id, :string
    field :occurred_at, :utc_datetime_usec
    field :direction, :string
    field :participants, {:array, :map}, default: []
    field :subject, :string
    field :excerpt, :string
    field :metadata, :map, default: %{}
    field :resolved_person_ids, {:array, Ecto.UUID}, default: []
    field :flushed_at, :utc_datetime_usec
    field :learned_at, :utc_datetime_usec
    field :last_error, :string

    belongs_to :user, User, type: :string
    belongs_to :window, Window, foreign_key: :window_id

    timestamps(type: :utc_datetime_usec)
  end

  def directions, do: @directions
  def sources, do: @sources

  @required_fields [:user_id, :source, :source_item_id, :occurred_at, :direction]
  @optional_fields [
    :source_account,
    :participants,
    :subject,
    :excerpt,
    :metadata,
    :resolved_person_ids,
    :window_id,
    :flushed_at,
    :learned_at,
    :last_error
  ]

  @doc """
  Build a changeset from normalized adapter input. Used by source adapters to
  produce the canonical shape that `Crm.Ingest.observe/2` accepts.
  """
  def new(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
  end

  def changeset(observation, attrs) do
    observation
    |> cast(stringify_keys(attrs), @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:source_item_id, min: 1, max: 255)
    |> validate_length(:source_account, max: 255)
    |> validate_length(:subject, max: 8_000)
    |> validate_length(:excerpt, max: 8_000)
    |> normalize_participants()
    |> normalize_metadata()
    |> unique_constraint([:user_id, :source, :source_item_id],
      name: :crm_observations_user_source_item_index,
      message: "already observed"
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:window_id)
  end

  @doc """
  Convert a persisted observation to the loose-map shape
  `RelationshipIntelligence.learn_from_observations/3` consumes.
  """
  def to_intelligence_input(%__MODULE__{} = obs) do
    %{
      "source" => obs.source,
      "source_account" => obs.source_account,
      "source_item_id" => obs.source_item_id,
      "occurred_at" => format_datetime(obs.occurred_at),
      "direction" => obs.direction,
      "participants" => obs.participants || [],
      "subject" => obs.subject,
      "excerpt" => obs.excerpt,
      "metadata" => obs.metadata || %{}
    }
  end

  defp normalize_participants(changeset) do
    case get_change(changeset, :participants) do
      nil ->
        changeset

      list when is_list(list) ->
        normalized = Enum.map(list, &normalize_participant/1)
        put_change(changeset, :participants, normalized)

      _ ->
        add_error(changeset, :participants, "must be a list")
    end
  end

  defp normalize_participant(participant) when is_map(participant) do
    participant
    |> stringify_keys()
    |> Map.update("identifier", %{}, fn
      identifier when is_map(identifier) -> stringify_keys(identifier)
      _ -> %{}
    end)
  end

  defp normalize_participant(_), do: %{}

  defp normalize_metadata(changeset) do
    case get_change(changeset, :metadata) do
      nil ->
        changeset

      map when is_map(map) ->
        put_change(changeset, :metadata, stringify_keys(map))

      _ ->
        add_error(changeset, :metadata, "must be a map")
    end
  end

  defp stringify_keys(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} when is_binary(k) -> {k, stringify_value(v)}
      {k, v} -> {to_string(k), stringify_value(v)}
    end)
  end

  defp stringify_keys(value), do: value

  defp stringify_value(v) when is_map(v) and not is_struct(v), do: stringify_keys(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v), do: v

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(nil), do: nil
  defp format_datetime(other), do: other
end
