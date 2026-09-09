defmodule Maraithon.AssistantChat.ThreadWorker do
  @moduledoc "Compatibility enqueue API backed by durable, owned background jobs."

  alias Maraithon.AssistantChat.Execution
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramConversations.Turn

  def enqueue(%{run_id: run_id, conversation_id: conversation_id, user_turn_id: turn_id}) do
    with %Run{conversation_id: ^conversation_id} = run <- Repo.get(Run, run_id),
         %Turn{conversation_id: ^conversation_id, role: "user"} = turn <- Repo.get(Turn, turn_id),
         ^run_id <- Turn.effective_assistant_run_id(turn),
         {:ok, _job} <- Execution.enqueue(run, turn) do
      :ok
    else
      _ -> {:error, :queued_request_not_found}
    end
  end
end
