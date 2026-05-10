defmodule Maraithon.TelegramAssistant.Client.LLMJson do
  @moduledoc """
  JSON-contract model client for the Telegram assistant loop.
  """

  @behaviour Maraithon.TelegramAssistant.Client

  alias Maraithon.AssistantHarness
  alias Maraithon.LLM
  alias Maraithon.LLM.JsonFieldStreamer
  alias Maraithon.TelegramAssistant.LivenessSession

  @impl true
  def next_step(payload) when is_map(payload) do
    {stream_target, payload} = Map.pop(payload, :_stream_target)

    if is_binary(stream_target) and stream_target != "" do
      AssistantHarness.next_step(payload, llm_complete: streaming_llm_complete(stream_target))
    else
      AssistantHarness.next_step(payload)
    end
  end

  def build_prompt(payload) when is_map(payload) do
    AssistantHarness.build_prompt(payload)
  end

  defp streaming_llm_complete(run_id) do
    fn params ->
      streamer_table = :ets.new(:json_streamer, [:set, :public])
      :ets.insert(streamer_table, {:state, JsonFieldStreamer.new()})

      on_chunk = fn delta ->
        try do
          [{:state, current}] = :ets.lookup(streamer_table, :state)
          {emit, next_state} = JsonFieldStreamer.feed(current, delta)
          :ets.insert(streamer_table, {:state, next_state})

          if emit != "" do
            LivenessSession.stream_chunk(run_id, emit)
          end
        rescue
          _error -> :ok
        end
      end

      try do
        LLM.stream_complete(params, on_chunk)
      after
        LivenessSession.stream_done(run_id)
        :ets.delete(streamer_table)
      end
    end
  end
end
