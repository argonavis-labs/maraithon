defmodule Maraithon.Crm.Person do
  @moduledoc """
  User-scoped CRM person record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Crm.PersonLink

  @contact_keys ~w(contact_details contacts email emails phone phone_number phones slack_id slack_ids telegram_id telegram_ids)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "crm_people" do
    field :first_name, :string
    field :last_name, :string
    field :display_name, :string
    field :contact_details, :map, default: %{}
    field :preferred_communication_method, :string
    field :relationship, :string
    field :communication_frequency, :string
    field :interaction_count, :integer, default: 0
    field :relationship_strength, :integer, default: 0
    field :affinity_score, :integer, default: 0
    field :last_interaction_at, :utc_datetime_usec
    field :notes, :string
    field :metadata, :map, default: %{}
    field :embedding, Pgvector.Ecto.Vector
    field :embedding_source_hash, :string
    field :embedding_refreshed_at, :utc_datetime_usec

    belongs_to :user, User, type: :string
    has_many :links, PersonLink, foreign_key: :person_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:display_name]
  @optional_fields [
    :first_name,
    :last_name,
    :contact_details,
    :preferred_communication_method,
    :relationship,
    :communication_frequency,
    :interaction_count,
    :relationship_strength,
    :affinity_score,
    :last_interaction_at,
    :notes,
    :metadata,
    :embedding,
    :embedding_source_hash,
    :embedding_refreshed_at
  ]

  def changeset(person, attrs) do
    person
    |> cast(normalize_attrs(attrs), @required_fields ++ @optional_fields)
    |> merge_contact_details_change()
    |> maybe_put_generated_display_name()
    |> validate_required([:user_id, :display_name])
    |> validate_length(:first_name, max: 120)
    |> validate_length(:last_name, max: 120)
    |> validate_length(:display_name, min: 1, max: 240)
    |> validate_length(:preferred_communication_method, max: 80)
    |> validate_length(:relationship, max: 160)
    |> validate_length(:communication_frequency, max: 120)
    |> validate_number(:interaction_count, greater_than_or_equal_to: 0)
    |> validate_number(:relationship_strength,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_number(:affinity_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_length(:notes, max: 8_000)
    |> validate_map(:contact_details)
    |> validate_map(:metadata)
    |> foreign_key_constraint(:user_id)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
    |> normalize_text_fields()
    |> normalize_contact_details()
  end

  defp normalize_attrs(attrs), do: attrs

  defp normalize_text_fields(attrs) do
    Enum.reduce(
      ~w(first_name last_name display_name preferred_communication_method relationship communication_frequency notes),
      attrs,
      fn key, acc ->
        case Map.fetch(acc, key) do
          {:ok, value} -> Map.put(acc, key, normalize_text(value))
          :error -> acc
        end
      end
    )
  end

  defp normalize_contact_details(attrs) do
    if Enum.any?(@contact_keys, &Map.has_key?(attrs, &1)) do
      do_normalize_contact_details(attrs)
    else
      attrs
    end
  end

  defp do_normalize_contact_details(attrs) do
    contact_details =
      attrs
      |> Map.get("contact_details", Map.get(attrs, "contacts"))
      |> case do
        nil -> %{}
        value when is_map(value) -> stringify_keys(value)
        value -> value
      end

    if is_map(contact_details) do
      contact_details =
        contact_details
        |> Map.drop(~w(email phone phone_number slack_id telegram_id))
        |> put_normalized_list(
          "emails",
          Map.get(contact_details, "emails") || Map.get(contact_details, "email") ||
            Map.get(attrs, "email") || Map.get(attrs, "emails")
        )
        |> put_normalized_list(
          "phones",
          Map.get(contact_details, "phones") || Map.get(contact_details, "phone") ||
            Map.get(contact_details, "phone_number") || Map.get(attrs, "phone") ||
            Map.get(attrs, "phone_number") || Map.get(attrs, "phones")
        )
        |> put_normalized_list(
          "slack_ids",
          Map.get(contact_details, "slack_ids") || Map.get(contact_details, "slack_id") ||
            Map.get(attrs, "slack_id") || Map.get(attrs, "slack_ids")
        )
        |> put_normalized_list(
          "telegram_ids",
          Map.get(contact_details, "telegram_ids") || Map.get(contact_details, "telegram_id") ||
            Map.get(attrs, "telegram_id") || Map.get(attrs, "telegram_ids")
        )
        |> compact_contact_details()

      Map.put(attrs, "contact_details", contact_details)
    else
      Map.put(attrs, "contact_details", contact_details)
    end
  end

  defp maybe_put_generated_display_name(changeset) do
    display_name = get_field(changeset, :display_name)

    name_changed? =
      field_changed?(changeset, :first_name) or field_changed?(changeset, :last_name)

    display_name_changed? = field_changed?(changeset, :display_name)

    cond do
      display_name_changed? ->
        changeset

      name_changed? ->
        maybe_put_display_name_change(changeset)

      is_nil(normalize_text(display_name)) ->
        maybe_put_display_name_change(changeset)

      true ->
        changeset
    end
  end

  defp maybe_put_display_name_change(changeset) do
    display_name =
      display_name_from_fields(changeset) ||
        contact_label(get_field(changeset, :contact_details) || %{})

    case display_name do
      nil -> changeset
      value -> put_change(changeset, :display_name, value)
    end
  end

  defp display_name_from_fields(changeset) do
    [get_field(changeset, :first_name), get_field(changeset, :last_name)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> normalize_text()
  end

  defp field_changed?(changeset, field), do: Map.has_key?(changeset.changes, field)

  defp merge_contact_details_change(%{data: %{contact_details: existing}} = changeset)
       when is_map(existing) do
    case get_change(changeset, :contact_details) do
      incoming when is_map(incoming) ->
        put_change(changeset, :contact_details, merge_contact_details(existing, incoming))

      _other ->
        changeset
    end
  end

  defp merge_contact_details_change(changeset), do: changeset

  defp merge_contact_details(existing, incoming) do
    Map.merge(existing, incoming, fn _key, existing_value, incoming_value ->
      merge_contact_value(existing_value, incoming_value)
    end)
  end

  defp merge_contact_value(existing, incoming) when is_list(existing) and is_list(incoming) do
    (existing ++ incoming)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp merge_contact_value(existing, incoming) when is_map(existing) and is_map(incoming) do
    Map.merge(existing, incoming)
  end

  defp merge_contact_value(_existing, incoming), do: incoming

  defp contact_label(contact_details) when is_map(contact_details) do
    ["emails", "slack_ids", "phones", "telegram_ids"]
    |> Enum.find_value(fn key ->
      case Map.get(contact_details, key) do
        [value | _] when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp contact_label(_contact_details), do: nil

  defp put_normalized_list(map, _key, nil), do: map

  defp put_normalized_list(map, key, value) do
    values =
      value
      |> List.wrap()
      |> Enum.flat_map(fn
        value when is_binary(value) ->
          value
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)

        value ->
          [to_string(value)]
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case values do
      [] -> map
      values -> Map.put(map, key, values)
    end
  end

  defp compact_contact_details(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), normalize_contact_value(value)} end)
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp normalize_contact_value(value) when is_binary(value), do: normalize_text(value)

  defp normalize_contact_value(value) when is_list(value) do
    value
    |> Enum.map(&normalize_contact_value/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp normalize_contact_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_contact_value(value), do: value

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_key(:firstName), do: "first_name"
  defp normalize_key(:lastName), do: "last_name"
  defp normalize_key(:displayName), do: "display_name"
  defp normalize_key(:contactDetails), do: "contact_details"
  defp normalize_key(:preferredCommunicationMethod), do: "preferred_communication_method"
  defp normalize_key(:preferredMethodOfCommunication), do: "preferred_communication_method"
  defp normalize_key(:communicationFrequency), do: "communication_frequency"
  defp normalize_key(:interactionCount), do: "interaction_count"
  defp normalize_key(:relationshipStrength), do: "relationship_strength"
  defp normalize_key(:affinityScore), do: "affinity_score"
  defp normalize_key(:lastInteractionAt), do: "last_interaction_at"
  defp normalize_key(:speak_frequency), do: "communication_frequency"
  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()
  defp normalize_key("firstName"), do: "first_name"
  defp normalize_key("lastName"), do: "last_name"
  defp normalize_key("displayName"), do: "display_name"
  defp normalize_key("name"), do: "display_name"
  defp normalize_key("contactDetails"), do: "contact_details"
  defp normalize_key("contacts"), do: "contacts"
  defp normalize_key("preferredCommunicationMethod"), do: "preferred_communication_method"
  defp normalize_key("preferredMethodOfCommunication"), do: "preferred_communication_method"
  defp normalize_key("preferred_method"), do: "preferred_communication_method"
  defp normalize_key("preferred_moth"), do: "preferred_communication_method"
  defp normalize_key("preferred_moth_of_communication"), do: "preferred_communication_method"
  defp normalize_key("communicationFrequency"), do: "communication_frequency"
  defp normalize_key("interactionCount"), do: "interaction_count"
  defp normalize_key("relationshipStrength"), do: "relationship_strength"
  defp normalize_key("affinityScore"), do: "affinity_score"
  defp normalize_key("lastInteractionAt"), do: "last_interaction_at"
  defp normalize_key("speak_frequency"), do: "communication_frequency"
  defp normalize_key("speaking_frequency"), do: "communication_frequency"
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(value), do: value
end
