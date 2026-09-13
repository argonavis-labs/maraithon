defmodule Maraithon.PeopleNetwork.Identity do
  @moduledoc "Resolves observed identifiers without guessing from a person's name."
  import Ecto.Query
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Crm.Person
  alias Maraithon.LocalContacts.LocalContact
  alias Maraithon.PeopleNetwork.ReadRepo

  def load(user_id) do
    people =
      ReadRepo.all(
        from p in Person,
          where: p.user_id == ^user_id,
          limit: 15_001,
          select:
            struct(p, [
              :id,
              :display_name,
              :relationship,
              :contact_details,
              :status,
              :merged_into_id
            ])
      )

    if length(people) > 15_000, do: throw(:people_network_budget_exceeded)
    records = Map.new(people, &{&1.id, &1})
    own = own_handles(user_id)

    self_ids =
      people
      |> Enum.filter(&Enum.any?(handles(&1.contact_details), fn h -> MapSet.member?(own, h) end))
      |> Enum.map(&canonical_id(&1.id, records, MapSet.new()))
      |> MapSet.new()

    hidden =
      people
      |> Enum.filter(&(&1.status == "archived" or MapSet.member?(self_ids, &1.id)))
      |> Enum.flat_map(&handles(&1.contact_details))
      |> MapSet.new()

    nodes =
      people
      |> Enum.filter(&(&1.status == "active" and not MapSet.member?(self_ids, &1.id)))
      |> Map.new(fn p ->
        {p.id,
         %{
           id: p.id,
           person_id: p.id,
           name: p.display_name,
           subtitle: p.relationship,
           handles: handles(p.contact_details)
         }}
      end)

    index =
      people
      |> Enum.flat_map(fn p ->
        id = canonical_id(p.id, records, MapSet.new())
        if Map.has_key?(nodes, id), do: Enum.map(handles(p.contact_details), &{&1, id}), else: []
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {handle, ids} ->
        {handle,
         case Enum.uniq(ids) do
           [id] -> id
           _ -> :ambiguous
         end}
      end)

    contacts =
      ReadRepo.all(
        from c in LocalContact,
          where: c.user_id == ^user_id,
          select: %{
            name: c.display_name,
            company: c.organization_name,
            emails: c.emails,
            phones: c.phones
          }
      )
      |> Enum.flat_map(fn c ->
        Enum.map(handles(%{"emails" => c.emails, "phones" => c.phones}), &{&1, c})
      end)
      |> Map.new()

    %{nodes: nodes, index: index, own: MapSet.union(own, hidden), contacts: contacts}
  end

  def resolve(identity, %{handle: handle} = participant) when is_binary(handle) do
    cond do
      MapSet.member?(identity.own, handle) ->
        nil

      Map.get(identity.index, handle) == :ambiguous ->
        nil

      id = Map.get(identity.index, handle) ->
        Map.get(identity.nodes, id)

      true ->
        contact = Map.get(identity.contacts, handle, %{})
        name = text(contact[:name]) || text(participant[:name]) || display_handle(handle)

        %{
          id: node_id(handle),
          person_id: nil,
          name: name,
          subtitle: text(contact[:company]),
          handles: [handle]
        }
    end
  end

  def resolve(_identity, _participant), do: nil

  def participant(raw) when is_map(raw) do
    identifiers = raw["identifier"] || %{}

    handle =
      normalize(identifiers["email"]) || normalize(identifiers["phone"]) ||
        slack_handle(identifiers["slack_id"])

    %{handle: handle, name: raw["display_name"], role: raw["role"]}
  end

  def participant(_raw), do: %{handle: nil, name: nil, role: nil}

  def handles(details) do
    details = details || %{}

    (Enum.map(List.wrap(details["emails"]) ++ List.wrap(details["phones"]), &normalize/1) ++
       Enum.map(List.wrap(details["slack_ids"]), &slack_handle/1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def normalize(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "slack:") ->
        value

      String.contains?(value, "@") ->
        Maraithon.UserIdentity.normalize_handle(value)

      Regex.match?(~r/^\+?[\d\s().-]{7,24}$/, value) ->
        Maraithon.UserIdentity.normalize_handle(value)

      true ->
        nil
    end
  end

  def normalize(_value), do: nil

  defp own_handles(user_id) do
    accounts =
      ReadRepo.all(
        from a in ConnectedAccount,
          where: a.user_id == ^user_id,
          select: %{provider: a.provider, metadata: a.metadata}
      )

    slack =
      Enum.flat_map(accounts, fn a ->
        if String.starts_with?(a.provider, "slack") do
          Enum.map(
            ~w(authed_user_id slack_user_id bot_user_id),
            &slack_handle((a.metadata || %{})[&1])
          )
        else
          []
        end
      end)

    Enum.into(Enum.reject(slack, &is_nil/1), Maraithon.UserIdentity.handle_set(user_id))
  end

  defp canonical_id(id, records, visited) do
    if MapSet.member?(visited, id) do
      nil
    else
      case Map.get(records, id) do
        %Person{status: "active"} ->
          id

        %Person{status: "merged", merged_into_id: next} when is_binary(next) ->
          canonical_id(next, records, MapSet.put(visited, id))

        _ ->
          nil
      end
    end
  end

  defp slack_handle(value) when is_binary(value) and value != "", do: "slack:#{value}"
  defp slack_handle(_value), do: nil

  defp node_id(handle),
    do: "observed_" <> Base.url_encode64(:crypto.hash(:sha256, handle), padding: false)

  defp display_handle("slack:" <> id), do: "Slack member #{id}"
  defp display_handle(handle), do: handle

  defp text(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp text(_value), do: nil
end
