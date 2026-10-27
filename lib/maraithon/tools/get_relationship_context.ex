defmodule Maraithon.Tools.GetRelationshipContext do
  @moduledoc """
  Fetch relationship context for a person, including linked work items.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Crm
  alias Maraithon.Tools.PersonHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      case Crm.relationship_context(user_id, args) do
        {:ok, context} ->
          {:ok,
           %{
             source: "maraithon_crm",
             relationship_context: PersonHelpers.serialize_relationship_context(context)
           }}

        {:error, reason} ->
          {:error, normalize_error(reason)}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp normalize_error(:person_not_found), do: "person_not_found"
  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: safe_error(reason)
end
