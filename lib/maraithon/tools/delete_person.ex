defmodule Maraithon.Tools.DeletePerson do
  @moduledoc """
  Delete one CRM person for a user.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Crm
  alias Maraithon.Tools.PersonHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, person_id} <- required_string(args, "person_id") do
      case Crm.delete_person(user_id, person_id) do
        {:ok, person} ->
          {:ok,
           %{
             source: "maraithon_crm",
             deleted: true,
             person: PersonHelpers.serialize_person(person)
           }}

        {:error, reason} ->
          {:error, normalize_error(reason)}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp normalize_error(:person_not_found), do: "person_not_found"
  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: inspect(reason)
end
