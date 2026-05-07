defmodule Maraithon.Tools.LinearGetIssue do
  @moduledoc """
  Fetches a Linear issue by UUID or issue identifier.
  """

  alias Maraithon.Connectors.Linear
  alias Maraithon.OAuth
  alias Maraithon.Tools.ActionHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, issue_id} <- ActionHelpers.required_string(args, "issue_id"),
         {:ok, access_token} <- OAuth.get_valid_access_token(user_id, "linear"),
         {:ok, issue} <- Linear.get_issue(access_token, issue_id) do
      {:ok, %{source: "linear", issue_id: issue_id, issue: issue}}
    else
      {:error, :no_token} -> {:error, "linear_not_connected"}
      {:error, :reauth_required} -> {:error, "linear_reauth_required"}
      {:error, :not_found} -> {:error, "linear_issue_not_found"}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "linear_get_issue_failed: #{inspect(reason)}"}
    end
  end
end
