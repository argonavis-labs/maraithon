defmodule Maraithon.TelegramAssistant.Continuation do
  @moduledoc """
  Bounded continuation for an owned conversation request.

  A model entry is charged before calling the provider. Its public decision is
  saved before any tools run. Tool receipts live in the existing encrypted Step
  ledger; the checkpoint stores counters, routing and the current decision only.
  Recovery rebuilds public history, never provider-private reasoning. A running
  mutating tool without a receipt requires reconciliation, not blind replay.
  """

  import Ecto.Query
  alias Maraithon.{AssistantHarness, DurablePayload, Repo, TelegramAssistant}
  alias Maraithon.AssistantChat.Execution
  alias Maraithon.TelegramAssistant.{Run, Step, Toolbox}

  @key "execution_checkpoint"
  @version 1
  @max_bytes 64_000
  @counters [:iteration, :llm_turns, :tool_steps, :sequence]
  @options ~w(chat_model reasoning_effort max_tokens request_focus context_scope tool_scope
    max_wall_clock_ms max_llm_turns max_tool_steps model_busy_max_retries
    model_retry_max_delay_ms)a
  @scopes ~w(connector_status source_hint_identity person_context linked_item_context
    quick_chat today_mode waiting_on meeting_prep commitment_audit continuity)a

  def enabled?(attrs), do: attrs[:durable_processing] == true and attrs[:surface] == "mobile"
  def present?(%Run{} = run), do: is_map((run.result_summary || %{})[@key])

  def upgrade(run, checkpoint, profile, state, opts) do
    policy = AssistantHarness.runtime_policy(opts).loop
    original_start = checkpoint["deadline_ms"] - checkpoint["policy"]["max_wall_clock_ms"]

    checkpoint =
      checkpoint
      |> Map.put("deadline_ms", original_start + policy.max_wall_clock_ms)
      |> Map.put("policy", policy)
      |> Map.put("profile", encode_profile(profile))

    save(run, checkpoint, "ready", state)
  end

  def start(run, attrs, profile, opts) do
    if enabled?(attrs) do
      policy = AssistantHarness.runtime_policy(opts).loop

      checkpoint = %{
        "version" => @version,
        "run_id" => run.id,
        "user_id" => run.user_id,
        "conversation_id" => run.conversation_id,
        "source_message_id" => Map.fetch!(attrs, :source_message_id),
        "deadline_ms" => System.system_time(:millisecond) + policy.max_wall_clock_ms,
        "policy" => policy,
        "profile" => encode_profile(profile)
      }

      save(run, checkpoint, "ready", AssistantHarness.initial_loop_state())
    else
      {:ok, nil}
    end
  end

  def save(run, checkpoint, phase, state, response \\ nil)
  def save(_run, nil, _phase, _state, _response), do: {:ok, nil}

  def save(run, checkpoint, phase, state, response) do
    value =
      checkpoint
      |> Map.put("phase", phase)
      |> Map.put("state", Map.take(state, @counters))
      |> Map.put("response", public_response(response))

    with {:ok, bounded} <- DurablePayload.prepare_map(value, @max_bytes),
         {:ok, _} <-
           Execution.write_run(run, fn current ->
             TelegramAssistant.update_run(current, %{
               result_summary: Map.put(current.result_summary || %{}, @key, bounded)
             })
           end) do
      {:ok, bounded}
    end
  end

  def load(%Run{} = run, attrs) do
    checkpoint = (Run.hydrate_payloads(run).result_summary || %{})[@key]

    with :ok <- validate(checkpoint, run, attrs),
         {:ok, profile} <- decode_profile(checkpoint["profile"]),
         {:ok, history} <- history(run.id, checkpoint["state"]["sequence"]),
         true <- length(history) == checkpoint["state"]["tool_steps"] do
      state = Map.new(@counters, &{&1, checkpoint["state"][Atom.to_string(&1)]})
      state = Map.put(state, :tool_history, history)

      limits =
        Map.new(
          [:max_wall_clock_ms, :max_llm_turns, :max_tool_steps],
          &{&1, checkpoint["policy"][Atom.to_string(&1)]}
        )
        |> Map.to_list()

      profile = Map.update!(profile, :llm_opts, &Keyword.merge(&1, limits))
      {:ok, checkpoint, profile, state}
    else
      false -> {:error, :incomplete_tool_history}
      error -> error
    end
  end

  def validate(checkpoint, run, attrs) do
    with true <- is_map(checkpoint),
         {:ok, _} <- DurablePayload.prepare_map(checkpoint, @max_bytes),
         true <- checkpoint["version"] == @version,
         true <- checkpoint["run_id"] == run.id and checkpoint["user_id"] == run.user_id,
         true <- checkpoint["conversation_id"] == run.conversation_id,
         true <- checkpoint["source_message_id"] == attrs[:source_message_id],
         true <- is_map(attrs[:conversation]),
         true <-
           attrs[:user_id] == run.user_id and
             Map.get(attrs[:conversation], :id) == run.conversation_id,
         true <- run.status == "running" and run.surface == "mobile",
         true <- checkpoint["phase"] in ["ready", "model_entered", "decision"],
         true <- valid_counters?(checkpoint["state"]),
         true <- is_integer(checkpoint["deadline_ms"]),
         true <- valid_policy?(checkpoint["policy"]),
         true <- valid_decision?(checkpoint) do
      :ok
    else
      _ -> {:error, :invalid_execution_checkpoint}
    end
  end

  # The deadline survives node changes. Queue time after a crash does not grant
  # a new execution budget. A saved final decision can still drain delivery.
  def remaining_ms(checkpoint),
    do: max(checkpoint["deadline_ms"] - System.system_time(:millisecond), 0)

  def tool(run, call, sequence) do
    name = call["tool"]
    arguments = call["arguments"] || %{}
    identity = call["call_id"] || "#{run.id}:#{sequence}"
    request = %{"tool" => name, "arguments" => arguments, "call_id" => identity}

    Execution.write_run(run, fn _current ->
      existing = Repo.get_by(Step, run_id: run.id, sequence: sequence) |> Step.hydrate_payloads()

      case existing do
        nil ->
          case TelegramAssistant.create_step(%{
                 run_id: run.id,
                 sequence: sequence,
                 step_type: "tool_call",
                 status: "running",
                 request_payload: request,
                 started_at: DateTime.utc_now()
               }) do
            {:ok, step} -> {:ok, {:execute, step}}
            error -> error
          end

        %Step{step_type: "tool_call", request_payload: ^request, status: status} = step
        when status in ["completed", "failed"] ->
          {:ok, {:receipt, entry(step)}}

        %Step{step_type: "tool_call", request_payload: ^request, status: "running"} = step ->
          if Toolbox.replayable_read?(name, arguments) do
            {:ok, {:execute, step}}
          else
            {:error, {:tool_outcome_unknown, step.id}}
          end

        _ ->
          {:error, :tool_checkpoint_mismatch}
      end
    end)
  end

  defp history(run_id, sequence) do
    steps =
      Repo.all(
        from s in Step,
          where: s.run_id == ^run_id and s.step_type == "tool_call" and s.sequence <= ^sequence,
          order_by: s.sequence,
          limit: 25
      )
      |> Enum.map(&Step.hydrate_payloads/1)

    if length(steps) <= 24 and Enum.all?(steps, &(&1.status in ["completed", "failed"])) do
      {:ok, Enum.map(steps, &entry/1)}
    else
      {:error, :incomplete_tool_history}
    end
  end

  defp entry(step) do
    %{"tool" => step.request_payload["tool"], "arguments" => step.request_payload["arguments"]}
    |> Map.put(
      if(step.status == "completed", do: "result", else: "error"),
      if(step.status == "completed", do: step.response_payload, else: step.error)
    )
  end

  defp public_response(nil), do: nil

  defp public_response(response) do
    calls = get_in(response, ["_native_message", "tool_calls"]) || []

    response
    |> Map.delete("_native_message")
    |> Map.update("tool_calls", [], fn tools ->
      tools
      |> Enum.with_index()
      |> Enum.map(fn {call, index} ->
        case Enum.at(calls, index) do
          %{"id" => id} -> Map.put(call, "call_id", id)
          _ -> call
        end
      end)
    end)
  end

  defp valid_counters?(state) when is_map(state) do
    Enum.all?(@counters, fn key ->
      value = state[Atom.to_string(key)]
      is_integer(value) and value >= 0 and value <= 100
    end) and state["iteration"] > 0 and state["sequence"] > 0 and
      state["llm_turns"] <= 16 and state["tool_steps"] <= 24 and
      state["sequence"] == 1 + 2 * state["llm_turns"] + state["tool_steps"]
  end

  defp valid_counters?(_), do: false

  defp valid_policy?(%{
         "max_wall_clock_ms" => wall,
         "max_llm_turns" => llm,
         "max_tool_steps" => tool
       }) do
    is_integer(wall) and wall in 1..120_000 and is_integer(llm) and llm in 1..16 and
      is_integer(tool) and tool in 1..24
  end

  defp valid_policy?(_), do: false

  defp valid_decision?(%{"phase" => "decision", "response" => %{"status" => status} = response}) do
    calls = response["tool_calls"] || []

    status in ["final", "tool_calls"] and is_list(calls) and length(calls) <= 3 and
      Enum.all?(calls, &valid_call?/1) and unique_call_ids?(calls)
  end

  defp valid_decision?(%{"phase" => phase, "response" => nil}),
    do: phase in ["ready", "model_entered"]

  defp valid_decision?(_), do: false

  defp valid_call?(call) when is_map(call) do
    is_binary(call["tool"]) and byte_size(call["tool"]) in 1..128 and
      is_map(call["arguments"] || %{}) and
      (is_nil(call["call_id"]) or
         (is_binary(call["call_id"]) and byte_size(call["call_id"]) in 1..255))
  end

  defp valid_call?(_), do: false

  defp unique_call_ids?(calls) do
    ids = Enum.map(calls, & &1["call_id"]) |> Enum.reject(&is_nil/1)
    length(Enum.uniq(ids)) == length(ids)
  end

  defp encode_profile(profile) do
    profile
    |> Map.take([:tier, :model, :reasoning_effort, :task_class, :route_reason])
    |> Map.new(fn {key, value} -> {key, json_value(value)} end)
    |> Map.put(
      :llm_opts,
      Map.new(
        Keyword.take(profile[:llm_opts] || [], @options),
        fn {key, value} -> {key, json_value(value)} end
      )
    )
  end

  defp json_value(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp json_value(value), do: value

  defp decode_profile(%{"tier" => tier, "llm_opts" => opts} = profile)
       when tier in ["fast", "chat", "reasoning"] and is_map(opts) do
    if is_binary(profile["model"]) and
         Enum.all?(opts, fn {key, value} -> valid_option?(key, value) end) do
      restore_profile(profile, opts, tier)
    else
      {:error, :invalid_execution_profile}
    end
  end

  defp decode_profile(_), do: {:error, :invalid_execution_profile}

  defp valid_option?(key, value) do
    cond do
      key in ~w(request_focus context_scope tool_scope) ->
        Enum.any?(@scopes, &(Atom.to_string(&1) == value))

      key in ~w(chat_model reasoning_effort) ->
        is_binary(value)

      key in Enum.map(@options, &Atom.to_string/1) ->
        is_integer(value) and value in 0..120_000

      true ->
        false
    end
  end

  defp restore_profile(profile, opts, tier) do
    options =
      Enum.flat_map(@options, fn key ->
        case Map.fetch(opts, Atom.to_string(key)) do
          {:ok, value} when key in [:request_focus, :context_scope, :tool_scope] ->
            case Enum.find(@scopes, &(Atom.to_string(&1) == value)) do
              nil -> []
              scope -> [{key, scope}]
            end

          {:ok, value} ->
            [{key, value}]

          :error ->
            []
        end
      end)

    {:ok,
     %{
       tier: Enum.find([:fast, :chat, :reasoning], &(Atom.to_string(&1) == tier)),
       model: profile["model"],
       reasoning_effort: profile["reasoning_effort"],
       task_class: profile["task_class"],
       route_reason: profile["route_reason"],
       llm_opts: options
     }}
  end
end
