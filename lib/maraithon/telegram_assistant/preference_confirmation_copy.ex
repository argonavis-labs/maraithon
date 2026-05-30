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
        "Maraithon will apply it when ranking future work."
      else
        "Maraithon will apply them when ranking future work."
      end

    "#{subject} #{consequence}"
  end

  def local_only_text do
    "Got it. This stays in the conversation and will not be saved as a standing preference."
  end

  def no_pending_text do
    "There is no pending preference to approve or dismiss."
  end

  def failed_text do
    "Could not turn that into a clear standing preference yet. Send /prefer with the rule you want remembered."
  end

  def text(rules, opts \\ []) do
    format = Keyword.get(opts, :format, :plain)
    rules = rules |> List.wrap() |> Enum.filter(&is_map/1)

    heading =
      case length(rules) do
        1 -> "Remember this for future triage?"
        _ -> "Remember these for future triage?"
      end

    body =
      rules
      |> Enum.take(3)
      |> Enum.map(&format_rule(&1, format))
      |> Enum.join("\n")

    [heading, "", body, more_line(length(rules)), "", reply_instruction(format, length(rules))]
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

  defp reply_instruction(:html, count) do
    object = if count == 1, do: "it", else: "them"

    "Reply <code>yes</code> to remember #{object}, or <code>no</code> to keep this in the conversation only."
  end

  defp reply_instruction(_format, count) do
    object = if count == 1, do: "it", else: "them"
    "Reply `yes` to remember #{object}, or `no` to keep this in the conversation only."
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
