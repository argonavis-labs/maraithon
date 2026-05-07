defmodule Maraithon.Tools.GmailLabels do
  @moduledoc """
  Lists, creates, updates, and deletes Gmail labels.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.GmailApiHelpers

  def execute(args) when is_map(args) do
    action = args |> ActionHelpers.optional_string("action") |> normalize_action("list")

    case action do
      "list" -> list_labels(args)
      "create" -> create_label(args)
      "update" -> update_label(args)
      "delete" -> delete_label(args)
      _ -> {:error, "unsupported_gmail_labels_action"}
    end
  end

  defp list_labels(args) do
    case GmailApiHelpers.request(args, :get, "/users/me/labels") do
      {:ok, %{"labels" => labels}} ->
        {:ok, %{source: "gmail", count: length(labels), labels: labels}}

      {:ok, response} ->
        {:ok, %{source: "gmail", labels: [], response: response}}

      {:error, reason} ->
        GmailApiHelpers.normalize_error(reason)
    end
  end

  defp create_label(args) do
    with {:ok, name} <- ActionHelpers.required_string(args, "name") do
      body =
        %{
          name: name,
          labelListVisibility: ActionHelpers.optional_string(args, "label_list_visibility"),
          messageListVisibility: ActionHelpers.optional_string(args, "message_list_visibility"),
          color: label_color(args)
        }
        |> GmailApiHelpers.compact()

      case GmailApiHelpers.request(args, :post, "/users/me/labels", body) do
        {:ok, label} -> {:ok, %{source: "gmail", label: label}}
        {:error, reason} -> GmailApiHelpers.normalize_error(reason)
      end
    end
  end

  defp update_label(args) do
    with {:ok, label_id} <- ActionHelpers.required_string(args, "label_id") do
      body =
        %{
          name: ActionHelpers.optional_string(args, "name"),
          labelListVisibility: ActionHelpers.optional_string(args, "label_list_visibility"),
          messageListVisibility: ActionHelpers.optional_string(args, "message_list_visibility"),
          color: label_color(args)
        }
        |> GmailApiHelpers.compact()

      case GmailApiHelpers.request(args, :patch, "/users/me/labels/#{URI.encode(label_id)}", body) do
        {:ok, label} -> {:ok, %{source: "gmail", label_id: label_id, label: label}}
        {:error, reason} -> GmailApiHelpers.normalize_error(reason)
      end
    end
  end

  defp delete_label(args) do
    with {:ok, label_id} <- ActionHelpers.required_string(args, "label_id") do
      case GmailApiHelpers.request(args, :delete, "/users/me/labels/#{URI.encode(label_id)}") do
        {:ok, response} -> {:ok, %{source: "gmail", label_id: label_id, response: response}}
        {:error, reason} -> GmailApiHelpers.normalize_error(reason)
      end
    end
  end

  defp label_color(args) do
    text_color = ActionHelpers.optional_string(args, "text_color")
    background_color = ActionHelpers.optional_string(args, "background_color")

    case {text_color, background_color} do
      {nil, nil} -> nil
      _ -> GmailApiHelpers.compact(%{textColor: text_color, backgroundColor: background_color})
    end
  end

  defp normalize_action(nil, default), do: default
  defp normalize_action(action, _default), do: String.downcase(action)
end
