defmodule Maraithon.Delegations.EvaluationRunner do
  @moduledoc "Bounded Kent-to-Kent provider evals, driven by durable background job checkpoints."
  import Ecto.Query
  alias Maraithon.{Delegations, Repo, TelegramAssistant}
  alias Maraithon.AssistantChat.Execution
  alias Maraithon.Connectors.{Gmail, GoogleAccount}
  alias Maraithon.Delegations.{Evaluation, Gates, Ingress, Turn}
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobs, JobAuthority}
  alias Maraithon.TelegramAssistant.{ActionReconciliation, PreparedAction, Run}
  alias Maraithon.Todos.{Todo, Workflow}
  alias Maraithon.Tools.GmailApiHelpers

  @user "kent@runner.now"
  @counterparty "kent.fenwick@gmail.com"
  @job_type "delegation_eval"

  def start(scenario_id) when scenario_id == "information_reply" do
    with true <- Gates.sends_enabled?(@user, "gmail") and eval_only?(),
         %{} = scenario <-
           Enum.find(Evaluation.scenarios()["scenarios"], &(&1["id"] == scenario_id)),
         %{"accounts_ready" => true, "model_ready" => true} = report <- Evaluation.preflight() do
      accounts = Map.new(report["accounts"], &{&1["email"], &1["account_id"]})
      id = Ecto.UUID.generate()

      payload = %{
        "scenario" => scenario,
        "sender_account_id" => accounts[@counterparty],
        "owner_account_id" => accounts[@user],
        "deadline" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60, :minute)),
        "subject" => "[Maraithon eval] #{scenario_id} #{id}"
      }

      Repo.transaction(fn ->
        Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(@user)

        {:ok, job} =
          BackgroundJobs.enqueue(@job_type, %{
            user_id: @user,
            queue: "runtime_provider_account",
            partition_key: "delegation-eval:#{@user}",
            rate_limit_key: "google",
            max_attempts: 3,
            dedupe_key: "delegation-eval:#{id}",
            payload: payload
          })

        %{job_id: job.id, scenario: scenario_id, phase: "queued"}
      end)
    else
      _ -> {:error, :eval_preflight_required}
    end
  end

  def start(_), do: {:error, :unsupported_eval_scenario}

  def execute(%BackgroundJob{job_type: @job_type, user_id: @user} = job) do
    job = BackgroundJob.hydrate_payloads(job)

    Execution.with_authority(job, fn ->
      with {:ok, :ok} <- JobAuthority.transaction(job, fn -> :ok end),
           true <- eval_only?() and Gates.sends_enabled?(@user, "gmail"),
           {:ok, deadline, _} <- DateTime.from_iso8601(job.payload["deadline"]),
           :gt <- DateTime.compare(deadline, DateTime.utc_now()) do
        state = job.result || %{}

        case step(job, state) do
          {:wait, next} -> {:ok, next, {:reschedule_in, 30_000}}
          {:done, next} -> {:ok, next}
          {:error, reason} -> fail(job, state, reason)
        end
      else
        _ -> fail(job, job.result || %{}, :eval_stopped)
      end
    end)
  end

  def status do
    Repo.all(
      from j in BackgroundJob,
        where: j.job_type == @job_type and j.user_id == @user,
        order_by: [desc: j.inserted_at],
        limit: 5
    )
    |> Enum.map(fn row ->
      job = BackgroundJob.hydrate_payloads(row)
      %{job_id: job.id, status: job.status, result: job.result, error: job.last_error}
    end)
  end

  defp step(job, %{"delegation_id" => id} = state) do
    d = Delegations.get(@user, id)

    cond do
      is_nil(d) ->
        {:error, :eval_delegation_removed}

      d.state == "completed" ->
        verify(job, state, d)

      d.state in ~w(needs_user paused stopped expired waiting_capacity) ->
        {:error, {:conversation_held, d.state}}

      d.state == "waiting_reply" and state["reply_action_id"] == nil ->
        reply(job, state, d)

      true ->
        {:wait, Map.put(state, "phase", "waiting_for_agent")}
    end
  end

  defp step(job, state) do
    with {:ok, action} <-
           action(job, "initial", %{"body" => job.payload["scenario"]["initial_email"]}),
         {:ok, sent} <- deliver(action),
         {:ok, message} <- inbox_message(job, sent) do
      delegate(job, state, message)
    else
      :wait -> {:wait, Map.put(state, "phase", "waiting_for_initial_email")}
      error -> error
    end
  end

  defp delegate(job, state, message) do
    key = "delegation-eval:#{job.id}"

    with {:ok, todo} <-
           JobAuthority.transaction(job, fn ->
             Repo.get_by(Todo, user_id: @user, dedupe_key: key) ||
               Repo.insert!(%Todo{
                 user_id: @user,
                 owner_user_id: @user,
                 title: job.payload["subject"],
                 summary: job.payload["scenario"]["outcome"],
                 source: "gmail",
                 source_account_id: job.payload["owner_account_id"],
                 source_item_id: message.message_id,
                 next_action: "Ask Kent for the test project colour.",
                 dedupe_key: key
               })
           end),
         {:ok, d} <- ensure_delegation(job, todo) do
      {:wait,
       Map.merge(state, %{
         "phase" => "waiting_for_agent",
         "delegation_id" => d.id,
         "todo_id" => todo.id
       })}
    end
  end

  defp ensure_delegation(job, todo) do
    case Delegations.for_todo(@user, todo.id) do
      nil ->
        attrs = %{
          "actor" => "as_user",
          "kind" => job.payload["scenario"]["kind"],
          "outcome" => job.payload["scenario"]["outcome"],
          "expected_revision" => Workflow.current(todo)["revision"],
          "request_id" => "eval:#{job.id}:delegate"
        }

        with {:ok, scope} <- Delegations.preview(@user, todo.id, attrs),
             do:
               Delegations.delegate(
                 @user,
                 todo.id,
                 Map.put(attrs, "scope_hash", scope["scope_hash"])
               )

      d ->
        {:ok, d}
    end
  end

  defp reply(job, state, d) do
    with {:ok, initial} <-
           action(job, "initial", %{"body" => job.payload["scenario"]["initial_email"]}),
         initial = PreparedAction.hydrate_payload(initial),
         thread = initial.payload["_maraithon_execution_result"]["thread_id"],
         {:ok, token} <- GoogleAccount.access_token(@user, job.payload["sender_account_id"]),
         {:ok, messages} <- Gmail.fetch_thread_content(token, thread, access_token: true),
         parent when not is_nil(parent) <-
           Enum.find(Enum.reverse(messages), fn m ->
             String.contains?(String.downcase(m.from || ""), @user) and "DRAFT" not in m.labels
           end),
         {:ok, action} <-
           action(job, "reply", %{
             "body" => hd(job.payload["scenario"]["counterparty_replies"]),
             "thread_id" => thread,
             "reply_to_message_id" => parent.message_id
           }),
         {:ok, sent} <- deliver(action),
         {:ok, message} <- inbox_message(job, sent),
         {:ok, :ok} <-
           JobAuthority.transaction(job, fn ->
             Ingress.gmail!(@user, d.connected_account_id, message)
           end) do
      Maraithon.Delegations.Outbox.publish_pending(@user)

      {:wait,
       Map.merge(state, %{
         "phase" => "waiting_for_completion",
         "reply_action_id" => action.id,
         "reply_message_id" => message.message_id
       })}
    else
      nil -> {:wait, state}
      :wait -> {:wait, state}
      error -> error
    end
  end

  defp action(job, key, content) do
    id = deterministic_id(job.id, key)

    JobAuthority.transaction(job, fn ->
      Repo.get(PreparedAction, id) |> PreparedAction.hydrate_payload() ||
        create_action!(job, id, content)
    end)
  end

  defp create_action!(job, id, content) do
    run_id = deterministic_id(job.id, "run")
    chat = "delegation-eval:#{job.id}"

    unless Repo.get(Run, run_id) do
      %Run{id: run_id}
      |> Run.changeset(%{
        user_id: @user,
        chat_id: chat,
        surface: "telegram",
        trigger_type: "inbound_message",
        status: "completed",
        model_provider: "none",
        model_name: "fixture",
        prompt_snapshot: %{"eval_job_id" => job.id},
        result_summary: %{},
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()
    end

    payload =
      Map.merge(content, %{
        "user_id" => @user,
        "account_id" => job.payload["sender_account_id"],
        "from" => @counterparty,
        "to" => @user,
        "cc" => "",
        "subject" => job.payload["subject"]
      })

    %PreparedAction{id: id}
    |> PreparedAction.changeset(%{
      user_id: @user,
      run_id: run_id,
      chat_id: chat,
      surface: "telegram",
      action_type: "gmail_send",
      target_type: "email",
      payload: payload,
      preview_text: "Kent's authorised controlled conversation eval.",
      expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
    })
    |> Repo.insert!()
  end

  defp deliver(action) do
    case TelegramAssistant.confirm_and_execute(action, durable: false) do
      {:ok, sent, _} -> {:ok, sent}
      {:ok, sent, _, :already_executed} -> {:ok, sent}
      {:error, _, _, :manual_reconciliation} -> :wait
      {:error, _, :prepared_action_execution_in_progress} -> :wait
      _ -> {:error, :eval_send_failed}
    end
  end

  defp inbox_message(job, sent) do
    account = Repo.get!(Maraithon.Accounts.ConnectedAccount, job.payload["owner_account_id"])
    query = "in:anywhere rfc822msgid:#{ActionReconciliation.message_id(sent)}"

    with {:ok, ids} <-
           GmailApiHelpers.list_message_ids(
             %{"user_id" => @user, "provider" => account.provider, "exact_account" => true},
             query,
             2
           ),
         [id] <- ids,
         {:ok, token} <- GoogleAccount.access_token(@user, account.id),
         {:ok, message} <- Gmail.fetch_message_content(token, id, access_token: true) do
      {:ok, message}
    else
      [] -> :wait
      [_ | _] -> {:error, :ambiguous_eval_message}
      error -> error
    end
  end

  defp verify(_job, state, d) do
    todo = Repo.get!(Todo, d.todo_id)
    turns = Repo.all(from t in Turn, where: t.delegation_id == ^d.id)
    evidence_ids = Enum.map(d.data["evidence"] || [], & &1["id"])

    passed =
      todo.status == "done" and state["reply_message_id"] in evidence_ids and
        String.contains?(
          String.downcase(get_in(d.data, ["ledger", "latest_outcome"]) || ""),
          "indigo"
        ) and
        d.lifetime_sends in 1..2 and d.lifetime_micro_usd <= 100_000

    {:done,
     Map.merge(state, %{
       "phase" => if(passed, do: "passed", else: "failed"),
       "model_calls" => Enum.sum(Enum.map(turns, & &1.model_calls)),
       "turns" => length(turns),
       "cost_micro_usd" => d.lifetime_micro_usd,
       "agent_messages" => d.lifetime_sends,
       "todo_state" => Workflow.current(todo)["state"],
       "completion_cites_reply" => state["reply_message_id"] in evidence_ids
     })}
  end

  defp fail(_job, state, reason) do
    if id = state["delegation_id"] do
      if d = Delegations.get(@user, id) do
        if d.state not in ~w(completed stopped expired) do
          Delegations.stop(@user, id, %{
            "request_id" => "eval-stop:#{id}",
            "expected_revision" => d.revision
          })
        end
      end
    end

    {:ok,
     Map.merge(state, %{"phase" => "failed", "reason" => Maraithon.Redaction.error_class(reason)})}
  end

  defp deterministic_id(job_id, key) do
    <<id::binary-size(16), _::binary>> = :crypto.hash(:sha256, "#{job_id}:#{key}")
    Ecto.UUID.load!(id)
  end

  defp eval_only?, do: Application.get_env(:maraithon, :delegation_eval_only, false) == true
end
