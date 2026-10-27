defmodule Maraithon.Tools.GetPerson do
  @moduledoc """
  Get one CRM person and optionally their attached relationship context.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Crm
  alias Maraithon.Tools.PersonHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      include_links = Map.get(args, "include_links", true) != false

      result =
        if include_links do
          Crm.relationship_context(user_id, args)
        else
          get_person_only(user_id, args)
        end

      case result do
        {:ok, %{person: _person} = context} ->
          {:ok,
           %{
             source: "maraithon_crm",
             relationship_context: PersonHelpers.serialize_relationship_context(context)
           }}

        {:ok, person} ->
          {:ok,
           %{
             source: "maraithon_crm",
             person: PersonHelpers.serialize_person(person)
           }}

        {:error, reason} ->
          {:error, normalize_error(reason)}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp get_person_only(user_id, args) do
    case optional_string(args, "person_id") || optional_string(args, "id") do
      nil ->
        case Crm.relationship_context(user_id, args) do
          {:ok, %{person: person}} -> {:ok, person}
          {:error, reason} -> {:error, reason}
        end

      person_id ->
        case Crm.get_person_for_user(user_id, person_id) do
          nil -> {:error, :person_not_found}
          person -> {:ok, person}
        end
    end
  end

  defp normalize_error(:person_not_found), do: "person_not_found"
  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: safe_error(reason)
end
