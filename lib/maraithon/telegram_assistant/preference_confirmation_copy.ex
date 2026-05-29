defmodule Maraithon.TelegramAssistant.PreferenceConfirmationCopy do
  @moduledoc false

  def saved_text(rules) do
    rules = rules |> List.wrap() |> Enum.filter(&is_map/1)
    labels = Enum.map(rules, &rule_label/1) |> Enum.reject(&(&1 == ""))

    subject =
      case labels do
        [] -> "Preference saved."
        [label] -> "Preference saved: #{label}."
        many -> "Preferences saved: #{Enum.take(many, 3) |> Enum.join("; ")}#{more_suffix(many)}."
      end

    consequence =
      if length(labels) == 1 do
        "Future triage will apply it automatically."
      else
        "Future triage will apply them automatically."
      end

    "#{subject} #{consequence}"
  end

  def local_only_text do
    "Kept as local feedback. No saved preference rule added."
  end

  def no_pending_text do
    "No pending preference to reject."
  end

  def failed_text do
    "Could not turn that into a saved preference yet. Try /prefer with a broader rule."
  end

  def text(rules, opts \\ []) do
    format = Keyword.get(opts, :format, :plain)
    rules = rules |> List.wrap() |> Enum.filter(&is_map/1)

    heading =
      case length(rules) do
        1 -> "Save this preference?"
        _ -> "Save these preferences?"
      end

    body =
      rules
      |> Enum.take(3)
      |> Enum.map(&format_rule(&1, format))
      |> Enum.join("\n")

    [heading, "", body, more_line(length(rules)), "", reply_instruction(format)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp format_rule(rule, format) do
    label = rule_label(rule)
    instruction = rule_value(rule, "instruction") || label

    rendered =
      if String.downcase(label) == String.downcase(instruction) do
        render_text(label, format)
      else
        "#{render_text(label, format)}: #{render_text(instruction, format)}"
      end

    "- #{rendered}"
  end

  defp more_line(count) when count > 3 do
    remaining = count - 3
    "#{remaining} more preference#{plural(remaining)} will be saved with this approval."
  end

  defp more_line(_count), do: nil

  defp more_suffix(items) when length(items) > 3 do
    " and #{length(items) - 3} more"
  end

  defp more_suffix(_items), do: ""

  defp reply_instruction(:html) do
    "Reply <code>yes</code> to save, or <code>no</code> to keep this local only."
  end

  defp reply_instruction(_format) do
    "Reply `yes` to save, or `no` to keep this local only."
  end

  defp render_text(value, :html), do: value |> to_string() |> escape_html()
  defp render_text(value, _format), do: to_string(value)

  defp rule_label(rule) do
    rule_value(rule, "label") || rule_value(rule, "instruction") || "Preference update"
  end

  defp escape_html(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp rule_value(rule, key) do
    case Map.get(rule, key) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        atom_key =
          case key do
            "label" -> :label
            "instruction" -> :instruction
          end

        case Map.get(rule, atom_key) do
          value when is_binary(value) and value != "" -> value
          _ -> nil
        end
    end
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
