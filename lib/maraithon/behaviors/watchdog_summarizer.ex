defmodule Maraithon.Behaviors.WatchdogSummarizer do
  @moduledoc """
  Lightweight monitor that periodically writes activity notes and checks URLs.

  Config:
    - check_url: URL to periodically check (optional)
    - wakeup_interval_ms: How often to wake up (default: 30 minutes)
  """

  @behaviour Maraithon.Behaviors.Behavior

  @default_wakeup_interval_ms :timer.minutes(30)

  require Logger

  @impl true
  def init(config) do
    %{
      check_url: config["check_url"],
      summaries: [],
      iteration: 0,
      wakeup_interval_ms: config["wakeup_interval_ms"] || @default_wakeup_interval_ms
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    state = %{state | iteration: state.iteration + 1}

    Logger.info("WatchdogSummarizer wakeup", iteration: state.iteration)

    cond do
      # Every 6th wakeup (3 hours), do a URL check if configured
      state.check_url && rem(state.iteration, 6) == 0 ->
        Logger.info("Checking URL", url: state.check_url)
        {:effect, {:tool_call, "http_get", %{"url" => state.check_url}}, state}

      # Every 2nd wakeup (1 hour), ask for a summary
      rem(state.iteration, 2) == 0 ->
        prompt = build_summary_prompt(context)

        params = %{
          "messages" => [
            %{"role" => "user", "content" => prompt}
          ],
          "max_tokens" => 500,
          "temperature" => 0.5
        }

        {:effect, {:llm_call, params}, state}

      # Otherwise, just note we're alive
      true ->
        note =
          "Monitoring check #{state.iteration}: no new issues at #{timestamp()}."

        {:emit, {:note_appended, note}, state}
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, _context) do
    summary = response.content
    state = %{state | summaries: [summary | state.summaries] |> Enum.take(100)}

    {:emit, {:note_appended, "Monitoring update: #{truncate_summary(summary)}"}, state}
  end

  def handle_effect_result({:tool_call, result}, state, _context) do
    status = result["status"] || "unknown"
    note = "Endpoint check: #{http_status_label(status)} at #{timestamp()}."

    {:emit, {:note_appended, note}, state}
  end

  @impl true
  def next_wakeup(state) do
    {:relative, state.wakeup_interval_ms}
  end

  # Private functions

  defp build_summary_prompt(context) do
    """
    You write concise operator-facing monitoring updates.

    Current time: #{context.timestamp |> DateTime.to_iso8601()}
    Monitoring check: activity and endpoint status from the current run.

    Write one short paragraph for a busy operator:
    - Start with the concrete state: quiet, changed, degraded, or needs attention.
    - Include only observations the available context supports.
    - Do not mention agent ids, tool budgets, runtime internals, or model/provider details.
    - Do not invent system health beyond the observed activity.

    Keep it under 100 words.
    """
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp truncate_summary(summary) when is_binary(summary) do
    summary
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> "No notable changes."
      text -> truncate(text, 220)
    end
  end

  defp truncate_summary(_summary), do: "No notable changes."

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    text
    |> String.slice(0, max)
    |> String.replace(~r/\s+\S*$/, "")
    |> Kernel.<>("...")
  end

  defp http_status_label(status) when is_integer(status), do: "HTTP #{status}"

  defp http_status_label(status) when is_binary(status) do
    value = String.trim(status)

    if value == "" or value == "unknown" do
      "no HTTP status returned"
    else
      "HTTP #{value}"
    end
  end

  defp http_status_label(_status), do: "no HTTP status returned"
end
