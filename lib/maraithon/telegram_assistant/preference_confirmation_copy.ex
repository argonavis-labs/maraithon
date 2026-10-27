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

    consequence = consequence_text(rules, labels)

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

  defp consequence_text(rules, labels) do
    kinds =
      rules
      |> Enum.map(&rule_value(&1, "kind"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    plural? = length(labels) != 1

    cond do
      "quiet_hours" in kinds ->
        "Telegram interruptions will respect #{object_pronoun(plural?)} before anything is sent."

      "routing_preference" in kinds ->
        "Future alerts and summaries will use #{object_pronoun(plural?)} when choosing where work should land."

      "action_preference" in kinds or "style_preference" in kinds ->
        "Future drafts and replies will use #{object_pronoun(plural?)} before anything is prepared."

      "content_filter" in kinds ->
        "Future triage will use #{object_pronoun(plural?)} to keep low-value work out of view."

      "urgency_boost" in kinds ->
        "Future triage will use #{object_pronoun(plural?)} to raise matching work sooner."

      true ->
        "Future triage will use #{object_pronoun(plural?)} when deciding what reaches you."
    end
  end

  defp object_pronoun(true), do: "these preferences"
  defp object_pronoun(false), do: "this preference"

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
            "kind" -> :kind
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
