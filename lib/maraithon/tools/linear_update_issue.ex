defmodule Maraithon.Tools.LinearUpdateIssue do
  @moduledoc """
  Updates editable Linear issue fields.
  """

  alias Maraithon.Connectors.Linear
  alias Maraithon.OAuth
  alias Maraithon.Tools.ActionHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, issue_id} <- ActionHelpers.required_string(args, "issue_id"),
         {:ok, access_token} <- OAuth.get_valid_access_token(user_id, "linear"),
         {:ok, issue} <- Linear.update_issue(access_token, issue_id, build_opts(args)) do
      {:ok, %{source: "linear", issue_id: issue_id, issue: issue}}
    else
      {:error, :no_token} -> {:error, "linear_not_connected"}
      {:error, :reauth_required} -> {:error, "linear_reauth_required"}
      {:error, :empty_update} -> {:error, "linear_update_issue_requires_at_least_one_field"}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "linear_update_issue_failed: #{inspect(reason)}"}
    end
  end

  defp build_opts(args) do
    []
    |> ActionHelpers.maybe_put(:title, ActionHelpers.optional_string(args, "title"))
    |> ActionHelpers.maybe_put(:description, ActionHelpers.optional_string(args, "description"))
    |> ActionHelpers.maybe_put(:priority, ActionHelpers.optional_integer(args, "priority"))
    |> ActionHelpers.maybe_put(:assignee_id, ActionHelpers.optional_string(args, "assignee_id"))
    |> ActionHelpers.maybe_put(:project_id, ActionHelpers.optional_string(args, "project_id"))
    |> ActionHelpers.maybe_put(:state_id, ActionHelpers.optional_string(args, "state_id"))
    |> ActionHelpers.maybe_put(:due_date, ActionHelpers.optional_string(args, "due_date"))
    |> maybe_put_label_ids(ActionHelpers.optional_csv(args, "label_ids"))
  end

  defp maybe_put_label_ids(opts, []), do: opts
  defp maybe_put_label_ids(opts, label_ids), do: Keyword.put(opts, :label_ids, label_ids)
end
