defmodule MaraithonWeb.AgentActionCopy do
  @moduledoc false

  def success(:create, display_name), do: success_with_name(display_name, "created")
  def success(:update, display_name), do: success_with_name(display_name, "updated")

  def not_found do
    "That automation is no longer available. Refresh automations before continuing."
  end

  def error(:install, %Ecto.Changeset{} = changeset) do
    with_detail(
      "Could not install that automation.",
      validation_detail(changeset),
      "Review the launch details before installing."
    )
  end

  def error(:install, reason) when is_binary(reason) do
    with_detail(
      "Could not install that automation.",
      reason,
      "Review the launch details before installing."
    )
  end

  def error(:install, _reason) do
    "Could not install that automation. Refresh automations before installing."
  end

  def error(:create, %Ecto.Changeset{} = changeset) do
    with_detail(
      "Could not create that automation.",
      validation_detail(changeset),
      "Review the settings before saving."
    )
  end

  def error(:create, reason) when is_binary(reason) do
    with_detail("Could not create that automation.", reason, "Review the settings before saving.")
  end

  def error(:create, _reason) do
    "Could not create that automation. Review the settings before saving."
  end

  def error(:update, %Ecto.Changeset{} = changeset) do
    with_detail(
      "Could not update that automation.",
      validation_detail(changeset),
      "Review the settings before saving."
    )
  end

  def error(:update, reason) when is_binary(reason) do
    with_detail("Could not update that automation.", reason, "Review the settings before saving.")
  end

  def error(:update, _reason) do
    "Could not update that automation. Refresh automations before saving."
  end

  def error(:start, _reason) do
    "Could not start that automation. Refresh automations before starting it."
  end

  def error(:stop, _reason) do
    "Could not pause that automation. Refresh automations before pausing it."
  end

  def error(:delete, _reason) do
    "Could not remove that automation. Refresh automations before removing it."
  end

  def error(:send_message, _reason) do
    "Could not send that message. Start the automation before sending a message."
  end

  def marketplace_error(_reason) do
    "Some automation templates are unavailable because required connections need attention."
  end

  defp success_with_name(display_name, verb) do
    case visible_automation_name(display_name) do
      nil -> "Automation #{verb}"
      name -> "#{name} #{verb}"
    end
  end

  defp visible_automation_name(display_name) when is_binary(display_name) do
    display_name
    |> product_detail()
    |> String.trim()
    |> case do
      "" ->
        nil

      name ->
        if String.downcase(name) in ["automation", "unnamed_agent", "unnamed automation"] do
          nil
        else
          name
        end
    end
  end

  defp visible_automation_name(_display_name), do: nil

  defp with_detail(prefix, message, fallback) do
    cond do
      not is_binary(message) ->
        "#{prefix} #{fallback}"

      technical_message?(message) ->
        "#{prefix} #{fallback}"

      true ->
        case String.trim(message) do
          "" -> "#{prefix} #{fallback}"
          trimmed -> "#{prefix} #{trimmed |> product_detail() |> ensure_sentence()}"
        end
    end
  end

  defp product_detail(message) do
    message
    |> String.replace(~r/\bagents\b/i, "automations")
    |> String.replace(~r/\bagent\b/i, "automation")
    |> String.replace(~r/\bruntime\b/i, "workspace")
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
      Regex.match?(
        ~r/\b(?:authorization|bearer|token|secret|password|api[_ -]?key|access[_ -]?token|refresh[_ -]?token|client[_ -]?secret)\b/i,
        trimmed
      ) or
      Enum.any?(
        [
          "dbconnection",
          "postgrex",
          "ecto.",
          "phoenix.",
          "runtimeerror",
          "functionclauseerror",
          "internal_stacktrace",
          "http_status",
          "request_id",
          "stacktrace",
          "{:",
          "%{",
          "=>"
        ],
        &String.contains?(lower, &1)
      )
  end
end
