defmodule Maraithon.Tools.GmailDrafts do
  @moduledoc """
  Lists, gets, creates, updates, sends, and deletes Gmail drafts.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.GmailApiHelpers

  def execute(args) when is_map(args) do
    action = args |> ActionHelpers.optional_string("action") |> normalize_action("list")

    case action do
      "list" -> list_drafts(args)
      "get" -> get_draft(args)
      "create" -> create_or_update_draft(args, :post)
      "update" -> create_or_update_draft(args, :put)
      "send" -> send_draft(args)
      "delete" -> delete_draft(args)
      _ -> {:error, "unsupported_gmail_drafts_action"}
    end
  end

  defp list_drafts(args) do
    max_results = resolve_limit(args, 20, 100)
    path = "/users/me/drafts?#{URI.encode_query(%{maxResults: max_results})}"

    case GmailApiHelpers.request(args, :get, path) do
      {:ok, %{"drafts" => drafts} = response} when is_list(drafts) ->
        {:ok,
         %{
           source: "gmail",
           count: length(drafts),
           drafts: drafts,
           next_page_token: response["nextPageToken"]
         }}

      {:ok, response} ->
        {:ok, %{source: "gmail", count: 0, drafts: [], response: response}}

      {:error, reason} ->
        GmailApiHelpers.normalize_error(reason)
    end
  end

  defp get_draft(args) do
    with {:ok, draft_id} <- ActionHelpers.required_string(args, "draft_id") do
      path = "/users/me/drafts/#{URI.encode(draft_id)}?format=full"

      case GmailApiHelpers.request(args, :get, path) do
        {:ok, draft} -> {:ok, %{source: "gmail", draft_id: draft_id, draft: draft}}
        {:error, reason} -> GmailApiHelpers.normalize_error(reason)
      end
    end
  end

  defp create_or_update_draft(args, method) do
    with {:ok, body} <- draft_body(args),
         {:ok, path} <- draft_path(args, method) do
      case GmailApiHelpers.request(args, method, path, body) do
        {:ok, draft} -> {:ok, %{source: "gmail", draft: draft}}
        {:error, reason} -> GmailApiHelpers.normalize_error(reason)
      end
    end
  end

  defp draft_path(_args, :post), do: {:ok, "/users/me/drafts"}

  defp draft_path(args, :put) do
    with {:ok, draft_id} <- ActionHelpers.required_string(args, "draft_id") do
      {:ok, "/users/me/drafts/#{URI.encode(draft_id)}"}
    end
  end

  defp send_draft(args) do
    with {:ok, draft_id} <- ActionHelpers.required_string(args, "draft_id") do
      case GmailApiHelpers.request(args, :post, "/users/me/drafts/send", %{id: draft_id}) do
        {:ok, message} -> {:ok, %{source: "gmail", draft_id: draft_id, message: message}}
        {:error, reason} -> GmailApiHelpers.normalize_error(reason)
      end
    end
  end

  defp delete_draft(args) do
    with {:ok, draft_id} <- ActionHelpers.required_string(args, "draft_id") do
      case GmailApiHelpers.request(args, :delete, "/users/me/drafts/#{URI.encode(draft_id)}") do
        {:ok, response} -> {:ok, %{source: "gmail", draft_id: draft_id, response: response}}
        {:error, reason} -> GmailApiHelpers.normalize_error(reason)
      end
    end
  end

  defp draft_body(args) do
    with {:ok, to} <- ActionHelpers.required_string(args, "to"),
         {:ok, subject} <- ActionHelpers.required_string(args, "subject"),
         {:ok, text_body} <- ActionHelpers.required_string(args, "body") do
      raw =
        GmailApiHelpers.raw_message(to, subject, text_body,
          cc: ActionHelpers.optional_string(args, "cc"),
          bcc: ActionHelpers.optional_string(args, "bcc"),
          in_reply_to: ActionHelpers.optional_string(args, "in_reply_to"),
          references: ActionHelpers.optional_string(args, "references")
        )

      message =
        %{raw: raw, threadId: ActionHelpers.optional_string(args, "thread_id")}
        |> GmailApiHelpers.compact()

      {:ok, %{message: message}}
    end
  end

  defp resolve_limit(args, default, max_value) do
    case ActionHelpers.optional_integer(args, "max_results") do
      value when is_integer(value) -> value |> max(1) |> min(max_value)
      _ -> default
    end
  end

  defp normalize_action(nil, default), do: default
  defp normalize_action(action, _default), do: String.downcase(action)
end
