defmodule Maraithon.Memory.Item do
  @moduledoc """
  Durable per-user memory item used by the runtime, tools, and assistant loops.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  @statuses ~w(active archived superseded rejected)
  @kinds ~w(fact preference relevance_feedback instruction relationship project workflow correction system_note)
  @scopes ~w(user system agent project)
  @author_types ~w(user system agent model tool)
  @polarities ~w(neutral positive negative)

  schema "memory_items" do
    field :status, :string, default: "active"
    field :kind, :string, default: "fact"
    field :scope, :string, default: "user"
    field :title, :string
    field :content, Maraithon.Encrypted.Binary
    field :summary, Maraithon.Encrypted.Binary
    field :source, :string, default: "manual"
    field :source_ref_type, :string
    field :source_ref_id, :string
    field :author_type, :string, default: "user"
    field :author_id, :string
    field :tags, {:array, :string}, default: []
    field :importance, :integer, default: 50
    field :confidence, :float, default: 0.75
    field :polarity, :string, default: "neutral"
    field :dedupe_key, :string
    field :metadata, Maraithon.Encrypted.Map
    field :last_used_at, :utc_datetime_usec
    field :use_count, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :decay_at, :utc_datetime_usec

    belongs_to :user, User, type: :string
    belongs_to :superseded_by, __MODULE__, foreign_key: :superseded_by_id, type: :binary_id
    belongs_to :supersedes, __MODULE__, foreign_key: :supersedes_id, type: :binary_id
    has_one :superseding_memory, __MODULE__, foreign_key: :supersedes_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :status, :kind, :scope, :title, :content, :source, :author_type]
  @cast_required_fields @required_fields -- [:user_id]
  @optional_fields [
    :summary,
    :source_ref_type,
    :source_ref_id,
    :author_id,
    :tags,
    :importance,
    :confidence,
    :polarity,
    :dedupe_key,
    :metadata,
    :last_used_at,
    :use_count,
    :expires_at,
    :decay_at,
    :superseded_by_id,
    :supersedes_id
  ]
  @all_fields @required_fields ++ @optional_fields
  @known_string_keys Map.new(@all_fields, &{Atom.to_string(&1), &1})

  def changeset(item, attrs) do
    attrs = normalize_attrs(attrs, item)

    item
    |> cast(attrs, @cast_required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:author_type, @author_types)
    |> validate_inclusion(:polarity, @polarities)
    |> validate_length(:title, min: 2, max: 220)
    |> validate_length(:content, min: 3, max: 10_000)
    |> validate_length(:summary, max: 2_000)
    |> validate_length(:source, min: 2, max: 120)
    |> validate_number(:importance, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:use_count, greater_than_or_equal_to: 0)
    |> validate_change(:metadata, fn :metadata, value ->
      if is_map(value), do: [], else: [metadata: "must be a map"]
    end)
    |> validate_evidence()
    |> validate_decay_after_inserted_at()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:superseded_by_id)
    |> foreign_key_constraint(:supersedes_id)
    |> unique_constraint(:dedupe_key, name: :memory_items_user_active_dedupe_index)
  end

  defp normalize_attrs(attrs, item) when is_map(attrs) do
    attrs
    |> normalize_keys()
    |> normalize_text(:title)
    |> normalize_text(:content)
    |> normalize_text(:summary)
    |> normalize_text(:source)
    |> normalize_text(:source_ref_type)
    |> normalize_text(:source_ref_id)
    |> normalize_text(:author_id)
    |> normalize_text(:dedupe_key)
    |> normalize_enum(:status, "active")
    |> normalize_enum(:kind, "fact")
    |> normalize_enum(:scope, "user")
    |> normalize_enum(:author_type, "user")
    |> normalize_enum(:polarity, "neutral")
    |> normalize_tags()
    |> normalize_metadata()
    |> normalize_title(item)
  end

  defp normalize_attrs(_attrs, item), do: normalize_attrs(%{}, item)

  defp normalize_keys(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_binary(key) ->
        case Map.fetch(@known_string_keys, key) do
          {:ok, field} -> Map.put(acc, field, value)
          :error -> acc
        end

      {key, value}, acc when is_atom(key) ->
        if key in @all_fields, do: Map.put(acc, key, value), else: acc

      _other, acc ->
        acc
    end)
  end

  defp normalize_text(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> Map.delete(attrs, key)
          normalized -> Map.put(attrs, key, normalized)
        end

      _other ->
        attrs
    end
  end

  defp normalize_enum(attrs, key, default) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        normalized =
          value
          |> String.trim()
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/u, "_")
          |> String.trim("_")

        if normalized == "",
          do: Map.put(attrs, key, default),
          else: Map.put(attrs, key, normalized)

      nil ->
        attrs

      value ->
        Map.put(attrs, key, to_string(value))
    end
  end

  defp normalize_tags(%{tags: tags} = attrs) when is_list(tags) do
    tags =
      tags
      |> Enum.map(&normalize_tag/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    Map.put(attrs, :tags, tags)
  end

  defp normalize_tags(%{tags: tags} = attrs) when is_binary(tags) do
    tags =
      tags
      |> String.split(",", trim: true)
      |> Enum.map(&normalize_tag/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    Map.put(attrs, :tags, tags)
  end

  defp normalize_tags(attrs), do: attrs

  defp normalize_tag(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9:_-]+/u, "_")
    |> String.trim("_")
  end

  defp normalize_tag(value), do: value |> to_string() |> normalize_tag()

  defp normalize_metadata(%{metadata: metadata} = attrs) when is_map(metadata), do: attrs
  defp normalize_metadata(%{metadata: _metadata} = attrs), do: Map.put(attrs, :metadata, %{})
  defp normalize_metadata(attrs), do: attrs

  defp validate_evidence(changeset) do
    evidence =
      changeset
      |> get_field(:metadata)
      |> case do
        metadata when is_map(metadata) ->
          Map.get(metadata, "evidence") || Map.get(metadata, :evidence)

        _metadata ->
          nil
      end

    if valid_evidence?(evidence) do
      changeset
    else
      add_error(
        changeset,
        :metadata,
        "evidence must be a map or list of maps with quote and source"
      )
    end
  end

  defp valid_evidence?(nil), do: true

  defp valid_evidence?(evidence) when is_map(evidence) do
    present?(Map.get(evidence, "quote") || Map.get(evidence, :quote)) and
      present?(Map.get(evidence, "source") || Map.get(evidence, :source))
  end

  defp valid_evidence?(evidence) when is_list(evidence),
    do: Enum.all?(evidence, &valid_evidence?/1)

  defp valid_evidence?(_evidence), do: false

  defp validate_decay_after_inserted_at(changeset) do
    case {get_field(changeset, :inserted_at), get_field(changeset, :decay_at)} do
      {%DateTime{} = inserted_at, %DateTime{} = decay_at} ->
        if DateTime.compare(decay_at, inserted_at) == :gt do
          changeset
        else
          add_error(changeset, :decay_at, "must be after inserted_at")
        end

      _other ->
        changeset
    end
  end

  defp normalize_title(attrs, item) do
    current_title = item && Map.get(item, :title)

    cond do
      present?(Map.get(attrs, :title)) ->
        attrs

      present?(current_title) ->
        attrs

      present?(Map.get(attrs, :content)) ->
        Map.put(attrs, :title, attrs |> Map.fetch!(:content) |> title_from_content())

      true ->
        attrs
    end
  end

  defp title_from_content(content) do
    content
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(10)
    |> Enum.join(" ")
    |> String.slice(0, 120)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
