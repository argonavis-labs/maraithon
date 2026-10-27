defmodule Maraithon.Tools.GmailBatchModify do
  @moduledoc """
  Applies batch label/read/archive changes to Gmail messages by ids or query.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.GmailApiHelpers

  @default_query_limit 50
  @max_query_limit 500

  def execute(args) when is_map(args) do
    with {:ok, message_ids} <- resolve_message_ids(args),
         {:ok, body} <- build_body(args, message_ids) do
      case GmailApiHelpers.request(args, :post, "/users/me/messages/batchModify", body) do
        {:ok, response} ->
          {:ok,
           %{
             source: "gmail",
             count: length(message_ids),
             message_ids: message_ids,
             response: response
           }}

        {:error, reason} ->
          GmailApiHelpers.normalize_error(reason)
      end
    end
  end

  defp resolve_message_ids(args) do
    case ActionHelpers.optional_csv(args, "message_ids") do
      [] ->
        with {:ok, query} <- ActionHelpers.required_string(args, "query") do
          GmailApiHelpers.list_message_ids(args, query, resolve_limit(args))
        end

      ids ->
        {:ok, ids}
    end
  end

  defp build_body(args, message_ids) do
    {add_label_ids, remove_label_ids} =
      args
      |> ActionHelpers.optional_csv("actions")
      |> Enum.reduce(
        {ActionHelpers.optional_csv(args, "add_label_ids"),
         ActionHelpers.optional_csv(args, "remove_label_ids")},
        fn
          "archive", {add, remove} -> {add, ["INBOX" | remove]}
          "unarchive", {add, remove} -> {["INBOX" | add], remove}
          "mark_read", {add, remove} -> {add, ["UNREAD" | remove]}
          "mark_unread", {add, remove} -> {["UNREAD" | add], remove}
          _action, acc -> acc
        end
      )

    body =
      %{
        ids: message_ids,
        addLabelIds: Enum.uniq(add_label_ids),
        removeLabelIds: Enum.uniq(remove_label_ids)
      }
      |> GmailApiHelpers.compact()

    cond do
      message_ids == [] ->
        {:error, "gmail_batch_modify_requires_messages"}

      Map.get(body, :addLabelIds, []) == [] and Map.get(body, :removeLabelIds, []) == [] ->
        {:error, "gmail_batch_modify_requires_actions"}

      true ->
        {:ok, body}
    end
  end

  defp resolve_limit(args) do
    case ActionHelpers.optional_integer(args, "max_results") do
      value when is_integer(value) -> value |> max(1) |> min(@max_query_limit)
      _ -> @default_query_limit
    end
  end
end
