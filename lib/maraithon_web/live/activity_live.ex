defmodule MaraithonWeb.ActivityLive do
  @moduledoc """
  User-scoped status timeline for durable OTP agent runs and todo creation.
  """

  use MaraithonWeb, :live_view

  @source_error_codes ~w(source_discovery_child_failed source_closure_child_failed)

  alias Maraithon.Agents
  alias Maraithon.RunErrorCopy
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Todos
  alias MaraithonWeb.LocalTime

  @refresh_interval 5_000
  @run_limit 50
  @source_run_page_size 200
  @todo_event_limit 50

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Activity",
        current_path: "/activity",
        timeline: [],
        run_count: 0,
        source_run_count: 0,
        source_run_limit: @source_run_page_size,
        todo_count: 0,
        refreshed_at: nil,
        timezone_info: LocalTime.default_timezone_info()
      )

    if connected?(socket), do: :timer.send_interval(@refresh_interval, self(), :refresh)

    {:ok, refresh(socket)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("refresh_now", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("load_more_source_runs", _params, socket) do
    socket =
      update(socket, :source_run_limit, fn limit -> limit + @source_run_page_size end)

    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    user_id = socket.assigns.current_user.id
    timezone_info = LocalTime.timezone_info_for_user(user_id)
    runs = Agents.list_recent_runs_for_user(user_id, limit: @run_limit)

    source_runs =
      BackgroundJobs.list_latest_source_account_runs_for_user(user_id,
        limit: socket.assigns.source_run_limit
      )

    todo_events =
      Todos.list_activity_for_user(user_id,
        event_type: "created",
        limit: @todo_event_limit
      )

    linked_todo_ids =
      user_id
      |> Todos.list_by_ids(Enum.map(todo_events, & &1.todo_id))
      |> Map.new(&{&1.id, true})

    timeline =
      Enum.map(runs, &run_item/1) ++
        Enum.map(source_runs, &source_run_item/1) ++
        Enum.map(todo_events, &todo_item(&1, linked_todo_ids))

    timeline =
      Enum.sort_by(
        timeline,
        fn item -> {DateTime.to_unix(item.occurred_at, :microsecond), item.sort_id} end,
        :desc
      )

    assign(socket,
      timeline: timeline,
      run_count: length(runs),
      source_run_count: length(source_runs),
      todo_count: length(todo_events),
      refreshed_at: DateTime.utc_now(),
      timezone_info: timezone_info
    )
  end

  defp run_item(run) do
    steps = Enum.map(run.steps, &step_item/1)

    %{
      kind: :run,
      id: "run-#{run.id}",
      sort_id: run.id,
      reference: String.slice(run.id, 0, 8),
      agent_name: agent_name(run),
      status: run.status,
      trigger: trigger_label(run.trigger_type),
      summary: run_summary(run.status, run.step_count),
      safe_error: RunErrorCopy.agent_run(run.error),
      duration: duration_label(run.started_at, run.completed_at),
      llm_calls: normalize_count(run.llm_call_count),
      tool_calls: normalize_count(run.tool_call_count),
      steps: steps,
      last_action: steps |> List.last() |> then(&(&1 && &1.label)),
      occurred_at: run.started_at
    }
  end

  defp source_run_item(job) do
    account = Map.get(job, :account)
    provider = source_provider_label(account)
    role = source_role(job.job_type)
    stage = source_stage(job.job_type)
    fanout = source_fanout(job.dedupe_key, job.result)
    matrix = source_matrix(job.dedupe_key, job.result)
    occurred_at = job.claimed_at || job.scheduled_at || job.inserted_at
    finished_at = job.completed_at || job.failed_at || job.cancelled_at

    %{
      kind: :source_run,
      id: "source-run-#{job.id}",
      sort_id: job.id,
      reference: String.slice(job.id, 0, 8),
      agent_name: "#{provider} #{String.downcase(role)}",
      account: source_account_label(account, provider),
      status: job.status,
      summary: source_run_summary(job.job_type, job.status, fanout),
      safe_error: source_run_error(job.status, job.last_error),
      last_error_code: source_error_code(job.last_error),
      duration: duration_label(occurred_at, finished_at),
      lane: source_lane(job.queue),
      role: role,
      stage: stage,
      ai_calls: source_ai_calls(job.job_type, job.queue, job.status, job.result),
      failed_attempts: normalize_count(job.attempts),
      source_items: source_result_count(job.result, "source_items"),
      decision_count: source_result_count(job.result, "decision_count"),
      fanout: fanout,
      matrix: matrix,
      occurred_at: occurred_at
    }
  end

  defp todo_item(event, linked_todo_ids) do
    %{
      kind: :todo,
      id: "todo-event-#{event.id}",
      sort_id: event.id,
      todo_id: event.todo_id,
      linked?: is_binary(event.todo_id) and Map.has_key?(linked_todo_ids, event.todo_id),
      title: presence(event.todo_title, "Untitled todo"),
      source: source_label(event.todo_source),
      actor: actor_label(event.actor_type),
      occurred_at: event.occurred_at
    }
  end

  defp step_item(step) do
    %{
      id: step.id,
      label: step_label(step),
      status: step.status
    }
  end

  defp step_label(%{tool_name: "upsert_todos"}), do: "Created or updated todos"
  defp step_label(%{tool_name: "list_todos"}), do: "Reviewed existing todos"
  defp step_label(%{tool_name: "get_open_loops"}), do: "Reviewed open work"
  defp step_label(%{tool_name: "review_connected_context"}), do: "Reviewed connected context"
  defp step_label(%{tool_name: "gmail_search"}), do: "Searched Gmail"
  defp step_label(%{tool_name: "gmail_list_recent"}), do: "Reviewed recent email"
  defp step_label(%{tool_name: "slack_search_messages"}), do: "Searched Slack"
  defp step_label(%{tool_name: "slack_list_messages"}), do: "Reviewed Slack messages"
  defp step_label(%{tool_name: "messages_search"}), do: "Searched messages"
  defp step_label(%{tool_name: "calendar_search"}), do: "Searched the calendar"
  defp step_label(%{tool_name: "google_calendar_list_events"}), do: "Reviewed calendar events"
  defp step_label(%{tool_name: "notes_search"}), do: "Searched notes"
  defp step_label(%{tool_name: "reminders_search"}), do: "Searched reminders"
  defp step_label(%{tool_name: "files_search"}), do: "Searched files"
  defp step_label(%{tool_name: "recall_memory"}), do: "Recalled saved context"
  defp step_label(%{tool_name: "write_memory"}), do: "Saved context"
  defp step_label(%{tool_name: "draft_message"}), do: "Drafted a message"
  defp step_label(%{tool_name: "slack_post_message"}), do: "Sent a Slack message"
  defp step_label(%{tool_name: "gmail_send_message"}), do: "Sent an email"
  defp step_label(%{step_type: "llm_call"}), do: "Reviewed context and planned next actions"
  defp step_label(%{effect_type: "llm_call"}), do: "Reviewed context and planned next actions"
  defp step_label(%{step_type: "tool_call"}), do: "Ran an action"
  defp step_label(_step), do: "Processed the run"

  defp agent_name(%{package_name: name}) when is_binary(name) and name != "", do: name
  defp agent_name(%{behavior: "ai_chief_of_staff"}), do: "Chief of Staff"
  defp agent_name(%{behavior: "founder_followthrough_agent"}), do: "Follow-through assistant"
  defp agent_name(%{behavior: "inbox_calendar_advisor"}), do: "Inbox and calendar assistant"
  defp agent_name(%{behavior: "slack_followthrough_agent"}), do: "Slack follow-through assistant"
  defp agent_name(%{behavior: "prompt_agent"}), do: "Custom assistant"
  defp agent_name(_run), do: "Maraithon agent"

  defp source_provider_label(%{provider: provider}) when is_binary(provider) do
    cond do
      provider == "google" or String.starts_with?(provider, "google:") -> "Gmail"
      provider == "slack" or String.starts_with?(provider, "slack:") -> "Slack"
      true -> "Connected source"
    end
  end

  defp source_provider_label(_account), do: "Connected source"

  defp source_account_label(%{metadata: metadata} = account, provider) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    [
      Map.get(metadata, "account_email"),
      Map.get(metadata, "email"),
      Map.get(metadata, "team_name"),
      Map.get(metadata, "workspace_name"),
      Map.get(account, :external_account_id),
      source_provider_suffix(Map.get(account, :provider))
    ]
    |> Enum.find_value(&normalized_label/1)
    |> presence(provider)
  end

  defp source_account_label(_account, provider), do: provider

  defp source_provider_suffix(provider) when is_binary(provider) do
    case String.split(provider, ":", parts: 2) do
      [_root, suffix] -> suffix
      _other -> nil
    end
  end

  defp source_provider_suffix(_provider), do: nil

  defp normalized_label(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      label -> label
    end
  end

  defp normalized_label(_value), do: nil

  defp source_role(job_type)
       when job_type in [
              "runtime_partition:source_account_discovery",
              "runtime_partition:source_account_discovery_reason",
              "runtime_partition:source_account_discovery_finalize"
            ],
       do: "Todo discovery"

  defp source_role(_job_type), do: "Todo completion"

  defp source_stage(job_type)
       when job_type in [
              "runtime_partition:source_account_discovery_reason",
              "runtime_partition:source_account_closure_reason"
            ],
       do: "AI review"

  defp source_stage(job_type)
       when job_type in [
              "runtime_partition:source_account_discovery_finalize",
              "runtime_partition:source_account_closure_finalize"
            ],
       do: "Coverage finalizer"

  defp source_stage(_job_type), do: "Source delta"

  defp source_lane("runtime_provider_account"), do: "Provider lane"
  defp source_lane("runtime_model_user"), do: "Model lane"
  defp source_lane(_queue), do: "Runtime lane"

  defp source_ai_calls(
         job_type,
         _queue,
         _status,
         _result
       )
       when job_type in [
              "runtime_partition:source_account_discovery_finalize",
              "runtime_partition:source_account_closure_finalize"
            ],
       do: "0"

  defp source_ai_calls(_job_type, "runtime_provider_account", _status, _result), do: "0"

  defp source_ai_calls(_job_type, "runtime_model_user", "completed", result),
    do: Integer.to_string(source_result_count(result, "model_calls"))

  defp source_ai_calls(_job_type, "runtime_model_user", _status, _result),
    do: "Pending · max 1"

  defp source_ai_calls(_job_type, _queue, _status, _result), do: "Bounded"

  defp source_run_summary(_job_type, "pending", fanout),
    do: fanout_summary("Waiting for its OTP lane", fanout)

  defp source_run_summary(_job_type, "running", fanout),
    do: fanout_summary("Checking this account now", fanout)

  defp source_run_summary("runtime_partition:source_account_discovery", "completed", _fanout),
    do: "Checked only messages after this account's discovery cursor"

  defp source_run_summary(
         "runtime_partition:source_account_discovery_reason",
         "completed",
         fanout
       ),
       do: fanout_summary("Reviewed new messages for todo decisions", fanout)

  defp source_run_summary(
         "runtime_partition:source_account_discovery_finalize",
         "completed",
         _fanout
       ),
       do: "Proved every acquired message received a todo decision"

  defp source_run_summary(
         "runtime_partition:source_account_closure_acquire",
         "completed",
         _fanout
       ),
       do: "Checked only later messages for completion evidence"

  defp source_run_summary(
         "runtime_partition:source_account_closure_reason",
         "completed",
         fanout
       ),
       do:
         fanout_summary("Compared a bounded later-message partition with this todo batch", fanout)

  defp source_run_summary(
         "runtime_partition:source_account_closure_finalize",
         "completed",
         _fanout
       ),
       do: "Proved every snapshotted open todo received a completion decision"

  defp source_run_summary(_job_type, "failed", _fanout),
    do: "This account worker did not complete"

  defp source_run_summary(_job_type, "cancelled", _fanout),
    do: "This account worker stopped safely"

  defp source_run_summary(_job_type, _status, _fanout), do: "Account worker status updated"

  defp source_fanout(dedupe_key, result) do
    index = source_result_count(result, "fanout_index")
    count = source_result_count(result, "fanout_count")

    cond do
      index > 0 and count > 0 ->
        %{index: index, count: count}

      is_binary(dedupe_key) ->
        case Regex.run(~r/:(\d+)-of-(\d+):\d+$/, dedupe_key, capture: :all_but_first) do
          [index, count] -> %{index: String.to_integer(index), count: String.to_integer(count)}
          _other -> nil
        end

      true ->
        nil
    end
  end

  defp fanout_summary(summary, %{index: index, count: count}),
    do: "#{summary} · batch #{index} of #{count}"

  defp fanout_summary(summary, _fanout), do: summary

  defp source_matrix(dedupe_key, result) do
    source_index = source_result_count(result, "source_partition_index")
    source_count = source_result_count(result, "source_partition_count")
    todo_index = source_result_count(result, "todo_batch_index")
    todo_count = source_result_count(result, "todo_batch_count")

    cond do
      source_index > 0 and source_count >= source_index and todo_index > 0 and
          todo_count >= todo_index ->
        matrix(source_index, source_count, todo_index, todo_count)

      is_binary(dedupe_key) ->
        case Regex.run(
               ~r/:source-(\d+)-of-(\d+):todo-(\d+)-of-(\d+):\d+-of-\d+:\d+$/,
               dedupe_key,
               capture: :all_but_first
             ) do
          [source_index, source_count, todo_index, todo_count] ->
            matrix(
              String.to_integer(source_index),
              String.to_integer(source_count),
              String.to_integer(todo_index),
              String.to_integer(todo_count)
            )

          _other ->
            nil
        end

      true ->
        nil
    end
  end

  defp matrix(source_index, source_count, todo_index, todo_count) do
    %{
      source_index: source_index,
      source_count: source_count,
      todo_index: todo_index,
      todo_count: todo_count
    }
  end

  defp source_result_count(result, key) when is_map(result) do
    case Map.get(result, key, 0) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp source_result_count(_result, _key), do: 0

  defp source_run_error("failed", last_error) do
    RunErrorCopy.runtime_failure(%{source: "background_job", details: last_error || "failed"})
  end

  defp source_run_error(_status, _last_error), do: nil

  defp source_error_code(last_error) when is_map(last_error),
    do: Maraithon.Redaction.error_class(last_error)

  defp source_error_code(last_error) when last_error in @source_error_codes,
    do: last_error

  defp source_error_code(_last_error), do: nil

  defp run_summary("running", _steps), do: "Working now"
  defp run_summary("completed", 0), do: "Finished successfully"
  defp run_summary("completed", 1), do: "Finished after 1 step"
  defp run_summary("completed", steps), do: "Finished after #{steps} steps"
  defp run_summary("failed", _steps), do: "Stopped before it could finish"
  defp run_summary("cancelled", _steps), do: "Stopped safely"
  defp run_summary(_status, _steps), do: "Run status updated"

  defp trigger_label(value) when value in ["schedule", "scheduled", "cron", "wakeup"],
    do: "Scheduled"

  defp trigger_label(value) when value in ["message", "user_message", "ask"],
    do: "User request"

  defp trigger_label(value) when value in ["event", "pubsub", "webhook", "subscription"],
    do: "Connected app event"

  defp trigger_label("manual"), do: "Started manually"
  defp trigger_label(_value), do: "Automatic trigger"

  defp source_label("gmail"), do: "Gmail"
  defp source_label("slack"), do: "Slack"
  defp source_label("calendar"), do: "Calendar"
  defp source_label("google_calendar"), do: "Calendar"
  defp source_label("messages"), do: "Messages"
  defp source_label("reminders"), do: "Reminders"
  defp source_label("manual"), do: "Manual"
  defp source_label("mobile"), do: "Mobile"
  defp source_label("mcp"), do: "Maraithon"
  defp source_label(_source), do: "Connected source"

  defp actor_label("user"), do: "You"
  defp actor_label(_actor_type), do: "Maraithon"

  defp presence(nil, fallback), do: fallback
  defp presence("", fallback), do: fallback
  defp presence(value, _fallback), do: value

  defp normalize_count(value) when is_integer(value) and value >= 0, do: value
  defp normalize_count(_value), do: 0

  defp duration_label(%DateTime{} = started_at, completed_at) do
    finished_at = if match?(%DateTime{}, completed_at), do: completed_at, else: DateTime.utc_now()
    seconds = max(DateTime.diff(finished_at, started_at, :second), 0)

    cond do
      seconds < 1 -> "under 1 second"
      seconds < 60 -> "#{seconds} sec"
      seconds < 3_600 -> "#{div(seconds, 60)} min #{rem(seconds, 60)} sec"
      true -> "#{div(seconds, 3_600)} hr #{div(rem(seconds, 3_600), 60)} min"
    end
  end

  defp duration_label(_started_at, _completed_at), do: "unknown"

  defp status_label("running"), do: "Running"
  defp status_label("pending"), do: "Queued"
  defp status_label("completed"), do: "Completed"
  defp status_label("failed"), do: "Failed"
  defp status_label("cancelled"), do: "Cancelled"
  defp status_label(_status), do: "Unknown"

  defp status_color("running"), do: "blue"
  defp status_color("pending"), do: "zinc"
  defp status_color("completed"), do: "emerald"
  defp status_color("failed"), do: "red"
  defp status_color("cancelled"), do: "zinc"
  defp status_color(_status), do: "zinc"

  defp status_dot_class("running"), do: "bg-blue-500"
  defp status_dot_class("pending"), do: "bg-zinc-400"
  defp status_dot_class("completed"), do: "bg-emerald-500"
  defp status_dot_class("failed"), do: "bg-red-500"
  defp status_dot_class("cancelled"), do: "bg-zinc-400"
  defp status_dot_class(_status), do: "bg-zinc-400"

  defp step_status_label("requested"), do: "In progress"
  defp step_status_label("completed"), do: "Done"
  defp step_status_label("failed"), do: "Failed"
  defp step_status_label(_status), do: "Updated"

  defp step_status_class("requested"), do: "bg-blue-500"
  defp step_status_class("completed"), do: "bg-emerald-500"
  defp step_status_class("failed"), do: "bg-red-500"
  defp step_status_class(_status), do: "bg-zinc-400"

  defp format_time(value, timezone_info),
    do: LocalTime.format_datetime(value, "Time unavailable", timezone_info)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="mx-auto max-w-4xl space-y-6">
        <.page_header
          title="Activity"
          subtitle="The latest OTP agent runs, per-account source fan-outs, and todo creations."
        >
          <:actions>
            <.badge color="emerald">
              <span class="size-1.5 rounded-full bg-emerald-500" aria-hidden="true"></span>
              Live
            </.badge>
            <.button variant="outline" phx-click="refresh_now">Refresh</.button>
          </:actions>
        </.page_header>

        <.panel body_class="px-5 py-0">
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 class="text-sm/6 font-semibold text-zinc-950">Latest activity</h2>
                <p class="text-sm/6 text-zinc-500">
                  {@run_count} agent {if @run_count == 1, do: "run", else: "runs"}, {@source_run_count} source {if @source_run_count == 1, do: "fan-out", else: "fan-outs"}, and {@todo_count} recent todo {if @todo_count == 1, do: "creation", else: "creations"}
                </p>
              </div>
              <p :if={@refreshed_at} class="text-xs/5 text-zinc-400">
                Updated {format_time(@refreshed_at, @timezone_info)}
              </p>
            </div>
          </:header>

          <div :if={@timeline == []} class="py-12 text-center">
            <p class="text-sm/6 font-medium text-zinc-700">No agent runs yet</p>
            <p class="mt-1 text-sm/6 text-zinc-500">New runs and created todos will appear here.</p>
          </div>

          <ol :if={@timeline != []} class="divide-y divide-zinc-950/5">
            <li
              :for={item <- @timeline}
              id={item.id}
              class="relative py-5 pl-8"
            >
              <span
                class={[
                  "absolute left-0 top-7 size-2.5 rounded-full ring-4 ring-white",
                  if(item.kind == :todo,
                    do: "bg-emerald-500",
                    else: status_dot_class(item.status)
                  )
                ]}
                aria-hidden="true"
              >
              </span>
              <span
                class="absolute bottom-0 left-[0.28125rem] top-9 w-px bg-zinc-200"
                aria-hidden="true"
              >
              </span>

              <div :if={item.kind == :source_run} data-testid="source-account-fan-out">
                <div class="flex flex-wrap items-start justify-between gap-x-4 gap-y-2">
                  <div class="min-w-0">
                    <div class="flex flex-wrap items-center gap-2">
                      <h3 class="text-sm/6 font-semibold text-zinc-950">{item.agent_name}</h3>
                      <.badge color={status_color(item.status)}>{status_label(item.status)}</.badge>
                    </div>
                    <p id={"#{item.id}-summary"} class="mt-1 text-sm/6 text-zinc-700">
                      {item.summary}
                    </p>
                  </div>
                  <time class="shrink-0 text-xs/5 text-zinc-400">
                    {format_time(item.occurred_at, @timezone_info)}
                  </time>
                </div>

                <p class="mt-1 text-xs/5 text-zinc-500">
                  {item.account} · {item.lane} · {item.duration}
                </p>

                <p
                  :if={item.safe_error}
                  class="mt-3 rounded-md bg-red-50 px-3 py-2 text-sm/6 text-red-700"
                >
                  {item.safe_error}
                </p>

                <details class="mt-3 text-xs/5 text-zinc-500">
                  <summary class="cursor-pointer select-none font-medium text-zinc-600 hover:text-zinc-950">
                    Fan-out details
                  </summary>
                  <dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 rounded-md bg-zinc-50 px-3 py-2">
                    <dt>Reference</dt>
                    <dd class="font-mono text-zinc-700">{item.reference}</dd>
                    <dt>Worker</dt>
                    <dd class="text-zinc-700">{item.role}</dd>
                    <dt>Stage</dt>
                    <dd class="text-zinc-700">{item.stage}</dd>
                    <dt>Lane</dt>
                    <dd class="text-zinc-700">{item.lane}</dd>
                    <dt>AI calls</dt>
                    <dd id={"#{item.id}-ai-policy"} class="text-zinc-700">{item.ai_calls}</dd>
                    <dt :if={item.source_items > 0}>Source items</dt>
                    <dd :if={item.source_items > 0} class="text-zinc-700">{item.source_items}</dd>
                    <dt :if={item.decision_count > 0}>Decisions</dt>
                    <dd :if={item.decision_count > 0} class="text-zinc-700">{item.decision_count}</dd>
                    <dt :if={item.matrix}>Source partition</dt>
                    <dd :if={item.matrix} class="text-zinc-700">
                      {item.matrix.source_index} of {item.matrix.source_count}
                    </dd>
                    <dt :if={item.matrix}>Todo batch</dt>
                    <dd :if={item.matrix} class="text-zinc-700">
                      {item.matrix.todo_index} of {item.matrix.todo_count}
                    </dd>
                    <dt>Failed attempts</dt>
                    <dd class="text-zinc-700">{item.failed_attempts}</dd>
                    <dt :if={item.last_error_code}>Last issue</dt>
                    <dd :if={item.last_error_code} class="font-mono text-zinc-700">
                      {item.last_error_code}
                    </dd>
                  </dl>
                </details>
              </div>

              <div :if={item.kind == :run}>
                <div class="flex flex-wrap items-start justify-between gap-x-4 gap-y-2">
                  <div class="min-w-0">
                    <div class="flex flex-wrap items-center gap-2">
                      <h3 class="text-sm/6 font-semibold text-zinc-950">{item.agent_name}</h3>
                      <.badge color={status_color(item.status)}>{status_label(item.status)}</.badge>
                    </div>
                    <p id={"#{item.id}-summary"} class="mt-1 text-sm/6 text-zinc-700">
                      {item.summary}
                    </p>
                  </div>
                  <time class="shrink-0 text-xs/5 text-zinc-400">
                    {format_time(item.occurred_at, @timezone_info)}
                  </time>
                </div>

                <p class="mt-1 text-xs/5 text-zinc-500">
                  {item.trigger} · {item.duration}
                </p>

                <p
                  :if={item.safe_error}
                  class="mt-3 rounded-md bg-red-50 px-3 py-2 text-sm/6 text-red-700"
                >
                  {item.safe_error}
                </p>

                <ul :if={item.steps != []} class="mt-3 space-y-1.5 border-l border-zinc-200 pl-3">
                  <li :for={step <- item.steps} class="flex items-center justify-between gap-4 text-sm/6">
                    <span class="flex min-w-0 items-center gap-2 text-zinc-700">
                      <span
                        class={["size-1.5 shrink-0 rounded-full", step_status_class(step.status)]}
                        aria-hidden="true"
                      >
                      </span>
                      <span class="truncate">{step.label}</span>
                    </span>
                    <span class="shrink-0 text-xs/5 text-zinc-400">
                      {step_status_label(step.status)}
                    </span>
                  </li>
                </ul>

                <details class="mt-3 text-xs/5 text-zinc-500">
                  <summary class="cursor-pointer select-none font-medium text-zinc-600 hover:text-zinc-950">
                    Run details
                  </summary>
                  <dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 rounded-md bg-zinc-50 px-3 py-2">
                    <dt>Reference</dt>
                    <dd class="font-mono text-zinc-700">{item.reference}</dd>
                    <dt>Trigger</dt>
                    <dd class="text-zinc-700">{item.trigger}</dd>
                    <dt>AI calls</dt>
                    <dd id={"#{item.id}-llm-calls"} class="text-zinc-700">{item.llm_calls}</dd>
                    <dt>Actions</dt>
                    <dd id={"#{item.id}-tool-calls"} class="text-zinc-700">{item.tool_calls}</dd>
                    <dt :if={item.last_action}>Last action</dt>
                    <dd :if={item.last_action} class="text-zinc-700">{item.last_action}</dd>
                  </dl>
                </details>
              </div>

              <div :if={item.kind == :todo}>
                <div class="flex flex-wrap items-start justify-between gap-x-4 gap-y-2">
                  <div class="min-w-0">
                    <.badge color="emerald">Todo created</.badge>
                    <.link
                      :if={item.linked?}
                      navigate={~p"/todos/#{item.todo_id}"}
                      class="mt-2 block text-sm/6 font-semibold text-zinc-950 hover:underline"
                    >
                      {item.title}
                    </.link>
                    <p :if={!item.linked?} class="mt-2 text-sm/6 font-semibold text-zinc-950">
                      {item.title}
                    </p>
                    <p class="mt-1 text-xs/5 text-zinc-500">
                      Created by {item.actor} · {item.source}
                    </p>
                  </div>
                  <time class="shrink-0 text-xs/5 text-zinc-400">
                    {format_time(item.occurred_at, @timezone_info)}
                  </time>
                </div>
              </div>
            </li>
          </ol>

          <div :if={@source_run_count >= @source_run_limit} class="border-t border-zinc-950/5 py-4 text-center">
            <.button variant="outline" phx-click="load_more_source_runs">
              Load older source fan-outs
            </.button>
          </div>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end
