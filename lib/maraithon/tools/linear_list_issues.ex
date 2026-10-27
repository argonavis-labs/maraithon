defmodule Maraithon.Tools.LinearListIssues do
  @moduledoc """
  Lists Linear issues with common filters.
  """

  alias Maraithon.Connectors.Linear
  alias Maraithon.OAuth
  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.ToolErrorCopy

  @default_limit 25
  @max_limit 100

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, access_token} <- OAuth.get_valid_access_token(user_id, "linear"),
         {:ok, result} <- Linear.list_issues(access_token, build_opts(args)) do
      issues = Map.get(result, :issues, [])

      {:ok,
       %{
         source: "linear",
         count: length(issues),
         issues: issues,
         page_info: Map.get(result, :page_info)
       }}
    else
      {:error, :no_token} ->
        {:error, "linear_not_connected"}

      {:error, :reauth_required} ->
        {:error, "linear_reauth_required"}

      {:error, message} when is_binary(message) ->
        {:error,
         ToolErrorCopy.safe_message(message, ToolErrorCopy.action_failed("Linear", "list issues"))}

      {:error, reason} ->
        {:error,
         ToolErrorCopy.safe_message(reason, ToolErrorCopy.action_failed("Linear", "list issues"))}
    end
  end

  defp build_opts(args) do
    [
      first: resolve_limit(args),
      after: ActionHelpers.optional_string(args, "after"),
      team_id: ActionHelpers.optional_string(args, "team_id"),
      assignee_id: ActionHelpers.optional_string(args, "assignee_id"),
      state_id: ActionHelpers.optional_string(args, "state_id"),
      project_id: ActionHelpers.optional_string(args, "project_id"),
      label_id: ActionHelpers.optional_string(args, "label_id"),
      query: ActionHelpers.optional_string(args, "query"),
      created_after: ActionHelpers.optional_string(args, "created_after"),
      updated_after: ActionHelpers.optional_string(args, "updated_after")
    ]
  end

  defp resolve_limit(args) do
    args
    |> ActionHelpers.optional_integer("limit")
    |> normalize_limit()
  end

  defp normalize_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)
  defp normalize_limit(_value), do: @default_limit
end
