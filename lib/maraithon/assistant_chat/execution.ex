defmodule Maraithon.AssistantChat.Execution do
  @moduledoc """
  Durable execution for web, Mac and iPhone conversations.

  The existing fair model lane supplies ownership, cancellation and bounded
  retries. Each job names the exact run and source turn. Recovery resumes a
  saved model/tool continuation or final delivery. Tools with an uncertain
  mutating outcome require reconciliation before they can run again.
  """

  import Ecto.Query

  alias Maraithon.{AssistantChat, Repo}
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobs}
  alias Maraithon.Runtime.Coordination.{Scope, TaskAssignment, TaskClaims}
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramConversations.{Conversation, Turn}

  @context_key {__MODULE__, :job}
  @job_type "assistant_chat_request"
  @active_assignments ~w(reserved running termination_requested termination_proven)

  @doc false
  def capture_authority, do: Process.get(@context_key)

  @doc false
  def retry_available? do
    case capture_authority() do
      %BackgroundJob{attempts: attempts, max_attempts: max_attempts} ->
        attempts + 1 < max_attempts

      _ ->
        false
    end
  end

  @doc false
  def with_authority(authority, fun) do
    previous = Process.put(@context_key, authority)

    try do
      fun.()
    after
      if previous, do: Process.put(@context_key, previous), else: Process.delete(@context_key)
    end
  end

  def enqueue(%Run{surface: "mobile"} = run, %Turn{role: "user"} = turn) do
    if run.conversation_id == turn.conversation_id and
         Turn.effective_assistant_run_id(turn) == run.id do
      BackgroundJobs.enqueue(@job_type, %{
        user_id: run.user_id,
        queue: "runtime_model_user",
        partition_key: "assistant-chat:#{run.conversation_id}",
        rate_limit_key: "model",
        dedupe_key: dedupe_key(run.id),
        max_attempts: 3,
        payload: %{
          "run_id" => run.id,
          "conversation_id" => run.conversation_id,
          "user_turn_id" => turn.id
        }
      })
    else
      {:error, :request_binding_mismatch}
    end
  end

  def enqueue(_, _), do: {:error, :request_binding_mismatch}

  def execute(%BackgroundJob{} = job) do
    job = BackgroundJob.hydrate_payloads(job)
    previous = Process.put(@context_key, job)

    try do
      execute_owned(job)
    after
      if previous, do: Process.put(@context_key, previous), else: Process.delete(@context_key)
    end
  end

  defp execute_owned(job) do
    case transaction(fn -> claim_request!(job) end) do
      {:ok, {:start, run, conversation, turn}} ->
        finish_request(AssistantChat.execute_request(run, conversation, turn), run)

      {:ok, {:resume, run, conversation, turn}} ->
        finish_request(AssistantChat.execute_request(run, conversation, turn, true), run)

      {:ok, :earlier_request_pending} ->
        {:ok, %{state: "waiting_for_earlier_message"}, {:reschedule_in, 1_000}}

      {:ok, {:terminal, run}} ->
        {:ok, %{run_id: run.id, state: run.status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_request!(job) do
    payload = job.payload || %{}
    run_id = payload["run_id"]
    conversation_id = payload["conversation_id"]
    turn_id = payload["user_turn_id"]

    with true <- valid_uuid?(run_id) and valid_uuid?(conversation_id) and valid_uuid?(turn_id),
         %Run{} = run <-
           Repo.one(
             from r in Run,
               where:
                 r.id == ^run_id and r.user_id == ^job.user_id and
                   r.conversation_id == ^conversation_id and r.surface == "mobile",
               lock: "FOR UPDATE"
           ),
         %Turn{role: "user"} = turn <-
           Repo.get_by(Turn, id: turn_id, conversation_id: conversation_id),
         ^run_id <- Turn.effective_assistant_run_id(turn),
         %Conversation{} = conversation <-
           Repo.get_by(Conversation, id: conversation_id, user_id: job.user_id, surface: "mobile") do
      run = Run.hydrate_payloads(run)
      turn = Turn.hydrate(turn)
      conversation = Conversation.hydrate(conversation)

      cond do
        run.status == "queued" and earlier_request_pending?(run) ->
          :earlier_request_pending

        run.status == "queued" ->
          run =
            run
            |> Run.changeset(%{status: "running", started_at: DateTime.utc_now()})
            |> Repo.update!()

          {:start, Run.hydrate_payloads(run), conversation, turn}

        resumable_delivery?(run, turn) ->
          {:resume, run, conversation, turn}

        run.status == "running" and
            Maraithon.TelegramAssistant.Continuation.present?(run) ->
          {:resume, run, conversation, turn}

        run.status == "running" and no_model_or_tool_entry?(run) ->
          {:start, run, conversation, turn}

        run.status == "running" ->
          # The scheduler only grants this retry after the previous task's
          # termination is proven. A missing checkpoint is still ambiguous.
          run =
            run
            |> Run.changeset(%{
              status: "degraded",
              finished_at: DateTime.utc_now(),
              error: "interrupted_run_requires_review"
            })
            |> Repo.update!()

          {:terminal, run}

        true ->
          {:terminal, run}
      end
    else
      _ -> Repo.rollback(:request_binding_mismatch)
    end
  end

  defp no_model_or_tool_entry?(run) do
    (run.result_summary || %{})["execution_preparing"] == true and
      not Repo.exists?(
        from s in Maraithon.TelegramAssistant.Step,
          where: s.run_id == ^run.id and s.step_type != "context_fetch"
      )
  end

  defp earlier_request_pending?(run) do
    Repo.exists?(
      from r in Run,
        where: r.conversation_id == ^run.conversation_id and r.surface == "mobile",
        where: r.status in ["queued", "running"],
        where:
          r.inserted_at < ^run.inserted_at or
            (r.inserted_at == ^run.inserted_at and r.id < ^run.id)
    )
  end

  defp resumable_delivery?(run, turn) do
    if run.status in ["running", "degraded", "failed"] do
      case TelegramAssistant.resumable_delivery_run(run.conversation_id, turn.id) do
        %Run{user_id: user_id, surface: "mobile", result_summary: summary}
        when user_id == run.user_id ->
          checkpoint = (summary || %{})["delivery_checkpoint"] || %{}

          checkpoint["kind"] in ["standard", "todo_digest"] and
            checkpoint["source_message_id"] == turn.id

        _ ->
          false
      end
    else
      false
    end
  end

  defp finish_request({:ok, {:delivery_resumed, delivered_run_id}}, run) do
    # Escalation may have created a child run. Drain its saved reply and settle
    # the accepted parent receipt as well, without executing either tool loop.
    if delivered_run_id != run.id do
      delivered = Repo.get!(Run, delivered_run_id)

      case TelegramAssistant.complete_run(run, %{
             status: delivered.status,
             result_summary: %{recovered_delivery: true, delivered_run_id: delivered_run_id}
           }) do
        {:ok, _} -> finish_request(:ok, run)
        error -> error
      end
    else
      finish_request(:ok, run)
    end
  end

  defp finish_request(result, run) when result == :ok or elem(result, 0) == :ok do
    current = Repo.get!(Run, run.id)
    Maraithon.AssistantChat.Progress.changed(run.user_id, run.conversation_id)

    if current.status in ["queued", "running"] do
      {:error, {:assistant_request_incomplete, run.id}}
    else
      {:ok, %{run_id: current.id, state: current.status}}
    end
  end

  defp finish_request(_result, run) do
    # A retry drains an existing delivery checkpoint or marks interrupted
    # execution for review. It never starts a second model/tool loop.
    {:error, {:assistant_request_incomplete, run.id}}
  end

  @doc false
  def write(fun) when is_function(fun, 0) do
    if Process.get(@context_key) do
      case transaction(fun) do
        {:ok, result} -> result
        error -> error
      end
    else
      fun.()
    end
  end

  @doc false
  def write_run(%Run{} = run, fun) when is_function(fun, 1) do
    case Process.get(@context_key) do
      %BackgroundJob{user_id: user_id, payload: payload} when user_id == run.user_id ->
        if payload["conversation_id"] == run.conversation_id do
          case transaction(fn ->
                 current = Repo.one!(from r in Run, where: r.id == ^run.id, lock: "FOR UPDATE")
                 fun.(Run.hydrate_payloads(current))
               end) do
            {:ok, result} -> result
            error -> error
          end
        else
          {:error, :request_binding_mismatch}
        end

      nil ->
        fun.(run)

      _ ->
        {:error, :request_binding_mismatch}
    end
  end

  defp transaction(fun) do
    Repo.transaction(fn ->
      job = Process.get(@context_key)
      fence_job!(job)
      _ = WriteFence.lock_user_writable!(job.user_id)
      fun.()
    end)
  end

  defp fence_job!(job) do
    if job.coordination_task_assignment_id do
      case Repo.get(TaskAssignment, job.coordination_task_assignment_id) do
        %TaskAssignment{work_kind: "background_job", work_id: id, claim_token: token} = assignment
        when id == job.id and token == job.claim_token ->
          TaskClaims.fence_running!(assignment)

        _ ->
          Repo.rollback(:task_authority_lost)
      end
    else
      if Scope.enabled?(), do: Repo.rollback(:task_authority_required)
    end

    owned =
      Repo.one(
        from j in BackgroundJob,
          where: j.id == ^job.id and j.claim_token == ^job.claim_token and j.status == "running",
          select: j.id,
          lock: "FOR SHARE"
      )

    if is_nil(owned), do: Repo.rollback(:claim_lost)
  end

  @doc false
  def job_active?(run_id) do
    key = dedupe_key(run_id)

    Repo.exists?(
      from j in BackgroundJob,
        left_join: a in TaskAssignment,
        on: a.work_kind == "background_job" and a.work_id == j.id,
        where: j.job_type == ^@job_type and j.dedupe_key == ^key,
        where: j.status in ["pending", "running"] or a.state in ^@active_assignments
    )
  end

  defp valid_uuid?(id), do: match?({:ok, _}, Ecto.UUID.cast(id))
  defp dedupe_key(run_id), do: "assistant-chat:#{run_id}"
end
