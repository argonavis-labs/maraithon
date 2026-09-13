defmodule Maraithon.AssistantChat.PreparationOutcome do
  @moduledoc "A failed preparation cannot become a ready-for-approval claim in the final response."
  alias Maraithon.TelegramAssistant.ActionFailureCopy

  @preparation_tools ~w(prepare_external_action calendar_create_event draft_imessage draft_message)

  def reconcile(response, history) when is_map(response) and is_list(history) do
    latest = Enum.find(Enum.reverse(history), &(value(&1, "tool") in @preparation_tools))

    case value(latest, "error") do
      nil ->
        reconcile_unsaved_email(response, latest)

      "" ->
        response

      error ->
        detail = ActionFailureCopy.tool_error(error)

        response
        |> Map.put("message_class", "system_notice")
        |> Map.put("assistant_message", "That action isn't ready for approval. " <> detail)
        |> Map.put("summary", "Action preparation failed: " <> detail)
    end
  end

  def reconcile(response, _), do: response

  defp reconcile_unsaved_email(response, latest) do
    result = value(latest, "result") || %{}
    card = value(result, "draft_card") || %{}

    if card["provider"] == "gmail" and value(result, "provider_draft") == nil and
         value(result, "warnings") not in [nil, []] do
      response
      |> Map.put(
        "assistant_message",
        "The email draft is ready to edit here, but Gmail could not save it. Review the connection step on the draft card, then prepare it again. Nothing was sent."
      )
      |> Map.put("summary", "Prepared an editable email; saving it in Gmail needs attention.")
    else
      response
    end
  end

  defp value(map, "tool") when is_map(map), do: Map.get(map, "tool") || Map.get(map, :tool)
  defp value(map, "error") when is_map(map), do: Map.get(map, "error") || Map.get(map, :error)
  defp value(map, "result") when is_map(map), do: Map.get(map, "result") || Map.get(map, :result)

  defp value(map, "draft_card") when is_map(map),
    do: Map.get(map, "draft_card") || Map.get(map, :draft_card)

  defp value(map, "provider_draft") when is_map(map),
    do: Map.get(map, "provider_draft") || Map.get(map, :provider_draft)

  defp value(map, "warnings") when is_map(map),
    do: Map.get(map, "warnings") || Map.get(map, :warnings)

  defp value(_, _), do: nil
end
