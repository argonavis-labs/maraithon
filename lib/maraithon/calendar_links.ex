defmodule Maraithon.CalendarLinks do
  @moduledoc """
  Stores and selects user-owned scheduling links for assistant drafts.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Maraithon.CalendarLinks.CalendarLink
  alias Maraithon.Repo
  alias Maraithon.Todos.AttentionRanker

  @contexts ~w(personal business)
  @short_terms ~w(15 fifteen quick short intro sync status checkin check-in walkthrough onboard onboarding)
  @long_terms [
    "30",
    "thirty",
    "half hour",
    "demo",
    "team demo",
    "deep dive",
    "weekly",
    "planning"
  ]
  @personal_terms ~w(personal family home friend friends dinner lunch coffee weekend saturday sunday whatsapp)
  @business_terms ~w(
    runner business customer client prospect sales investor partner partnership company compliance
    project product demo onboard onboarding walkthrough team startup work pricing contract founder
  )

  def list_user_links(user_id) when is_binary(user_id) do
    CalendarLink
    |> where([link], link.user_id == ^user_id)
    |> order_by([link],
      asc: link.context,
      asc: link.duration_minutes,
      asc: link.priority,
      asc: link.inserted_at
    )
    |> Repo.all()
    |> Enum.sort_by(&settings_sort_key/1)
  end

  def list_user_links(_user_id), do: []

  def list_active_links(user_id) when is_binary(user_id) do
    user_id
    |> list_user_links()
    |> Enum.filter(&(&1.active == true))
  end

  def list_active_links(_user_id), do: []

  def settings_rows(user_id) do
    rows =
      user_id
      |> list_user_links()
      |> Enum.map(&settings_row/1)

    rows ++ [blank_settings_row(length(rows))]
  end

  def settings_rows_from_params(raw_links) do
    rows =
      raw_links
      |> normalize_link_params()
      |> Enum.map(&settings_row_from_attrs/1)

    rows ++ [blank_settings_row(length(rows))]
  end

  def replace_user_links(user_id, raw_links) when is_binary(user_id) do
    changesets =
      raw_links
      |> normalize_link_params()
      |> Enum.reject(&blank_link?/1)
      |> Enum.with_index()
      |> Enum.map(fn {attrs, index} ->
        context = Map.get(attrs, :context) || "business"
        duration = Map.get(attrs, :duration_minutes) || default_duration(context)

        attrs =
          attrs
          |> Map.put(:user_id, user_id)
          |> Map.put(:context, context)
          |> Map.put(:duration_minutes, duration)
          |> Map.put(:label, Map.get(attrs, :label) || default_label(context, duration))
          |> Map.put_new(:priority, index)

        CalendarLink.changeset(%CalendarLink{}, attrs)
      end)

    case Enum.find(changesets, &(not &1.valid?)) do
      %Changeset{} = changeset ->
        {:error, changeset}

      nil ->
        Repo.transaction(fn ->
          CalendarLink
          |> where([link], link.user_id == ^user_id)
          |> Repo.delete_all()

          Enum.map(changesets, &Repo.insert!/1)
        end)
    end
  end

  def replace_user_links(_user_id, _raw_links), do: {:error, :invalid_user}

  def best_link_for(user_id, todo, body, opts \\ [])

  def best_link_for(user_id, todo, body, opts) when is_binary(user_id) do
    links = list_active_links(user_id)

    if links == [] do
      nil
    else
      text = intelligence_text(todo, body, Keyword.get(opts, :source_message, %{}))
      profile = attention_profile(todo)
      context = Keyword.get(opts, :context) || infer_context(todo, profile, text)
      duration = Keyword.get(opts, :duration_minutes) || infer_duration_minutes(context, text)

      links
      |> Enum.map(fn link -> {link_score(link, context, duration, text), link} end)
      |> Enum.max_by(fn {score, link} -> {score, -(link.priority || 100)} end, fn -> {0, nil} end)
      |> case do
        {score, %CalendarLink{} = link} when score > 0 -> link
        _other -> nil
      end
    end
  end

  def best_link_for(_user_id, _todo, _body, _opts), do: nil

  def display_label(%CalendarLink{label: label} = link) when is_binary(label) do
    case String.trim(label) do
      "" -> default_display_label(link)
      value -> value
    end
  end

  def display_label(%CalendarLink{} = link), do: default_display_label(link)

  defp default_display_label(%CalendarLink{} = link) do
    duration =
      case link.duration_minutes do
        minutes when is_integer(minutes) -> "#{minutes}-minute"
        _other -> nil
      end

    [duration, link.context, "link"]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp default_display_label(_link), do: "calendar link"

  def changeset_error_message(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{humanize_field(field)} #{&1}")
    end)
    |> List.first()
    |> case do
      nil -> "Calendar link could not be saved."
      message -> "Calendar link #{message}."
    end
  end

  def changeset_error_message(_reason), do: "Calendar links could not be saved."

  defp normalize_link_params(%{} = raw_links) do
    raw_links
    |> Enum.sort_by(fn {key, _value} -> parse_integer(key) || 0 end)
    |> Enum.map(fn {_key, value} -> normalize_link_attrs(value) end)
  end

  defp normalize_link_params(raw_links) when is_list(raw_links) do
    Enum.map(raw_links, &normalize_link_attrs/1)
  end

  defp normalize_link_params(_raw_links), do: []

  defp normalize_link_attrs(%{} = raw) do
    context = normalize_context(read_value(raw, "context"))
    duration = parse_integer(read_raw_value(raw, "duration_minutes")) || default_duration(context)
    label = read_value(raw, "label")
    url = read_value(raw, "url")

    %{
      context: context,
      duration_minutes: duration,
      label: label,
      url: url,
      active: parse_boolean(read_raw_value(raw, "active"), true),
      priority: parse_integer(read_raw_value(raw, "priority")) || 100,
      metadata: %{"source" => "settings"}
    }
  end

  defp normalize_link_attrs(_raw), do: %{}

  defp blank_link?(attrs) when is_map(attrs) do
    blank?(Map.get(attrs, :url)) and blank?(Map.get(attrs, :label))
  end

  defp blank_link?(_attrs), do: true

  defp settings_row(%CalendarLink{} = link) do
    %{
      id: link.id,
      context: link.context,
      duration_minutes: link.duration_minutes,
      label: link.label,
      url: link.url,
      active: link.active,
      priority: link.priority
    }
  end

  defp settings_row_from_attrs(attrs) when is_map(attrs) do
    %{
      id: nil,
      context: Map.get(attrs, :context) || "business",
      duration_minutes: Map.get(attrs, :duration_minutes) || 30,
      label: Map.get(attrs, :label),
      url: Map.get(attrs, :url),
      active: Map.get(attrs, :active, true),
      priority: Map.get(attrs, :priority) || 100
    }
  end

  defp blank_settings_row(index) do
    %{
      id: nil,
      context: "business",
      duration_minutes: 30,
      label: nil,
      url: nil,
      active: true,
      priority: 100 + index
    }
  end

  defp settings_sort_key(%CalendarLink{} = link) do
    {context_sort_value(link.context), link.duration_minutes || 0, link.priority || 100}
  end

  defp context_sort_value("personal"), do: 0
  defp context_sort_value("business"), do: 1
  defp context_sort_value(_context), do: 2

  defp link_score(%CalendarLink{} = link, context, duration, text) do
    context_score = if link.context == context, do: 120, else: 15
    duration_score = max(0, 60 - abs((link.duration_minutes || duration) - duration) * 4)
    keyword_score = link_keyword_score(link, text)
    active_score = if link.active == true, do: 20, else: -1_000

    context_score + duration_score + keyword_score + active_score - div(link.priority || 100, 10)
  end

  defp link_keyword_score(%CalendarLink{} = link, text) do
    link_text = "#{link.label} #{link.url}" |> String.downcase()

    [
      {"walkthrough", 70},
      {"ai", 35},
      {"onboard", 70},
      {"onboarding", 70},
      {"demo", 70},
      {"team demo", 90},
      {"co-founder", 25},
      {"founder", 20},
      {"personal", 50}
    ]
    |> Enum.reduce(0, fn {term, score}, acc ->
      if String.contains?(text, term) and String.contains?(link_text, term) do
        acc + score
      else
        acc
      end
    end)
  end

  defp infer_context(todo, profile, text) do
    cond do
      read_bool(profile, "personal_family") ->
        "personal"

      contains_any?(text, @personal_terms) and not contains_any?(text, @business_terms) ->
        "personal"

      read_field(todo, "source") in ["slack", "gmail"] ->
        "business"

      contains_any?(text, @business_terms) ->
        "business"

      true ->
        "business"
    end
  end

  defp infer_duration_minutes(context, text) do
    cond do
      contains_any?(text, @short_terms) -> 15
      contains_any?(text, @long_terms) -> 30
      context == "personal" -> 30
      true -> 30
    end
  end

  defp intelligence_text(todo, body, source_message) do
    metadata = read_field(todo, "metadata") || %{}

    [
      read_field(todo, "title"),
      read_field(todo, "summary"),
      read_field(todo, "next_action"),
      read_field(todo, "notes"),
      body,
      read_value(metadata, "life_domain"),
      read_value(metadata, "suggested_life_domain"),
      read_value(metadata, "company"),
      read_value(metadata, "organization"),
      read_value(metadata, "relationship"),
      read_value(source_message || %{}, "subject"),
      read_value(source_message || %{}, "from")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp attention_profile(todo) do
    AttentionRanker.profile(todo)
  rescue
    _ -> %{}
  end

  defp normalize_context(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    if value in @contexts, do: value, else: "business"
  end

  defp normalize_context(_value), do: "business"

  defp default_duration("personal"), do: 30
  defp default_duration(_context), do: 30

  defp default_label("personal", minutes), do: "Personal #{minutes} minutes"
  defp default_label("business", minutes), do: "Business #{minutes} minutes"
  defp default_label(_context, minutes), do: "#{minutes} minutes"

  defp read_field(%{__struct__: _struct} = struct, field) when is_binary(field) do
    Map.get(struct, existing_atom_key(field))
  end

  defp read_field(%{} = map, field), do: read_raw_value(map, field)
  defp read_field(_value, _field), do: nil

  defp read_value(map, key) do
    map
    |> read_raw_value(key)
    |> normalize_string()
  end

  defp read_raw_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) || Map.get(map, existing_atom_key(key))
  end

  defp read_raw_value(_map, _key), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_value), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp parse_boolean(values, default) when is_list(values) do
    cond do
      Enum.any?(values, &parse_boolean(&1, false)) -> true
      values == [] -> default
      true -> false
    end
  end

  defp parse_boolean(value, _default) when value in [true, "true", "on", "1", 1], do: true
  defp parse_boolean(value, _default) when value in [false, "false", "off", "0", 0], do: false
  defp parse_boolean(_value, default), do: default

  defp contains_any?(text, terms) when is_binary(text) do
    Enum.any?(terms, &String.contains?(text, &1))
  end

  defp contains_any?(_text, _terms), do: false

  defp read_bool(map, key) when is_map(map), do: read_raw_value(map, key) == true
  defp read_bool(_map, _key), do: false

  defp humanize_field(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
  end

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_key(key) when is_atom(key), do: key
  defp existing_atom_key(_key), do: nil

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
