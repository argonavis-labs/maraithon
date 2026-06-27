defmodule Maraithon.LocalContacts do
  @moduledoc """
  Context for macOS Contacts.app records synced from a companion Mac.

  This source has two outputs:

    * `local_contacts` rows for device stats, audit, and purging.
    * CRM people merged by durable identifiers: Apple contact id first,
      then email, then phone. Name-only contacts intentionally do not use
      fuzzy matching so two people with the same name are not collapsed.
  """

  import Ecto.Query

  require Logger

  alias Maraithon.Crm
  alias Maraithon.Crm.Person
  alias Maraithon.LocalContacts.LocalContact
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs

  @upsert_fields [
    :local_id,
    :display_name,
    :first_name,
    :middle_name,
    :last_name,
    :nickname,
    :organization_name,
    :department_name,
    :job_title,
    :emails,
    :phones,
    :urls,
    :postal_addresses,
    :payload_hash,
    :updated_at
  ]

  @doc """
  Ingests a batch of Apple Contacts payloads from a companion device.

  Returns `{:ok, %{accepted: integer, duplicate: integer, invalid: integer}}`.
  Contacts are mutable, so refreshed rows are reported as accepted in the
  same way Calendar and Reminders upserts are.
  """
  def ingest_batch(user_id, device_id, contacts)
      when is_binary(user_id) and is_binary(device_id) and is_list(contacts) do
    started_at = System.monotonic_time(:millisecond)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {prepared, invalid} =
      contacts
      |> Enum.map(&prepare_row(&1, user_id, device_id, now))
      |> Enum.split_with(&match?({:ok, _row}, &1))

    rows =
      prepared
      |> Enum.map(fn {:ok, row} -> row end)

    {affected_count, affected_rows} =
      if rows == [] do
        {0, []}
      else
        Repo.insert_all(LocalContact, rows,
          on_conflict: {:replace, @upsert_fields},
          conflict_target: [:user_id, :device_id, :source, :guid],
          returning: [:id, :guid, :display_name]
        )
      end

    enqueue_crm_merge(user_id, affected_rows)

    total = length(rows)
    accepted_count = affected_count
    duplicate_count = max(total - affected_count, 0)
    invalid_count = length(invalid)
    latency_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:maraithon, :companion, :contacts_ingested],
      %{
        count: length(contacts),
        accepted: accepted_count,
        duplicate: duplicate_count,
        invalid: invalid_count,
        latency_ms: latency_ms
      },
      %{user_id: user_id, device_id: device_id}
    )

    {:ok,
     %{
       accepted: accepted_count,
       duplicate: duplicate_count,
       invalid: invalid_count
     }}
  end

  def ingest_batch(_user_id, _device_id, _contacts), do: {:error, :invalid_batch}

  @doc """
  Merges previously mirrored Contacts rows into CRM people.

  This is intentionally separate from `ingest_batch/3` so companion HTTP
  requests can acknowledge local mirroring quickly while the durable background
  job runner handles slower CRM matching and resource linking.
  """
  def merge_contacts_into_crm(user_id, contact_ids)
      when is_binary(user_id) and is_list(contact_ids) do
    ids =
      contact_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    contacts =
      LocalContact
      |> where([contact], contact.user_id == ^user_id and contact.id in ^ids)
      |> Repo.all()

    lookup = crm_contact_lookup(user_id)

    {merged, failed, _lookup} =
      Enum.reduce(contacts, {0, 0, lookup}, fn contact, {merged, failed, lookup} ->
        case merge_contact_record_into_crm(user_id, contact, lookup) do
          {:ok, person} -> {merged + 1, failed, put_lookup_person(lookup, person)}
          {:error, _reason} -> {merged, failed + 1, lookup}
        end
      end)

    _ = BackgroundJobs.enqueue_person_dedupe(user_id)
    _ = BackgroundJobs.enqueue_goal_people_discovery(user_id)

    {:ok,
     %{
       source: "local_contacts_crm_merge",
       matched: length(contacts),
       merged: merged,
       failed: failed
     }}
  end

  def merge_contacts_into_crm(_user_id, _contact_ids), do: {:error, :invalid_batch}

  defp enqueue_crm_merge(_user_id, []), do: :ok

  defp enqueue_crm_merge(user_id, affected_rows) do
    contact_ids =
      affected_rows
      |> Enum.map(& &1.id)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if contact_ids == [] do
      :ok
    else
      digest =
        contact_ids
        |> Enum.sort()
        |> Enum.join(":")
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)

      case BackgroundJobs.enqueue("local_contacts_crm_merge", %{
             "user_id" => user_id,
             "queue" => "local_contacts",
             "payload" => %{"contact_ids" => contact_ids},
             "dedupe_key" => "local_contacts_crm_merge:#{user_id}:#{digest}",
             "max_attempts" => 5
           }) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning("apple contact CRM merge enqueue failed",
            reason: inspect(reason),
            user_id: user_id,
            contact_count: length(contact_ids)
          )

          :ok
      end
    end
  end

  @doc """
  Purges every synced contact row for a user/device pair. The merged CRM people
  remain, because those people may also contain email, phone, message, calendar,
  or manual CRM evidence from other sources.
  """
  def purge_device(user_id, device_id) when is_binary(user_id) do
    {deleted, _} =
      Repo.delete_all(
        from contact in LocalContact,
          where: contact.user_id == ^user_id and contact.device_id == ^device_id
      )

    {:ok, %{deleted: deleted}}
  end

  def purge_device(_user_id, _device_id), do: {:error, :invalid_device}

  defp prepare_row(contact, user_id, device_id, now) when is_map(contact) do
    attrs = %{
      user_id: user_id,
      device_id: device_id,
      source: text(fetch(contact, :source)) || "contacts",
      guid: text(fetch(contact, :guid) || fetch(contact, :identifier)),
      local_id: text(fetch(contact, :local_id)),
      display_name: text(fetch(contact, :display_name) || fetch(contact, :name)),
      first_name: text(fetch(contact, :first_name) || fetch(contact, :given_name)),
      middle_name: text(fetch(contact, :middle_name)),
      last_name: text(fetch(contact, :last_name) || fetch(contact, :family_name)),
      nickname: text(fetch(contact, :nickname)),
      organization_name: text(fetch(contact, :organization_name) || fetch(contact, :company)),
      department_name: text(fetch(contact, :department_name)),
      job_title: text(fetch(contact, :job_title) || fetch(contact, :title)),
      emails: normalize_email_list(fetch(contact, :emails)),
      phones: normalize_string_list(fetch(contact, :phones)),
      urls: normalize_string_list(fetch(contact, :urls)),
      postal_addresses: %{"items" => normalize_address_list(fetch(contact, :postal_addresses))}
    }

    attrs =
      attrs
      |> Map.put(:display_name, attrs.display_name || display_name_from_attrs(attrs))
      |> Map.put(:payload_hash, text(fetch(contact, :payload_hash)) || payload_hash(attrs))

    changeset = LocalContact.changeset(%LocalContact{}, attrs)

    if changeset.valid? do
      struct = Ecto.Changeset.apply_changes(changeset)

      row =
        LocalContact.__schema__(:fields)
        |> Kernel.--([:id, :inserted_at, :updated_at])
        |> Enum.into(%{}, fn field -> {field, Map.get(struct, field)} end)
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)

      {:ok, row}
    else
      {:error, changeset}
    end
  end

  defp prepare_row(_other, _user_id, _device_id, _now), do: {:error, :invalid}

  defp merge_contact_record_into_crm(user_id, %LocalContact{} = contact, lookup) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    row = contact_row(contact)

    case merge_row_into_crm(row, user_id, contact.device_id, now, lookup) do
      {:ok, merged_row, person} ->
        Repo.update_all(
          from(candidate in LocalContact, where: candidate.id == ^contact.id),
          set: [
            crm_person_id: merged_row.crm_person_id,
            updated_at: now
          ]
        )

        attach_crm_links(user_id, [%{merged_row | id: contact.id}])
        {:ok, person}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp contact_row(%LocalContact{} = contact) do
    LocalContact.__schema__(:fields)
    |> Enum.into(%{}, fn field -> {field, Map.get(contact, field)} end)
  end

  defp merge_row_into_crm(row, user_id, device_id, %DateTime{} = now, lookup) do
    existing = existing_person_for_row(row, lookup, user_id)
    attrs = crm_attrs(row, existing, device_id, now)

    result =
      case existing do
        %Person{} = person -> Crm.update_person(person, attrs)
        nil -> Crm.upsert_person(user_id, attrs)
      end

    case result do
      {:ok, %Person{} = person} ->
        {:ok, Map.put(row, :crm_person_id, person.id), person}

      {:error, reason} ->
        Logger.warning("apple contact CRM merge failed",
          reason: inspect(reason),
          user_id: user_id,
          device_id: device_id,
          guid: row.guid
        )

        {:error, reason}
    end
  end

  defp existing_person_for_row(row, lookup, user_id) do
    find_lookup_person(lookup, "apple_contact_ids", row.guid) ||
      Enum.find_value(row.emails || [], &find_lookup_person(lookup, "emails", &1)) ||
      Enum.find_value(row.phones || [], &find_lookup_person(lookup, "phones", &1)) ||
      find_lookup_person(lookup, "display_names", display_name_from_row(row)) ||
      find_person_by_exact_display_name(user_id, display_name_from_row(row))
  end

  defp find_person_by_exact_display_name(user_id, display_name) do
    if specific_display_name?(display_name) do
      normalized = normalize_name(display_name)

      Person
      |> where([person], person.user_id == ^user_id and person.status == "active")
      |> where([person], fragment("lower(?)", person.display_name) == ^normalized)
      |> order_by([person],
        desc: person.communication_score,
        desc: person.relationship_strength,
        desc: person.affinity_score,
        desc: person.updated_at
      )
      |> limit(1)
      |> Repo.one()
    end
  end

  defp crm_contact_lookup(user_id) do
    Person
    |> where([person], person.user_id == ^user_id and person.status == "active")
    |> Repo.all()
    |> Enum.reduce(empty_lookup(), &put_lookup_person(&2, &1))
  end

  defp empty_lookup do
    %{
      "apple_contact_ids" => %{},
      "emails" => %{},
      "phones" => %{},
      "display_names" => %{}
    }
  end

  defp put_lookup_person(lookup, %Person{} = person) do
    contact_details = ensure_map(person.contact_details)

    lookup
    |> put_lookup_values(
      "apple_contact_ids",
      Map.get(contact_details, "apple_contact_ids"),
      person
    )
    |> put_lookup_values("emails", Map.get(contact_details, "emails"), person)
    |> put_lookup_values("phones", Map.get(contact_details, "phones"), person)
    |> put_lookup_values("display_names", [person.display_name], person)
  end

  defp put_lookup_values(lookup, kind, values, person) do
    values
    |> List.wrap()
    |> Enum.reduce(lookup, fn value, lookup ->
      kind
      |> lookup_keys(value)
      |> Enum.reduce(lookup, fn key, lookup ->
        update_in(lookup, [kind], &Map.put(&1 || %{}, key, person))
      end)
    end)
  end

  defp find_lookup_person(_lookup, _kind, nil), do: nil

  defp find_lookup_person(lookup, kind, value) do
    kind
    |> lookup_keys(value)
    |> Enum.find_value(fn key ->
      lookup
      |> Map.get(kind, %{})
      |> Map.get(key)
    end)
  end

  defp lookup_keys("emails", value) do
    case text(value) do
      nil -> []
      value -> [String.downcase(value)]
    end
  end

  defp lookup_keys("phones", value) do
    digits = phone_digits(value)

    cond do
      byte_size(digits) >= 10 ->
        [digits, "last10:" <> String.slice(digits, -10, 10)]

      digits != "" ->
        [digits]

      true ->
        []
    end
  end

  defp lookup_keys("display_names", value) do
    case text(value) do
      value when is_binary(value) ->
        if specific_display_name?(value), do: [normalize_name(value)], else: []

      nil ->
        []
    end
  end

  defp lookup_keys(_kind, value) do
    case text(value) do
      nil -> []
      value -> [value]
    end
  end

  defp crm_attrs(row, existing, device_id, %DateTime{} = now) do
    metadata = merge_person_metadata(existing, row, device_id, now)

    %{
      "contact_details" => contact_details(row),
      "metadata" => metadata
    }
    |> maybe_put_field(existing, "display_name", display_name_from_row(row))
    |> maybe_put_field(existing, "first_name", row.first_name)
    |> maybe_put_field(existing, "last_name", row.last_name)
  end

  defp maybe_put_field(attrs, nil, key, value), do: put_text(attrs, key, value)

  defp maybe_put_field(attrs, %Person{} = person, key, value) do
    field = key |> String.to_existing_atom()

    if blank?(Map.get(person, field)) do
      put_text(attrs, key, value)
    else
      attrs
    end
  end

  defp contact_details(row) do
    %{}
    |> put_list("apple_contact_ids", [row.guid])
    |> put_list("emails", row.emails)
    |> put_list("phones", row.phones)
    |> put_list("urls", row.urls)
    |> put_map("postal_addresses", row.postal_addresses)
  end

  defp merge_person_metadata(existing, row, device_id, %DateTime{} = now) do
    metadata =
      case existing do
        %Person{metadata: metadata} when is_map(metadata) -> metadata
        _ -> %{}
      end

    apple =
      metadata
      |> Map.get("apple_contacts", %{})
      |> ensure_map()

    apple =
      apple
      |> merge_metadata_list("contact_ids", [row.guid])
      |> merge_metadata_list("device_ids", [device_id])
      |> merge_metadata_list("organization_names", [row.organization_name])
      |> merge_metadata_list("department_names", [row.department_name])
      |> merge_metadata_list("job_titles", [row.job_title])
      |> Map.put("last_synced_at", DateTime.to_iso8601(now))

    metadata
    |> Map.put("apple_contacts", apple)
    |> merge_metadata_list("sources", ["apple_contacts"])
  end

  defp attach_crm_links(_user_id, []), do: :ok

  defp attach_crm_links(user_id, rows) do
    Enum.each(rows, fn
      %{crm_person_id: person_id, id: contact_id} = row
      when is_binary(person_id) and is_binary(contact_id) ->
        _ =
          Crm.attach_resource(user_id, person_id, %{
            "resource_type" => "local_contact",
            "resource_id" => contact_id,
            "resource_source" => "contacts",
            "source_system" => "companion",
            "source_ref" => row.guid,
            "title" => row.display_name,
            "metadata" => %{"apple_contact_id" => row.guid}
          })

        :ok

      _row ->
        :ok
    end)
  end

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_email_list(values) do
    values
    |> normalize_string_list()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(_), do: []

  defp normalize_address_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_address/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_address_list(_), do: []

  defp normalize_address(address) do
    %{}
    |> put_text("label", fetch(address, :label))
    |> put_text("street", fetch(address, :street))
    |> put_text("city", fetch(address, :city))
    |> put_text("state", fetch(address, :state))
    |> put_text("postal_code", fetch(address, :postal_code))
    |> put_text("country", fetch(address, :country))
  end

  defp put_list(map, _key, values) when values in [nil, []], do: map

  defp put_list(map, key, values) do
    values =
      values
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&text/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if values == [], do: map, else: Map.put(map, key, values)
  end

  defp put_map(map, _key, nil), do: map
  defp put_map(map, _key, value) when value == %{}, do: map
  defp put_map(map, key, value) when is_map(value), do: Map.put(map, key, value)
  defp put_map(map, _key, _value), do: map

  defp put_text(map, _key, nil), do: map
  defp put_text(map, key, value), do: Map.put(map, key, value)

  defp display_name_from_attrs(attrs) do
    [
      attrs[:display_name],
      [attrs.first_name, attrs.last_name]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" "),
      attrs.organization_name,
      List.first(attrs.emails || []),
      List.first(attrs.phones || [])
    ]
    |> Enum.find_value(&text/1)
  end

  defp display_name_from_row(row) do
    display_name_from_attrs(%{
      display_name: row.display_name,
      first_name: row.first_name,
      last_name: row.last_name,
      organization_name: row.organization_name,
      emails: row.emails,
      phones: row.phones
    }) || "Apple Contact #{String.slice(row.guid || "unknown", 0, 8)}"
  end

  defp payload_hash(attrs) do
    attrs
    |> Map.take([
      :guid,
      :display_name,
      :first_name,
      :middle_name,
      :last_name,
      :nickname,
      :organization_name,
      :department_name,
      :job_title,
      :emails,
      :phones,
      :urls,
      :postal_addresses
    ])
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp merge_metadata_list(map, key, values) do
    incoming =
      values
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&text/1)
      |> Enum.reject(&is_nil/1)

    existing =
      map
      |> Map.get(key, [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    merged = (existing ++ incoming) |> Enum.uniq()

    if merged == [] do
      map
    else
      Map.put(map, key, merged)
    end
  end

  defp text(value) when is_binary(value) do
    value
    |> Maraithon.TextSanitize.scrub()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_), do: nil

  defp phone_digits(value) when is_binary(value), do: String.replace(value, ~r/\D+/, "")
  defp phone_digits(_value), do: ""

  defp specific_display_name?(value) when is_binary(value) do
    value
    |> normalize_name()
    |> String.split(" ", trim: true)
    |> Enum.reject(&String.contains?(&1, "@"))
    |> length()
    |> Kernel.>=(2)
  end

  defp specific_display_name?(_value), do: false

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}@.]+/u, " ")
    |> String.trim()
  end

  defp blank?(value), do: text(value) == nil
end
