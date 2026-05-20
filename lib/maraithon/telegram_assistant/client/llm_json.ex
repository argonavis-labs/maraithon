defmodule Maraithon.TelegramAssistant.Client.LLMJson do
  @moduledoc """
  JSON-contract model client for the Telegram assistant loop.
  """

  @behaviour Maraithon.TelegramAssistant.Client

  alias Maraithon.AssistantHarness
  alias Maraithon.LLM
  alias Maraithon.LLM.JsonFieldStreamer
  alias Maraithon.TelegramAssistant.LivenessSession

  @allowed_llm_opt_keys [
    :chat_model,
    :reasoning_effort,
    :max_tokens,
    :temperature,
    :model_fallbacks,
    :model_failover_max_attempts,
    :llm_complete
  ]

  @impl true
  def next_step(payload) when is_map(payload) do
    {stream_target, payload} = Map.pop(payload, :_stream_target)
    {llm_opts, payload} = Map.pop(payload, :_llm_opts, [])
    llm_opts = normalize_llm_opts(llm_opts)

    if is_binary(stream_target) and stream_target != "" do
      AssistantHarness.next_step(
        payload,
        Keyword.put(llm_opts, :llm_complete, streaming_llm_complete(stream_target))
      )
    else
      AssistantHarness.next_step(payload, llm_opts)
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

  defp normalize_llm_opts(opts) when is_list(opts) do
    Enum.reduce(opts, [], fn
      {key, value}, acc when key in @allowed_llm_opt_keys ->
        Keyword.put(acc, key, value)

      _other, acc ->
        acc
    end)
  end

  defp normalize_llm_opts(_opts), do: []
end
