defmodule Maraithon.TelegramAssistant.Client.LLMJson do
  @moduledoc """
  JSON-contract model client for the Telegram assistant loop.
  """

  @behaviour Maraithon.TelegramAssistant.Client

  alias Maraithon.AssistantHarness

  @impl true
  def next_step(payload) when is_map(payload) do
    AssistantHarness.next_step(payload)
  end

  def build_prompt(payload) when is_map(payload) do
    AssistantHarness.build_prompt(payload)
  end
end
