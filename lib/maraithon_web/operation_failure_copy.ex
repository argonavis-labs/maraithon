defmodule MaraithonWeb.OperationFailureCopy do
  @moduledoc false

  def onboarding_preview(_reason) do
    "Could not load the setup preview. Refresh the dashboard and try again."
  end

  def fly_logs(_reason) do
    "Could not fetch platform logs right now. Refresh the logs and try again."
  end

  def admin(:diagnostics_export, _reason) do
    "Could not generate diagnostics export. Check the output path and try again."
  end

  def admin(:fly_logs, reason) do
    fly_logs(reason)
  end

  def admin(:gmail_recent, _reason) do
    "Could not fetch recent Gmail messages. Check the Google connection and try again."
  end

  def admin(:todo_dismiss, _reason) do
    "Could not dismiss this work item. Refresh the list and try again."
  end

  def admin(:reset_operator_state, _reason) do
    "Could not reset operator state. Refresh the admin console and try again."
  end

  def admin(:telegram_push, _reason) do
    "Could not send Telegram message. Check the Telegram connection and try again."
  end

  def admin(:chief_of_staff_ensure, _reason) do
    "Could not refresh Chief of Staff setup. Refresh the page and try again."
  end

  def admin(:disconnect_connection, _reason) do
    "Could not disconnect that app. Refresh connections and try again."
  end

  def admin(_action, _reason) do
    "That admin action could not be completed. Refresh the admin console and try again."
  end

  def disconnect(label, _reason) do
    label = clean_label(label, "that app")

    "Could not disconnect #{label}. Refresh the page and try again."
  end

  def project(:create, %Ecto.Changeset{} = changeset) do
    with_detail(
      "Could not create that project.",
      validation_detail(changeset),
      "Review the highlighted fields before saving again."
    )
  end

  def project(:create, _reason) do
    "Could not create that project. Review the highlighted fields before saving again."
  end

  def project(:memory, %Ecto.Changeset{} = changeset) do
    with_detail(
      "Could not save that project memory.",
      validation_detail(changeset),
      "Review the highlighted fields before saving again."
    )
  end

  def project(:memory, _reason) do
    "Could not save that project memory. Review the highlighted fields before saving again."
  end

  def project(:recommendation_decision, _reason) do
    "Could not save that recommendation decision. Refresh the dashboard and try again."
  end

  def project(:repo_access, _reason) do
    "Could not grant repo access. Check the repository name and try again."
  end

  def project(:implementation_run, _reason) do
    "Could not start that delivery work. Refresh the dashboard and try again."
  end

  def insight(:acknowledge, _reason) do
    "Could not acknowledge that insight. Refresh the dashboard and try again."
  end

  def insight(:dismiss, _reason) do
    "Could not dismiss that insight. Refresh the dashboard and try again."
  end

  def insight(:snooze, _reason) do
    "Could not snooze that insight. Refresh the dashboard and try again."
  end

  def insight_delivery(_reason) do
    "Delivery failed. Check the connected channel and try again."
  end

  def relationship(:apply, _reason) do
    "Could not apply that relationship suggestion. Refresh insights and try again."
  end

  def memory(:archive, _reason) do
    "Could not archive that memory. Refresh memory and try again."
  end

  def briefing_schedule(:morning, :invalid_local_hour) do
    "Choose a valid morning briefing time."
  end

  def briefing_schedule(:morning, :invalid_local_minute) do
    "Choose a valid morning briefing minute."
  end

  def briefing_schedule(:morning, :invalid_timezone_offset_hours) do
    "Choose a valid timezone for the morning briefing."
  end

  def briefing_schedule(:morning, :briefing_agent_not_found) do
    "Select an active Chief of Staff setup and try again."
  end

  def briefing_schedule(:morning, :no_briefing_agents) do
    "Install Chief of Staff before changing the morning briefing schedule."
  end

  def briefing_schedule(:morning, _reason) do
    "Could not save the morning briefing time. Refresh Chief of Staff and try again."
  end

  defp clean_label(label, fallback) when is_binary(label) do
    case String.trim(label) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp clean_label(_label, fallback), do: fallback

  defp with_detail(prefix, message, fallback) do
    cond do
      not is_binary(message) ->
        "#{prefix} #{fallback}"

      technical_message?(message) ->
        "#{prefix} #{fallback}"

      true ->
        case String.trim(message) do
          "" -> "#{prefix} #{fallback}"
          trimmed -> "#{prefix} #{ensure_sentence(trimmed)}"
        end
    end
  end

  defp validation_detail(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, errors} ->
      Enum.map(errors, fn error -> "#{field_label(field)} #{error}" end)
    end)
    |> Enum.take(2)
    |> Enum.join(". ")
  end

  defp field_label(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp ensure_sentence(message) do
    if String.ends_with?(message, [".", "!", "?"]) do
      message
    else
      message <> "."
    end
  end

  defp technical_message?(message) do
    trimmed = String.trim(message)
    lower = String.downcase(trimmed)

    trimmed == "" or
      Regex.match?(~r/^[a-z0-9_]+$/, trimmed) or
      Enum.any?(
        [
          "dbconnection",
          "postgrex",
          "ecto.",
          "phoenix.",
          "stacktrace",
          "{:",
          "%{",
          "=>",
          "token ",
          "token:"
        ],
        &String.contains?(lower, &1)
      )
  end
end
