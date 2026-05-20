defmodule Maraithon.Tools.MergePeople do
  @moduledoc """
  Merge two CRM people with an audit trail.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Crm
  alias Maraithon.Tools.PersonHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, surviving_id} <- required_string(args, "surviving_person_id"),
         {:ok, merged_id} <- required_string(args, "merged_person_id") do
      attrs =
        args
        |> Map.take(["evidence", "model_rationale", "rationale", "performed_by", "metadata"])

      case Crm.merge_people(user_id, surviving_id, merged_id, attrs) do
        {:ok, result} ->
          {:ok,
           %{
             source: "maraithon_crm",
             merge: PersonHelpers.serialize_merge_result(result)
           }}

        {:error, reason} ->
          {:error, normalize_error(reason)}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp normalize_error(:cannot_merge_person_into_self), do: "cannot_merge_person_into_self"
  defp normalize_error(:survivor_already_merged), do: "survivor_already_merged"
  defp normalize_error(:person_already_merged), do: "person_already_merged"
  defp normalize_error(:person_not_active), do: "person_not_active"
  defp normalize_error(:person_not_found), do: "person_not_found"
  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: inspect(reason)
end
