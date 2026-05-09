defmodule Maraithon.Tools.LearnRelationshipContext do
  @moduledoc """
  Model-backed CRM and memory learning from source observations.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.RelationshipIntelligence

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      observations = Map.get(args, "observations", [])

      cond do
        not is_list(observations) ->
          {:error, "observations is required"}

        true ->
          case RelationshipIntelligence.learn_from_observations(
                 user_id,
                 Enum.filter(observations, &is_map/1),
                 source: optional_string(args, "source") || "learn_relationship_context"
               ) do
            {:ok, result} -> {:ok, result}
            {:error, reason} -> {:error, normalize_error(reason)}
          end
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: inspect(reason)
end
