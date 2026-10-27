defmodule Maraithon.Crm.RelationshipPresentation do
  @moduledoc false

  def health_level(value),
    do: band(value, [{80, "core"}, {60, "strong"}, {30, "developing"}], "new")

  def warmth_level(value),
    do: band(value, [{80, "very_warm"}, {55, "warm"}, {30, "familiar"}], "new")

  def health_label(value) do
    case health_level(value) do
      "core" -> "Core relationship"
      "strong" -> "Strong relationship"
      "developing" -> "Developing relationship"
      "new" -> "Needs context"
    end
  end

  def warmth_label(value) do
    case warmth_level(value) do
      "very_warm" -> "Very warm rapport"
      "warm" -> "Warm rapport"
      "familiar" -> "Familiar rapport"
      "new" -> "No rapport yet"
    end
  end

  defp band(value, bands, fallback) when is_integer(value) do
    bands
    |> Enum.find_value(fallback, fn {minimum, label} ->
      if value >= minimum, do: label
    end)
  end

  defp band(_value, _bands, fallback), do: fallback
end
