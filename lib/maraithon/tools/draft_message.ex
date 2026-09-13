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
      with {:ok, result} <- Drafts.create(user_id, args) do
        result =
          result
          |> Map.put(:draft_card, Maraithon.AssistantChat.EmailDraft.card(result, args))
          |> Map.update!(:warnings, &Enum.map(&1, fn warning -> public_status(warning) end))
          |> update_in([:voice_profile, :refreshed], &public_status/1)

        {:ok, result}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, ActionHelpers.safe_error(reason)}
    end
  end

  # Atom/tuple diagnostics are not JSON values. Returning them causes the
  # bounded result guard to discard the entire draft before the model/UI see it.
  defp public_status({:gmail_draft_save_failed, _}), do: "gmail_draft_save_failed"
  defp public_status({:llm_draft_failed, _}), do: "llm_draft_failed"
  defp public_status({:refreshed, _}), do: "refreshed"
  defp public_status({:refresh_failed, _}), do: "refresh_failed"
  defp public_status(value) when is_atom(value), do: Atom.to_string(value)
  defp public_status(_), do: "draft_check_needs_attention"
end
