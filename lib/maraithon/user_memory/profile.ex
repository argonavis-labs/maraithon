defmodule Maraithon.UserMemory.Profile do
  @moduledoc """
  Durable per-user operating profile shared across agent runtimes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.DurablePayload

  @legacy_tombstone "[encrypted]"
  @max_summary_bytes 5_000
  @max_profile_bytes 64_000
  @profile_bounds [
    max_binary_bytes: 16_000,
    max_depth: 8,
    max_nodes: 2_000,
    max_map_entries: 200,
    max_list_items: 500
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  schema "user_memory_profiles" do
    field :summary, Maraithon.Encrypted.Binary, source: :summary_ciphertext, redact: true

    field :legacy_summary, :string,
      source: :summary,
      default: @legacy_tombstone,
      redact: true

    field :profile, Maraithon.Encrypted.Map, source: :profile_ciphertext, redact: true
    field :legacy_profile, :map, source: :profile, default: %{}, redact: true
    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :content_erased_at, :utc_datetime_usec
    field :source_window_start, :utc_datetime_usec
    field :source_window_end, :utc_datetime_usec
    field :confidence, :float, default: 0.0

    belongs_to :user, User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :summary]
  @optional_fields [:profile, :source_window_start, :source_window_end, :confidence]

  def legacy_tombstone, do: @legacy_tombstone
  @doc false
  def payload_binding_spec do
    %{
      table: "user_memory_profiles",
      identity_fields: [:id],
      scope_fields: [:user_id],
      fields: [:summary, :profile],
      purge_field: :content_erased_at
    }
  end

  def max_summary_bytes, do: @max_summary_bytes
  def max_profile_bytes, do: @max_profile_bytes
  def profile_bounds, do: @profile_bounds

  def changeset(profile, attrs) do
    attrs = put_new_profile_default(profile, attrs || %{})

    profile
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:summary, min: 4, max: 5000)
    |> validate_summary_bytes()
    |> DurablePayload.put_bounded_map(:profile, @max_profile_bytes, @profile_bounds)
    |> mirror_legacy_content()
    |> put_payload_encryption_version()
    |> reactivate_content()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
  end

  @doc false
  def hydrate_content(profile, mode \\ DurablePayload.mode!())

  def hydrate_content(%__MODULE__{} = profile, mode) when mode in [:legacy, :exact] do
    :ok = DurablePayload.verify_binding!(profile, payload_binding_spec(), mode)
    {summary, content} = read_content!(profile, mode)
    %{profile | summary: summary, profile: content}
  end

  def hydrate_content(other, _mode), do: other

  @doc false
  def read_content!(%__MODULE__{content_erased_at: %DateTime{}} = profile, _mode) do
    if is_nil(profile.summary) and is_nil(profile.profile) and
         profile.legacy_summary == @legacy_tombstone and profile.legacy_profile == %{} do
      {nil, %{}}
    else
      raise ArgumentError, "erased UserMemory content is corrupt or inconsistent"
    end
  end

  def read_content!(%__MODULE__{} = profile, :legacy) do
    summary = profile.summary || legacy_summary(profile.legacy_summary)
    content = profile.profile || legacy_map(profile.legacy_profile)

    if is_binary(summary) and is_map(content) and not is_struct(content) do
      {summary, content}
    else
      raise ArgumentError, "UserMemory content is corrupt or inconsistent"
    end
  end

  def read_content!(%__MODULE__{} = profile, :exact) do
    if profile.payload_encryption_version == 1 and is_binary(profile.summary) and
         is_map(profile.profile) and not is_struct(profile.profile) and
         profile.legacy_summary == @legacy_tombstone and profile.legacy_profile == %{} do
      {profile.summary, profile.profile}
    else
      raise ArgumentError, "exact UserMemory content is not ciphertext-only"
    end
  end

  defp validate_summary_bytes(changeset) do
    validate_change(changeset, :summary, fn :summary, value ->
      if is_binary(value) and String.valid?(value) and byte_size(value) <= @max_summary_bytes,
        do: [],
        else: [summary: "must be at most #{@max_summary_bytes} UTF-8 bytes"]
    end)
  end

  defp put_new_profile_default(%__MODULE__{id: nil}, attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :profile) or Map.has_key?(attrs, "profile") -> attrs
      Enum.any?(Map.keys(attrs), &is_binary/1) -> Map.put(attrs, "profile", %{})
      true -> Map.put(attrs, :profile, %{})
    end
  end

  defp put_new_profile_default(_profile, attrs), do: attrs

  defp mirror_legacy_content(changeset) do
    legacy? = DurablePayload.legacy_write?()

    changeset
    |> mirror_field(:summary, :legacy_summary, if(legacy?, do: nil, else: @legacy_tombstone))
    |> mirror_field(:profile, :legacy_profile, if(legacy?, do: nil, else: %{}))
  end

  defp mirror_field(changeset, source, destination, exact_value) do
    case fetch_change(changeset, source) do
      {:ok, value} ->
        put_change(changeset, destination, if(is_nil(exact_value), do: value, else: exact_value))

      :error ->
        changeset
    end
  end

  defp put_payload_encryption_version(changeset) do
    if Map.has_key?(changeset.changes, :summary) or Map.has_key?(changeset.changes, :profile),
      do: put_change(changeset, :payload_encryption_version, 1),
      else: changeset
  end

  defp reactivate_content(changeset) do
    if changeset.data.content_erased_at &&
         (Map.has_key?(changeset.changes, :summary) or Map.has_key?(changeset.changes, :profile)),
       do: put_change(changeset, :content_erased_at, nil),
       else: changeset
  end

  defp legacy_summary(@legacy_tombstone), do: nil
  defp legacy_summary(value) when is_binary(value), do: value
  defp legacy_summary(_value), do: nil
  defp legacy_map(value) when is_map(value) and not is_struct(value), do: value
  defp legacy_map(_value), do: nil
end
