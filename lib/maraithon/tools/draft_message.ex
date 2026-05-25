defmodule Maraithon.Tools.DraftMessage do
  @moduledoc """
  Generates approval-ready Gmail and Slack drafts in the user's channel voice.
  """

  alias Maraithon.Drafts
  alias Maraithon.Tools.ActionHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, _channel} <- ActionHelpers.required_string(args, "channel"),
         {:ok, _purpose} <- ActionHelpers.required_string(args, "purpose") do
      Drafts.create(user_id, args)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
