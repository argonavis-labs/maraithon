defmodule Maraithon.Crm.Confirmations do
  @moduledoc "Explicit human review of inferred people and their contact details. Never called by model tools."
  import Ecto.Query
  alias Maraithon.{Crm, LifeContext, Memory, Repo, Todos}
  alias Maraithon.Crm.Person
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Todos.Brief

  @fields ~w(display_name relationship notes contact_details)

  def review(user_id, %{"person_id" => id}) when is_binary(id) and id != "" do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Person{status: "active"} = person <- Crm.get_person_for_user(user_id, id) do
      {:ok, serialize(person)}
    else
      _ -> {:error, :not_found}
    end
  end

  def review(user_id, %{"note_id" => id, "index" => index}) do
    with note when not is_nil(note) <- LifeContext.get(user_id, id),
         proposal when is_map(proposal) <-
           Enum.find(note.metadata["people"] || [], &(to_string(&1["index"]) == to_string(index))) do
      case proposal["person_id"] && Crm.get_person_for_user(user_id, proposal["person_id"]) do
        %Person{status: "active"} = person ->
          {:ok,
           serialize(person)
           |> Map.put(:suggested_relationship, proposal["relationship"])
           |> Map.put(:suggested_notes, proposal["notes"])}

        _ ->
          {:ok,
           %{
             id: nil,
             name: proposal["name"],
             relationship: proposal["relationship"],
             notes: proposal["notes"],
             emails: proposal["emails"] || [],
             phones: proposal["phones"] || [],
             confirmed_at: nil,
             suggested_relationship: nil,
             suggested_notes: nil
           }}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def review(user_id, %{"todo_id" => todo_id, "reference" => reference}) do
    with {:ok, todo_id} <- Ecto.UUID.cast(todo_id),
         todo when not is_nil(todo) <- Todos.get_for_user(user_id, todo_id),
         brief when is_map(brief) <- Brief.current(todo) || Brief.stored(todo),
         person when is_map(person) <- Enum.find(brief["people"] || [], &(&1["id"] == reference)) do
      linked_id =
        Repo.one(
          from link in Crm.PersonLink,
            where:
              link.user_id == ^user_id and link.resource_type == "todo" and
                link.resource_id == ^todo_id,
            where: fragment("?->>'brief_reference' = ?", link.metadata, ^reference),
            select: link.person_id,
            limit: 1
        )

      case review(user_id, %{"person_id" => linked_id || reference}) do
        {:ok, details} ->
          {:ok, details}

        _ ->
          {:ok,
           %{
             id: nil,
             name: person["name"],
             relationship: person["relationship"],
             notes: person["context"],
             emails: [],
             phones: [],
             confirmed_at: nil,
             suggested_relationship: nil,
             suggested_notes: nil
           }}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def review(_, _), do: {:error, :not_found}

  def confirm(user_id, params) do
    values = params["details"] || %{}
    emails = contact_values(values["emails"])
    phones = contact_values(values["phones"])
    request_id = params["request_id"]

    with {:ok, request_id} <- Ecto.UUID.cast(request_id),
         true <- valid_contacts?(emails, phones) do
      Repo.transaction(fn ->
        WriteFence.lock_user_writable!(user_id)

        details =
          case review(user_id, params) do
            {:ok, details} -> details
            {:error, reason} -> Repo.rollback(reason)
          end

        previous =
          Repo.one(
            from p in Person,
              where: p.user_id == ^user_id and p.status == "active",
              where: fragment("?->>'confirmation_request_id' = ?", p.metadata, ^request_id),
              limit: 1
          )

        person = previous || existing_person(user_id, details.id, emails ++ phones)
        person = person || %Person{user_id: user_id}

        contacts =
          Map.merge(
            Map.drop(person.contact_details || %{}, ~w(emails email phones phone phone_number)),
            %{"emails" => emails, "phones" => phones}
          )

        attrs = %{
          "display_name" => LifeContext.text(values["name"], 240),
          "relationship" => LifeContext.text(values["relationship"], 160),
          "notes" => LifeContext.text(values["notes"], 8_000),
          "contact_details" => contacts
        }

        snapshot = Map.put(attrs, "confirmed_at", LifeContext.timestamp())

        metadata =
          (person.metadata || %{})
          |> Map.put("confirmed_details", snapshot)
          |> Map.put("confirmation_request_id", request_id)

        changeset =
          person
          |> Person.changeset(Map.put(attrs, "metadata", metadata))
          |> Ecto.Changeset.put_change(:contact_details, contacts)

        confirmed =
          case Repo.insert_or_update(changeset) do
            {:ok, confirmed} -> confirmed
            {:error, reason} -> Repo.rollback(reason)
          end

        write_memory!(confirmed)
        LifeContext.invalidate_todos!(user_id)
        record_note_confirmation!(user_id, params, confirmed)
        link_todo!(user_id, params, confirmed)
        confirmed
      end)
      |> case do
        {:ok, person} ->
          Crm.PersonEmbeddings.refresh_async(person)
          {:ok, serialize(person)}

        error ->
          error
      end
    else
      _ -> {:error, :invalid_contact_details}
    end
  end

  def serialize(%Person{} = person) do
    contacts = person.contact_details || %{}

    %{
      id: person.id,
      name: person.display_name,
      relationship: person.relationship,
      notes: person.notes,
      emails: contacts["emails"] || [],
      phones: contacts["phones"] || [],
      confirmed_at: get_in(person.metadata || %{}, ["confirmed_details", "confirmed_at"]),
      suggested_relationship: nil,
      suggested_notes: nil
    }
  end

  # Discovery can still add evidence but cannot overwrite a human-confirmed identity.
  def protect_inferred(%Person{} = person, attrs) do
    case (person.metadata || %{})["confirmed_details"] do
      %{} = confirmed ->
        attrs
        |> Map.drop(
          ~w(contacts email emails phone phone_number phones slack_id slack_ids telegram_id telegram_ids)
        )
        |> Map.merge(Map.take(confirmed, @fields))

      _ ->
        attrs
    end
  end

  def merge_update_attrs(%Person{} = person, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    incoming = if is_map(attrs["metadata"]), do: attrs["metadata"], else: %{}
    incoming = Map.drop(incoming, ~w(confirmed_details confirmation_request_id))
    Map.put(attrs, "metadata", Map.merge(person.metadata || %{}, incoming))
  end

  def invalidate_changed_confirmation(changeset, person) do
    if Enum.any?(
         [:display_name, :relationship, :notes, :contact_details],
         &(Ecto.Changeset.get_field(changeset, &1) != Map.get(person, &1))
       ) do
      metadata = Ecto.Changeset.get_field(changeset, :metadata) || %{}
      Ecto.Changeset.put_change(changeset, :metadata, Map.delete(metadata, "confirmed_details"))
    else
      changeset
    end
  end

  def after_update({:ok, updated} = result, previous) do
    if Map.has_key?(previous.metadata || %{}, "confirmed_details") and
         not Map.has_key?(updated.metadata || %{}, "confirmed_details") do
      if memory =
           Repo.get_by(Memory.Item,
             user_id: previous.user_id,
             dedupe_key: "confirmed-person:#{previous.id}",
             status: "active"
           ) do
        case Memory.forget(previous.user_id, memory.id, source: "person_correction") do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      LifeContext.invalidate_todos!(previous.user_id)
    end

    result
  end

  def after_update(result, _previous), do: result

  defp existing_person(user_id, id, _contacts) when is_binary(id) do
    Repo.one(
      from p in Person,
        where: p.user_id == ^user_id and p.id == ^id and p.status == "active",
        lock: "FOR UPDATE"
    ) ||
      Repo.rollback(:not_found)
  end

  defp existing_person(user_id, nil, contacts) do
    matches =
      contacts
      |> Enum.map(&Crm.find_person_by_contact(user_id, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    case matches do
      [] -> nil
      [person] -> existing_person(user_id, person.id, [])
      _ -> Repo.rollback(:ambiguous_contacts)
    end
  end

  defp record_note_confirmation!(user_id, %{"note_id" => id, "index" => index}, person) do
    case LifeContext.transaction(user_id, id, fn note ->
           people =
             Enum.map(note.metadata["people"] || [], fn proposal ->
               if to_string(proposal["index"]) == to_string(index),
                 do:
                   Map.merge(proposal, %{
                     "person_id" => person.id,
                     "confirmed_at" => LifeContext.timestamp()
                   }),
                 else: proposal
             end)

           LifeContext.update!(note, %{"people" => people})
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp record_note_confirmation!(_, _, _), do: :ok

  defp link_todo!(user_id, %{"todo_id" => id} = params, person) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         todo when not is_nil(todo) <- Todos.get_for_user(user_id, id) do
      case Crm.attach_resource(user_id, person.id, %{
             resource_type: "todo",
             resource_id: id,
             source_system: "person_confirmation",
             metadata: %{"brief_reference" => params["reference"]},
             confidence: 1.0
           }) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp link_todo!(_, _, _), do: :ok

  defp write_memory!(person) do
    content =
      ["#{person.display_name} is a confirmed contact", person.relationship, person.notes]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(". ")

    case Memory.write(person.user_id, %{
           "kind" => "relationship",
           "title" => "Confirmed: #{String.slice(person.display_name, 0, 200)}",
           "content" => content,
           "source" => "person_confirmation",
           "source_ref_type" => "person",
           "source_ref_id" => person.id,
           "author_type" => "user",
           "confidence" => 1.0,
           "importance" => 90,
           "tags" => ["life_work_context"],
           "dedupe_key" => "confirmed-person:#{person.id}"
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp contact_values(value) when is_binary(value),
    do: contact_values(String.split(value, ~r/[,;\n]/))

  defp contact_values(value), do: LifeContext.strings(value, 8, 240)

  defp valid_contacts?(emails, phones) do
    Enum.all?(emails, &Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u, &1)) and
      Enum.all?(phones, &(String.length(String.replace(&1, ~r/\D/, "")) in 7..15))
  end
end
