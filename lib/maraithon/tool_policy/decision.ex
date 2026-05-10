defmodule Maraithon.ToolPolicy.Decision do
  @moduledoc """
  Stable decision returned by `Maraithon.ToolPolicy`.
  """

  @enforce_keys [:status, :reason_code, :message]
  defstruct status: :deny,
            reason_code: "policy_denied",
            message: "The tool call was denied by policy.",
            metadata: %{}

  @type status :: :allow | :deny | :needs_confirmation

  @type t :: %__MODULE__{
          status: status(),
          reason_code: String.t(),
          message: String.t(),
          metadata: map()
        }

  def new(status, reason_code, message, metadata \\ %{})
      when status in [:allow, :deny, :needs_confirmation] and is_binary(reason_code) and
             is_binary(message) and is_map(metadata) do
    %__MODULE__{
      status: status,
      reason_code: reason_code,
      message: message,
      metadata: stringify_keys(metadata)
    }
  end

  def to_map(%__MODULE__{} = decision) do
    %{
      "status" => Atom.to_string(decision.status),
      "reason_code" => decision.reason_code,
      "message" => decision.message,
      "metadata" => stringify_keys(decision.metadata)
    }
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
