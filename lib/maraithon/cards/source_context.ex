defmodule Maraithon.Cards.SourceContext do
  @moduledoc """
  Canonical participant and conversation context for next-action cards.

  Every card surface (todo source actions, chat draft cards, prepared-action
  cards) builds its people list and conversation excerpt here, so Gmail,
  Slack, iMessage, WhatsApp, and Calendar cards all preserve from/to/cc/bcc
  and show as much of the source conversation as we have.
  """

  alias Maraithon.LocalMessages
  alias Maraithon.Todos.{PublicMetadata, Todo}

  @max_participants 8
  @max_conversation_messages 6
  @max_message_chars 280

  @from_keys ~w(from sender from_email source_from)
  @to_keys ~w(to recipient recipient_email reply_to)
  @cc_keys ~w(cc)
  @bcc_keys ~w(bcc)
  @person_keys ~w(person contact requested_by sender_name recipient_name matching_person chat_display_name)

  # Only true source text qualifies as conversation; analysis fields like
  # "evidence" read as the assistant's own notes and would mis-attribute.
  @excerpt_keys ~w(
    matching_message_excerpt source_excerpt source_quote quote body_excerpt
    excerpt snippet source_body
  )

  @doc """
  Builds `%{"participants" => [...], "conversation" => [...]}` for a todo.

  Accepts a `%Todo{}` or a serialized todo map (as stored on chat primers).
  Empty lists are omitted.
  """
  def for_todo(todo, opts \\ [])

  def for_todo(%Todo{} = todo, opts) do
    build(
      todo.user_id,
      todo.metadata || %{},
      todo.action_draft || %{},
      Keyword.put_new(opts, :source, todo.source)
    )
  end

  def for_todo(%{} = todo, opts) do
    build(
      read_string(todo, "user_id") || Keyword.get(opts, :user_id),
      read_map(todo, "metadata"),
      read_map(todo, "action_draft"),
      Keyword.put_new(opts, :source, read_string(todo, "source"))
    )
  end

  def for_todo(_todo, _opts), do: %{}

  @doc """
  Builds participant context from a prepared-action payload.
  """
  def for_payload(payload) when is_map(payload) do
    nested = [payload | nested_maps(payload)]

    %{"participants" => participants(nested)}
    |> drop_blank_values()
  end

  def for_payload(_payload), do: %{}

  @doc """
  Merges participant/conversation context into a card map, without
  overwriting fields the card already set.
  """
  def merge_into(card, context) when is_map(card) and is_map(context) do
    Enum.reduce(context, card, fn {key, value}, acc ->
      Map.put_new(acc, key, value)
    end)
  end

  def merge_into(card, _context), do: card

  defp build(user_id, metadata, draft, opts) do
    sources = [draft, metadata, read_map(metadata, "record")] ++ nested_maps(draft)

    %{
      "participants" => participants(sources),
      "conversation" => conversation(user_id, metadata, Keyword.get(opts, :source))
    }
    |> drop_blank_values()
  end

  # ---------------------------------------------------------------------------
  # Participants
  # ---------------------------------------------------------------------------

  defp participants(sources) when is_list(sources) do
    [
      role_entries(sources, "from", @from_keys),
      role_entries(sources, "to", @to_keys),
      role_entries(sources, "cc", @cc_keys),
      role_entries(sources, "bcc", @bcc_keys),
      person_entries(sources),
      crm_entries(sources)
    ]
    |> List.flatten()
    |> dedupe_participants()
    |> Enum.take(@max_participants)
  end

  defp role_entries(sources, role, keys) do
    keys
    |> Enum.flat_map(fn key -> Enum.map(sources, &read_field(&1, key)) end)
    |> Enum.flat_map(&address_values/1)
    |> Enum.map(&parse_address(&1, role))
    |> Enum.reject(&is_nil/1)
  end

  defp person_entries(sources) do
    @person_keys
    |> Enum.flat_map(fn key -> Enum.map(sources, &read_field(&1, key)) end)
    |> Enum.flat_map(&address_values/1)
    |> Enum.map(&parse_address(&1, "participant"))
    |> Enum.reject(&is_nil/1)
  end

  defp crm_entries(sources) do
    sources
    |> Enum.flat_map(fn source ->
      case read_field(source, "crm_people") || read_field(source, "people") do
        people when is_list(people) -> Enum.filter(people, &is_map/1)
        %{} = person -> [person]
        _other -> []
      end
    end)
    |> Enum.map(fn person ->
      name =
        first_present([
          read_string(person, "display_name"),
          read_string(person, "name"),
          full_name(person)
        ])

      handle = crm_handle(person)

      if present?(name) or present?(handle) do
        participant(name, handle, "participant")
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp full_name(person) do
    [read_string(person, "first_name"), read_string(person, "last_name")]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  defp crm_handle(person) do
    contact_details = read_map(person, "contact_details")

    [
      Map.get(contact_details, "emails"),
      Map.get(contact_details, "email"),
      read_string(person, "email"),
      Map.get(contact_details, "phones"),
      Map.get(contact_details, "phone")
    ]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
  end

  # Accepts a single address, a comma/semicolon-separated header, or a list.
  defp address_values(value) when is_binary(value) do
    cond do
      String.contains?(value, "<") ->
        # Mixed header: bracketed name/address pairs plus any bare addresses
        # between them ("kent@x.com, Dana Chen <dana@y.com>").
        pair_pattern = ~r/(?:"?[^"<,;]*"?\s*)?<[^>]+>/

        pairs = pair_pattern |> Regex.scan(value) |> Enum.map(fn [match] -> match end)
        remainder = Regex.replace(pair_pattern, value, "")

        bare =
          ~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i
          |> Regex.scan(remainder)
          |> Enum.map(fn [match] -> match end)

        pairs ++ bare

      String.contains?(value, [",", ";"]) ->
        value |> String.split([",", ";"]) |> Enum.map(&String.trim/1)

      true ->
        [value]
    end
  end

  defp address_values(values) when is_list(values), do: Enum.flat_map(values, &address_values/1)
  defp address_values(_value), do: []

  defp parse_address(value, role) when is_binary(value) do
    value = String.trim(value)

    cond do
      blank?(value) ->
        nil

      String.contains?(value, "<") ->
        case Regex.run(~r/^"?([^"<]*?)"?\s*<([^>]+)>/, value) do
          [_all, name, handle] ->
            participant(clean_name(name), clean_handle(handle), role)

          _other ->
            participant(nil, clean_handle(value), role)
        end

      email_like?(value) or phone_like?(value) ->
        participant(nil, clean_handle(value), role)

      true ->
        participant(clean_name(value), nil, role)
    end
  end

  defp parse_address(_value, _role), do: nil

  defp participant(name, handle, role) do
    name = if public_text?(name), do: name
    handle = if safe_handle?(handle), do: handle

    if present?(name) or present?(handle) do
      %{"role" => role, "name" => name, "handle" => handle}
      |> drop_blank_values()
    end
  end

  defp dedupe_participants(entries) do
    entries
    |> Enum.reduce({[], MapSet.new()}, fn entry, {acc, seen} ->
      key = participant_key(entry)

      cond do
        MapSet.member?(seen, key) -> {acc, seen}
        true -> {[entry | acc], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> drop_redundant_generic_participants()
  end

  defp participant_key(entry) do
    handle = entry |> read_string("handle") |> normalize_key()
    name = entry |> read_string("name") |> normalize_key()
    handle || name
  end

  # A role-tagged entry (from/to/cc/bcc) beats a generic "participant" entry
  # for the same person; drop participant entries whose name matches a
  # role-tagged entry's name.
  defp drop_redundant_generic_participants(entries) do
    role_names =
      entries
      |> Enum.reject(&(read_string(&1, "role") == "participant"))
      |> Enum.map(&normalize_key(read_string(&1, "name")))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reject(entries, fn entry ->
      read_string(entry, "role") == "participant" and
        MapSet.member?(role_names, normalize_key(read_string(entry, "name")))
    end)
  end

  defp normalize_key(nil), do: nil

  defp normalize_key(value) when is_binary(value) do
    case value |> String.downcase() |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  # ---------------------------------------------------------------------------
  # Conversation
  # ---------------------------------------------------------------------------

  defp conversation(user_id, metadata, _source) do
    local_thread(user_id, metadata) || excerpt_thread(metadata) || []
  end

  defp local_thread(user_id, metadata) when is_binary(user_id) do
    chat_key =
      first_present([
        read_string(metadata, "chat_key"),
        read_string(read_map(metadata, "record"), "chat_key")
      ])

    with true <- present?(chat_key),
         messages when messages != [] <-
           LocalMessages.recent_for_chat(user_id, chat_key, limit: @max_conversation_messages) do
      messages
      |> Enum.reverse()
      |> Enum.map(fn message ->
        %{
          "speaker" => local_speaker(message),
          "text" => message.text |> to_string() |> clean_text(),
          "at" => datetime_iso(message.sent_at),
          "from_user" => message.is_from_me == true
        }
        |> drop_blank_values()
      end)
      |> Enum.reject(&blank?(read_string(&1, "text")))
      |> case do
        [] -> nil
        thread -> thread
      end
    else
      _ -> nil
    end
  rescue
    _exception -> nil
  end

  defp local_thread(_user_id, _metadata), do: nil

  defp local_speaker(message) do
    cond do
      message.is_from_me -> "You"
      present?(message.chat_display_name) and message.chat_style != "group" -> message.chat_display_name
      present?(message.sender_handle) -> message.sender_handle
      true -> "Them"
    end
  end

  defp excerpt_thread(metadata) do
    speaker =
      first_present([
        read_string(metadata, "sender_name"),
        speaker_from_header(read_string(metadata, "from")),
        read_string(metadata, "person")
      ])

    @excerpt_keys
    |> Enum.map(&read_field(metadata, &1))
    |> Enum.flat_map(&excerpt_values/1)
    |> Enum.map(&clean_text/1)
    |> Enum.filter(&public_text?/1)
    |> Enum.uniq()
    |> Enum.take(3)
    |> Enum.map(fn text ->
      %{"speaker" => speaker, "text" => text}
      |> drop_blank_values()
    end)
    |> case do
      [] -> nil
      thread -> thread
    end
  end

  defp excerpt_values(value) when is_binary(value), do: [value]
  defp excerpt_values(values) when is_list(values), do: Enum.flat_map(values, &excerpt_values/1)

  defp excerpt_values(%{} = value) do
    [
      read_string(value, "excerpt"),
      read_string(value, "quote"),
      read_string(value, "text"),
      read_string(value, "detail")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp excerpt_values(_value), do: []

  defp speaker_from_header(value) when is_binary(value) do
    case Regex.run(~r/^\s*"?([^"<@]+?)"?\s*</, value) do
      [_all, name] -> clean_name(name)
      _other -> if email_like?(value), do: String.trim(value)
    end
  end

  defp speaker_from_header(_value), do: nil

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp nested_maps(map) when is_map(map) do
    ~w(draft message headers)
    |> Enum.map(&read_map(map, &1))
    |> Enum.reject(&(map_size(&1) == 0))
  end

  defp nested_maps(_map), do: []

  defp clean_name(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim(" .,\"'")
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp clean_name(_value), do: nil

  defp clean_handle(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      email_like?(value) -> extract_email(value)
      phone_like?(value) -> value
      true -> nil
    end
  end

  defp clean_handle(_value), do: nil

  defp safe_handle?(value) when is_binary(value), do: email_like?(value) or phone_like?(value)
  defp safe_handle?(_value), do: false

  defp email_like?(value) when is_binary(value) do
    Regex.match?(~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i, value)
  end

  defp email_like?(_value), do: false

  defp extract_email(value) do
    case Regex.run(~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i, value) do
      [email] -> String.downcase(email)
      _other -> nil
    end
  end

  defp phone_like?(value) when is_binary(value) do
    digits = String.replace(value, ~r/[^0-9]/, "")
    String.length(digits) >= 7 and Regex.match?(~r/^\+?[0-9 ().\-]+$/, String.trim(value))
  end

  defp phone_like?(_value), do: false

  defp clean_text(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(@max_message_chars)
  end

  defp clean_text(_value), do: nil

  defp public_text?(value) when is_binary(value) do
    String.trim(value) != "" and PublicMetadata.public_text?(value)
  end

  defp public_text?(_value), do: false

  defp truncate(value, max) when is_binary(value) do
    if String.length(value) > max do
      String.slice(value, 0, max) <> "..."
    else
      value
    end
  end

  defp datetime_iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_iso(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime_iso(_value), do: nil

  defp read_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp read_field(_map, _key), do: nil

  defp atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp read_string(map, key) do
    case read_field(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp read_map(map, key) do
    case read_field(map, key) do
      %{} = value -> value
      _other -> %{}
    end
  end

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp blank?(value), do: not present?(value)

  defp drop_blank_values(map) when is_map(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      _entry -> false
    end)
  end
end
