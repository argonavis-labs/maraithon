defmodule MaraithonWeb.MobileParams do
  @moduledoc false

  def sanitize(params, allowed_keys) when is_map(params) and is_list(allowed_keys) do
    allowed = MapSet.new(allowed_keys)

    Enum.reduce(params, %{}, fn {key, value}, acc ->
      string_key = to_string(key)

      if MapSet.member?(allowed, string_key) do
        Map.put(acc, string_key, value)
      else
        acc
      end
    end)
  end

  def sanitize(_params, _allowed_keys), do: %{}
end
