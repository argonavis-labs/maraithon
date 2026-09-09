defmodule MaraithonWeb.RunnerConversationComponents do
  @moduledoc "Runner presentation for Maraithon's existing public conversation projection."
  use MaraithonWeb, :html

  attr :message, :map, required: true

  def turn(assigns) do
    message =
      assigns.message
      |> Map.take([:id, :role, :body, :sent_at])
      |> Map.put(:work_summary, public_work(assigns.message.work_summary))

    assigns = assign(assigns, :payload, Jason.encode!(%{message: message}))

    ~H"""
    <div id={"runner-turn-#{@message.id}"} phx-update="ignore" data-runner-turn
      data-turn={@payload} class="runner-components runner-conversation-turn">
      <p class="whitespace-pre-wrap text-sm/6"><%= @message.body %></p>
    </div>
    """
  end

  attr :run, :map, required: true

  def run(assigns) do
    run =
      assigns.run
      |> Map.take([:id, :status, :started_at])
      |> Map.put(:work_summary, public_work(assigns.run.work_summary))

    assigns = assign(assigns, :payload, Jason.encode!(%{run: run}))

    ~H"""
    <div id={"runner-run-#{@run.id}"} phx-update="ignore" data-runner-turn
      data-turn={@payload} class="runner-components runner-conversation-turn">
      <p role="status" class="text-sm/6 text-zinc-500">Working on your task…</p>
    </div>
    """
  end

  # Only display fields from WorkSummary cross the React boundary. Keep raw
  # audit payloads and internal model deliberation out of the transcript.
  defp public_work(nil), do: nil
  defp public_work(summary), do: Map.take(summary, ~w(headline status summary preview tool_calls))
end
