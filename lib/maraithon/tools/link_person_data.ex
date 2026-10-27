defmodule Maraithon.Tools.LinkPersonData do
  @moduledoc """
  Attach or detach a CRM person from a todo or other user-owned data object.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Crm
  alias Maraithon.Tools.PersonHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, person_id} <- required_string(args, "person_id") do
      operation = optional_string(args, "operation") || "attach"
      attrs = PersonHelpers.link_attrs(args)

      case operation do
        "attach" ->
          attach(user_id, person_id, attrs, args)

        "upsert" ->
          attach(user_id, person_id, attrs, args)

        "detach" ->
          detach(user_id, person_id, attrs)

        "delete" ->
          detach(user_id, person_id, attrs)

        _other ->
          {:error, "unsupported_person_link_operation"}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp attach(user_id, person_id, attrs, args) do
    case Crm.attach_resource(user_id, person_id, attrs) do
      {:ok, link} ->
        result = %{
          source: "maraithon_crm",
          operation: "attach",
          link: PersonHelpers.serialize_link(link)
        }

        maybe_add_context(result, user_id, person_id, args)

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp detach(user_id, person_id, attrs) do
    case Crm.detach_resource(user_id, person_id, attrs) do
      {:ok, link} ->
        {:ok,
         %{
           source: "maraithon_crm",
           operation: "detach",
           link: PersonHelpers.serialize_link(link)
         }}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp maybe_add_context(result, user_id, person_id, %{"include_context" => true}) do
    case Crm.relationship_context(user_id, %{"person_id" => person_id}) do
      {:ok, context} ->
        {:ok,
         Map.put(
           result,
           :relationship_context,
           PersonHelpers.serialize_relationship_context(context)
         )}

      {:error, _reason} ->
        {:ok, result}
    end
  end

  defp maybe_add_context(result, _user_id, _person_id, _args), do: {:ok, result}

  defp normalize_error(:person_not_found), do: "person_not_found"
  defp normalize_error(:person_link_not_found), do: "person_link_not_found"
  defp normalize_error(:missing_resource_type), do: "missing_resource_type"
  defp normalize_error(:missing_resource_id), do: "missing_resource_id"
  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: safe_error(reason)
end
