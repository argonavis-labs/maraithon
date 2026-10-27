defmodule Maraithon.OperatorEvents.OperatorEvent do
  @moduledoc """
  Durable user-scoped operator event emitted from connected systems and conversations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.DurablePayload
  alias Maraithon.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @scopes ~w(global project)
  @max_payload_bytes 256_000
  @max_metadata_bytes 128_000
  @payload_bounds [
    max_binary_bytes: 64_000,
    max_depth: 12,
    max_nodes: 10_000,
    max_map_entries: 2_000,
    max_list_items: 2_000
  ]

  schema "operator_events" do
    field :source, :string
    field :event_type, :string
    field :scope, :string, default: "global"
    field :source_item_id, :string
    field :dedupe_key, :string
    field :occurred_at, :utc_datetime_usec

    field :payload, Maraithon.Encrypted.Map, source: :payload_ciphertext, redact: true
    field :legacy_payload, :map, source: :payload, default: %{}, redact: true
    field :metadata, Maraithon.Encrypted.Map, source: :metadata_ciphertext, redact: true
    field :legacy_metadata, :map, source: :metadata, default: %{}, redact: true
    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :payload_purged_at, :utc_datetime_usec
    field :conversation_content_redacted_at, :utc_datetime_usec

    belongs_to :user, User, type: :string, foreign_key: :user_id
    belongs_to :project, Project

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :source, :event_type, :scope, :dedupe_key, :occurred_at]
  @optional_fields [:project_id, :source_item_id, :payload, :metadata]

  @doc false
  def payload_binding_spec do
    %{
      table: "operator_events",
      identity_fields: [:id],
      scope_fields: [:user_id, :project_id],
      fields: [:payload, :metadata],
      purge_field: :payload_purged_at
    }
  end

  def max_payload_bytes, do: @max_payload_bytes
  def max_metadata_bytes, do: @max_metadata_bytes
  def payload_bounds, do: @payload_bounds

  def changeset(event, attrs) do
    attrs = put_new_payload_defaults(event, attrs || %{})

    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:scope, @scopes)
    |> validate_length(:user_id, min: 3, max: 320)
    |> validate_length(:source, min: 2, max: 100)
    |> validate_length(:event_type, min: 2, max: 160)
    |> validate_length(:source_item_id, max: 255)
    |> validate_length(:dedupe_key, min: 4, max: 255)
    |> DurablePayload.put_bounded_map(:payload, @max_payload_bytes, @payload_bounds)
    |> DurablePayload.put_bounded_map(:metadata, @max_metadata_bytes, @payload_bounds)
    |> mirror_legacy_payload(:payload, :legacy_payload)
    |> mirror_legacy_payload(:metadata, :legacy_metadata)
    |> put_payload_encryption_version()
    |> reactivate_payload()
    |> mark_conversation_redaction()
    |> validate_project_scope()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:dedupe_key, name: :operator_events_user_id_dedupe_key_index)
  end

  @doc false
  def hydrate_payloads(event, mode \\ DurablePayload.mode!())

  def hydrate_payloads(%__MODULE__{} = event, mode) when mode in [:legacy, :exact] do
    :ok = DurablePayload.verify_binding!(event, payload_binding_spec(), mode)
    {payload, metadata} = read_payloads!(event, mode)
    %{event | payload: payload, metadata: metadata}
  end

  def hydrate_payloads(other, _mode), do: other

  @doc false
  def read_payloads!(%__MODULE__{payload_purged_at: %DateTime{}} = event, _mode) do
    if is_nil(event.payload) and is_nil(event.metadata) and event.legacy_payload == %{} and
         event.legacy_metadata == %{} do
      {%{}, %{}}
    else
      raise ArgumentError, "purged OperatorEvent payload is corrupt or inconsistent"
    end
  end

  def read_payloads!(%__MODULE__{} = event, :legacy) do
    payload = event.payload || legacy_map(event.legacy_payload)
    metadata = event.metadata || legacy_map(event.legacy_metadata)

    if json_map?(payload) and json_map?(metadata) do
      {payload, metadata}
    else
      raise ArgumentError, "OperatorEvent payload is corrupt or inconsistent"
    end
  end

  def read_payloads!(%__MODULE__{} = event, :exact) do
    if event.payload_encryption_version == 1 and json_map?(event.payload) and
         json_map?(event.metadata) and event.legacy_payload == %{} and
         event.legacy_metadata == %{} do
      {event.payload, event.metadata}
    else
      raise ArgumentError, "exact OperatorEvent payload is not ciphertext-only"
    end
  end

  defp put_new_payload_defaults(%__MODULE__{id: nil}, attrs) when is_map(attrs) do
    attrs
    |> put_attr_default(:payload, %{})
    |> put_attr_default(:metadata, %{})
  end

  defp put_new_payload_defaults(_event, attrs), do: attrs

  defp put_attr_default(attrs, field, default) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) or Map.has_key?(attrs, string_field) -> attrs
      Enum.any?(Map.keys(attrs), &is_binary/1) -> Map.put(attrs, string_field, default)
      true -> Map.put(attrs, field, default)
    end
  end

  defp mirror_legacy_payload(changeset, payload_field, legacy_field) do
    case fetch_change(changeset, payload_field) do
      {:ok, payload} ->
        put_change(
          changeset,
          legacy_field,
          if(DurablePayload.legacy_write?(), do: payload, else: %{})
        )

      :error ->
        changeset
    end
  end

  defp put_payload_encryption_version(changeset) do
    if Map.has_key?(changeset.changes, :payload) or Map.has_key?(changeset.changes, :metadata),
      do: put_change(changeset, :payload_encryption_version, 1),
      else: changeset
  end

  defp reactivate_payload(changeset) do
    if changeset.data.payload_purged_at &&
         (Map.has_key?(changeset.changes, :payload) or Map.has_key?(changeset.changes, :metadata)),
       do: put_change(changeset, :payload_purged_at, nil),
       else: changeset
  end

  defp legacy_map(value) when is_map(value) and not is_struct(value), do: value
  defp legacy_map(_value), do: nil
  defp json_map?(value), do: is_map(value) and not is_struct(value)

  defp mark_conversation_redaction(changeset) do
    if get_field(changeset, :source) == "telegram" and
         get_field(changeset, :event_type) == "conversation_turn.recorded" and
         redacted_conversation_copy?(get_field(changeset, :payload) || %{}) and
         redacted_conversation_copy?(get_field(changeset, :metadata) || %{}) do
      put_change(
        changeset,
        :conversation_content_redacted_at,
        get_field(changeset, :occurred_at) || DateTime.utc_now()
      )
    else
      changeset
    end
  end

  defp redacted_conversation_copy?(map) when is_map(map) do
    Enum.all?(
      [
        "text",
        :text,
        "structured_data",
        :structured_data,
        "summary",
        :summary,
        "historical_summary",
        :historical_summary
      ],
      &(not Map.has_key?(map, &1))
    )
  end

  defp redacted_conversation_copy?(_value), do: false

  defp validate_project_scope(changeset) do
    case {get_field(changeset, :scope), get_field(changeset, :project_id)} do
      {"project", nil} ->
        add_error(changeset, :project_id, "must be present for project-scoped events")

      {"global", project_id} when not is_nil(project_id) ->
        put_change(changeset, :scope, "project")

      _ ->
        changeset
    end
  end
end
