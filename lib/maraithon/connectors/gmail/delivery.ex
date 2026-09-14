defmodule Maraithon.Connectors.Gmail.Delivery do
  @moduledoc "Separates unsent Gmail drafts from evidence of delivered requests and promises."

  @reference_keys ~w(id message_id thread_id from to cc subject labels label_ids labelIds)a

  def draft?(message) when is_map(message) do
    labels =
      Enum.flat_map([:labels, :label_ids, :labelIds], fn key ->
        List.wrap(Map.get(message, key) || Map.get(message, Atom.to_string(key)))
      end)

    "DRAFT" in labels
  end

  def draft?(_), do: false

  @doc "Keeps draft identity and delivery status, excluding its proposed wording from model evidence."
  def for_reasoning(%_{} = value), do: value

  def for_reasoning(value) when is_map(value) do
    if draft?(value) do
      value
      |> Map.take(@reference_keys ++ Enum.map(@reference_keys, &Atom.to_string/1))
      |> Map.put("delivery_status", "unsent_draft")
    else
      Map.new(value, fn {key, nested} -> {key, for_reasoning(nested)} end)
    end
  end

  def for_reasoning(value) when is_list(value), do: Enum.map(value, &for_reasoning/1)
  def for_reasoning(value), do: value
end
