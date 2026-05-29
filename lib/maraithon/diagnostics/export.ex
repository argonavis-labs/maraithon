defmodule Maraithon.Diagnostics.Export do
  @moduledoc """
  Redacted diagnostic bundle export for local and production incident triage.

  The export is intentionally evidence-oriented and prompt-safe. It includes
  summaries, statuses, counters, and redacted metadata while excluding raw
  prompts, raw webhook bodies, raw tool outputs, and credentials by default.
  """

  import Ecto.Query

  alias Maraithon.Accounts.{ConnectedAccount, User}
  alias Maraithon.ActionLedger
  alias Maraithon.ActionLedger.Action
  alias Maraithon.Admin
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentIsolation.{Binding, Session}
  alias Maraithon.Agents.{Agent, AgentRun}
  alias Maraithon.Health
  alias Maraithon.LogBuffer
  alias Maraithon.MobileNodes
  alias Maraithon.MobileNodes.{Device, Pairing}
  alias Maraithon.Normalization
  alias Maraithon.Redaction
  alias Maraithon.Repo
  alias Maraithon.Runtime.{BackgroundJob, ScheduledJob}
  alias Maraithon.RunErrorCopy
  alias Maraithon.ScheduledTasks
  alias Maraithon.ScheduledTasks.Run, as: ScheduledTaskRun
  alias Maraithon.ScheduledTasks.Task
  alias Maraithon.SecretRef
  alias Maraithon.SourceFreshness
  alias Maraithon.Spend
  alias Maraithon.TelegramAssistant.{PushReceipt, Run}
  alias Maraithon.TrustMetrics

  @default_limit 100
  @max_limit 500
  @runtime_config_keys ~w(
    llm_provider_name
    llm_model
    llm_model_selector
    llm_routing_model
    llm_chat_model
    openai_model
    openrouter_model
    anthropic_model
    heartbeat_interval_ms
    checkpoint_interval_ms
    effect_poll_interval_ms
    effect_claim_timeout_ms
    effect_batch_size
    scheduler_poll_interval_ms
    scheduler_dispatch_timeout_ms
    briefing_cron_interval_ms
    insight_notify_interval_ms
    proactive_check_in_interval_ms
    proactive_check_in_batch_size
    oauth_refresh_interval_ms
    oauth_refresh_lookahead_seconds
    oauth_refresh_batch_size
    tool_allowed_paths
    llm_timeout_ms
    tool_timeout_ms
    max_effect_attempts
  )a

  def run(opts \\ []) when is_list(opts) do
    try do
      generated_at = DateTime.utc_now() |> DateTime.truncate(:second)
      user_id = normalize_blank(Keyword.get(opts, :user_id))
      limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()
      output_dir = opts |> Keyword.get(:output_dir) |> output_dir(generated_at)

      File.mkdir_p!(output_dir)

      sections = build_sections(generated_at, user_id, limit)

      files =
        sections
        |> Enum.map(fn {filename, payload} ->
          path = Path.join(output_dir, filename)
          File.write!(path, Jason.encode!(normalize_for_json(payload), pretty: true))
          filename
        end)

      {:ok,
       %{
         output_dir: output_dir,
         generated_at: DateTime.to_iso8601(generated_at),
         files: files
       }}
    rescue
      exception ->
        {:error, exception}
    catch
      kind, reason ->
        {:error, {kind, reason}}
    end
  end

  defp build_sections(generated_at, user_id, limit) do
    scope = if user_id, do: %{"user_id" => user_id}, else: %{"user_id" => "all"}

    %{
      "manifest.json" => %{
        generated_at: generated_at,
        app: "maraithon",
        version: app_version(),
        scope: scope,
        limit: limit,
        privacy: %{
          default_view: "redacted",
          excludes: [
            "raw prompts",
            "raw webhook bodies",
            "raw tool outputs",
            "tokens",
            "authorization headers",
            "cookies"
          ]
        }
      },
      "summary.json" => summary(user_id),
      "health.json" => Health.check(),
      "runtime_shape.json" => runtime_shape(),
      "secret_refs.json" => SecretRef.runtime_snapshot(),
      "queue_metrics.json" => Admin.queue_metrics(user_id: user_id),
      "source_freshness.json" => source_freshness(user_id),
      "connector_status.json" => connector_status(user_id, limit),
      "action_ledger.json" => action_ledger(user_id, limit),
      "assistant_runs.json" => assistant_runs(user_id, limit),
      "agent_runs.json" => agent_runs(user_id, limit),
      "scheduled_tasks.json" => scheduled_tasks(user_id, limit),
      "agent_isolation.json" => agent_isolation(user_id, limit),
      "mobile_nodes.json" => mobile_nodes(user_id, limit),
      "jobs.json" => jobs(user_id, limit),
      "logs.json" => redacted(LogBuffer.recent(limit)),
      "push_receipts.json" => push_receipts(user_id, limit),
      "spend_summary.json" => Spend.get_total_spend(user_id: user_id),
      "trust_metrics.json" => TrustMetrics.baseline(user_id: user_id),
      "redaction_manifest.json" => ActionLedger.redaction_manifest()
    }
  end

  defp summary(user_id) do
    %{
      users: count_users(user_id),
      agents: count_user_scoped(Agent, user_id),
      connected_accounts: count_user_scoped(ConnectedAccount, user_id),
      action_ledger_actions: count_user_scoped(Action, user_id),
      telegram_assistant_runs: count_user_scoped(Run, user_id),
      user_scheduled_tasks: count_user_scoped(Task, user_id),
      user_scheduled_task_runs: count_user_scoped(ScheduledTaskRun, user_id),
      agent_isolation_bindings: count_user_scoped(Binding, user_id),
      agent_isolation_sessions: count_user_scoped(Session, user_id),
      mobile_node_pairings: count_user_scoped(Pairing, user_id),
      mobile_node_devices: count_user_scoped(Device, user_id),
      background_jobs: count_user_scoped(BackgroundJob, user_id),
      scheduled_jobs: count_scheduled_jobs(user_id),
      proactive_push_receipts: count_user_scoped(PushReceipt, user_id)
    }
  end

  defp source_freshness(nil) do
    User
    |> select([user], user.id)
    |> Repo.all()
    |> Enum.flat_map(&SourceFreshness.for_user/1)
    |> redacted()
  end

  defp source_freshness(user_id), do: user_id |> SourceFreshness.for_user() |> redacted()

  defp connector_status(user_id, limit) do
    ConnectedAccount
    |> maybe_filter_user(user_id)
    |> order_by([account], desc: account.updated_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn account ->
      %{
        id: account.id,
        user_id: account.user_id,
        provider: account.provider,
        external_account_id: account.external_account_id,
        status: account.status,
        scopes: account.scopes || [],
        metadata: account.metadata || %{},
        connected_at: account.connected_at,
        last_refreshed_at: account.last_refreshed_at,
        inserted_at: account.inserted_at,
        updated_at: account.updated_at
      }
    end)
    |> redacted()
  end

  defp action_ledger(user_id, limit) do
    Action
    |> maybe_filter_user(user_id)
    |> order_by([action], desc: action.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&ActionLedger.redacted_action/1)
  end

  defp assistant_runs(user_id, limit) do
    Run
    |> maybe_filter_user(user_id)
    |> order_by([run], desc: run.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn run ->
      %{
        id: run.id,
        user_id: run.user_id,
        conversation_id: run.conversation_id,
        chat_id: run.chat_id,
        trigger_type: run.trigger_type,
        status: run.status,
        model_provider: run.model_provider,
        model_name: run.model_name,
        prompt_snapshot_keys: map_keys(run.prompt_snapshot),
        result_summary: run.result_summary || %{},
        started_at: run.started_at,
        finished_at: run.finished_at,
        error: RunErrorCopy.assistant_response(run.error),
        inserted_at: run.inserted_at,
        updated_at: run.updated_at
      }
    end)
    |> redacted()
  end

  defp agent_runs(user_id, limit) do
    AgentRun
    |> maybe_filter_user(user_id)
    |> order_by([run], desc: run.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn run ->
      %{
        id: run.id,
        user_id: run.user_id,
        agent_id: run.agent_id,
        project_id: run.project_id,
        behavior: run.behavior,
        status: run.status,
        trigger_type: run.trigger_type,
        trigger_keys: map_keys(run.trigger),
        resolved_model: run.resolved_model,
        intelligence: run.intelligence,
        finish_reason: run.finish_reason,
        generation_mode: run.generation_mode,
        active_skills: run.active_skills || [],
        tool_allowlist: run.tool_allowlist || [],
        budget_snapshot: run.budget_snapshot || %{},
        error: RunErrorCopy.agent_run(run.error),
        metadata: run.metadata || %{},
        started_at: run.started_at,
        completed_at: run.completed_at,
        inserted_at: run.inserted_at,
        updated_at: run.updated_at
      }
    end)
    |> redacted()
  end

  defp scheduled_tasks(user_id, limit) do
    tasks =
      Task
      |> maybe_filter_user(user_id)
      |> order_by([task], desc: task.updated_at, desc: task.inserted_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(fn task ->
        task
        |> ScheduledTasks.serialize_task()
        |> Map.update!(:command, &map_keys/1)
        |> Map.update!(:failure_destination, &map_keys/1)
      end)

    runs =
      ScheduledTaskRun
      |> maybe_filter_user(user_id)
      |> order_by([run], desc: run.scheduled_for)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(fn run ->
        run
        |> ScheduledTasks.serialize_run()
        |> Map.update!(:result, &map_keys/1)
      end)

    %{tasks: tasks, runs: runs}
    |> redacted()
  end

  defp agent_isolation(user_id, limit) do
    bindings =
      Binding
      |> maybe_filter_user(user_id)
      |> order_by([binding], desc: binding.updated_at, desc: binding.inserted_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&AgentIsolation.serialize_binding/1)

    sessions =
      Session
      |> maybe_filter_user(user_id)
      |> order_by([session], desc: session.updated_at, desc: session.inserted_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&AgentIsolation.serialize_session/1)

    %{bindings: bindings, sessions: sessions}
    |> redacted()
  end

  defp mobile_nodes(user_id, limit) do
    pairings =
      Pairing
      |> maybe_filter_user(user_id)
      |> order_by([pairing], desc: pairing.inserted_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&MobileNodes.redacted_pairing/1)

    devices =
      Device
      |> maybe_filter_user(user_id)
      |> order_by([device], desc: device.updated_at, desc: device.inserted_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&MobileNodes.redacted_device/1)

    %{
      command_contract: MobileNodes.command_contract(),
      pairings: pairings,
      devices: devices
    }
    |> redacted()
  end

  defp jobs(user_id, limit) do
    %{
      background_jobs: background_jobs(user_id, limit),
      scheduled_jobs: scheduled_jobs(user_id, limit)
    }
  end

  defp background_jobs(user_id, limit) do
    BackgroundJob
    |> maybe_filter_user(user_id)
    |> order_by([job], desc: job.updated_at, desc: job.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn job ->
      %{
        id: job.id,
        user_id: job.user_id,
        queue: job.queue,
        job_type: job.job_type,
        status: job.status,
        dedupe_key: job.dedupe_key,
        attempts: job.attempts,
        max_attempts: job.max_attempts,
        scheduled_at: job.scheduled_at,
        claimed_at: job.claimed_at,
        completed_at: job.completed_at,
        failed_at: job.failed_at,
        cancelled_at: job.cancelled_at,
        payload_keys: map_keys(job.payload),
        result_keys: map_keys(job.result),
        last_error: background_job_error(job.last_error),
        inserted_at: job.inserted_at,
        updated_at: job.updated_at
      }
    end)
    |> redacted()
  end

  defp scheduled_jobs(nil, limit) do
    ScheduledJob
    |> order_by([job], desc: job.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&serialize_scheduled_job/1)
    |> redacted()
  end

  defp scheduled_jobs(user_id, limit) do
    ScheduledJob
    |> join(:inner, [job], agent in Agent, on: agent.id == job.agent_id)
    |> where([_job, agent], agent.user_id == ^user_id)
    |> order_by([job, _agent], desc: job.inserted_at)
    |> limit(^limit)
    |> select([job, _agent], job)
    |> Repo.all()
    |> Enum.map(&serialize_scheduled_job/1)
    |> redacted()
  end

  defp serialize_scheduled_job(job) do
    %{
      id: job.id,
      agent_id: job.agent_id,
      job_type: job.job_type,
      status: job.status,
      attempts: job.attempts,
      fire_at: job.fire_at,
      claimed_at: job.claimed_at,
      dispatched_at: job.dispatched_at,
      delivered_at: job.delivered_at,
      payload_keys: map_keys(job.payload),
      inserted_at: job.inserted_at
    }
  end

  defp background_job_error(nil), do: nil
  defp background_job_error(""), do: nil

  defp background_job_error(error) do
    RunErrorCopy.runtime_failure(%{source: "background_job", details: error})
  end

  defp push_receipts(user_id, limit) do
    PushReceipt
    |> maybe_filter_user(user_id)
    |> order_by([receipt], desc: receipt.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn receipt ->
      %{
        id: receipt.id,
        user_id: receipt.user_id,
        conversation_turn_id: receipt.conversation_turn_id,
        dedupe_key: receipt.dedupe_key,
        origin_type: receipt.origin_type,
        origin_id: receipt.origin_id,
        decision: receipt.decision,
        inserted_at: receipt.inserted_at
      }
    end)
    |> redacted()
  end

  defp runtime_shape do
    runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

    runtime =
      runtime_config
      |> Keyword.take(@runtime_config_keys)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), safe_runtime_value(value)} end)

    assistant =
      :maraithon
      |> Application.get_env(:telegram_assistant, [])
      |> Keyword.take([
        :telegram_full_chat_enabled,
        :telegram_unified_push_enabled,
        :telegram_proactive_checkins_enabled
      ])
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    %{runtime: runtime, telegram_assistant: assistant}
  end

  defp safe_runtime_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_runtime_value(value), do: value

  defp count_users(nil), do: Repo.aggregate(User, :count)

  defp count_users(user_id) do
    User
    |> where([user], user.id == ^user_id)
    |> Repo.aggregate(:count)
  end

  defp count_user_scoped(schema, nil), do: Repo.aggregate(schema, :count)

  defp count_user_scoped(schema, user_id) do
    schema
    |> where([row], row.user_id == ^user_id)
    |> Repo.aggregate(:count)
  end

  defp count_scheduled_jobs(nil), do: Repo.aggregate(ScheduledJob, :count)

  defp count_scheduled_jobs(user_id) do
    ScheduledJob
    |> join(:inner, [job], agent in Agent, on: agent.id == job.agent_id)
    |> where([_job, agent], agent.user_id == ^user_id)
    |> Repo.aggregate(:count)
  end

  defp maybe_filter_user(query, nil), do: query
  defp maybe_filter_user(query, ""), do: query

  defp maybe_filter_user(query, user_id) when is_binary(user_id) do
    where(query, [row], row.user_id == ^user_id)
  end

  defp output_dir(nil, generated_at) do
    timestamp =
      generated_at
      |> DateTime.to_iso8601()
      |> String.replace(~r/[^0-9A-Za-z]/, "")

    Path.join(["tmp", "maraithon_diagnostics", timestamp])
  end

  defp output_dir("", generated_at), do: output_dir(nil, generated_at)
  defp output_dir(path, _generated_at) when is_binary(path), do: path

  defp map_keys(value) when is_map(value),
    do: value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

  defp map_keys(_value), do: []

  defp redacted(value), do: Redaction.redact(value)

  defp normalize_for_json(value) do
    value
    |> redacted()
    |> Normalization.normalize_json_value()
  end

  defp normalize_limit(limit), do: Normalization.clamp_limit(limit, @default_limit, @max_limit)

  defp normalize_blank(value), do: Normalization.blank_to_nil(value)

  defp app_version do
    case Application.spec(:maraithon, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end
end
