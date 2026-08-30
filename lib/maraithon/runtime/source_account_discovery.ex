defmodule Maraithon.Runtime.SourceAccountDiscovery do
  @moduledoc """
  Runs one source-account discovery worker as a durable provider/model handoff.

  Provider work fetches only the delta after that account's discovery cursor.
  Empty deltas advance without a model call. Non-empty deltas are compacted
  into an encrypted background-job payload, reasoned over once, and advance
  only after the resulting insight/todo writes have settled. An enabled Chief
  contributes its Follow-through configuration; accounts without one use the
  same safe defaults without requiring a long-lived Agent row.
  """

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Agents.Agent
  alias Maraithon.ChiefOfStaff.{Acquisition, SourceBundle, SourceScope}
  alias Maraithon.ChiefOfStaff.Skills.Followthrough
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.LLM

  @handoff_max_bytes 500_000
  @max_drive_steps 6
  @allowed_watermark_kinds ~w(gmail_discovery_watermark slack_discovery_watermark)
  @compact_profiles [
    %{
      gmail_inbox: 28,
      gmail_sent: 40,
      gmail_all: 64,
      slack_messages: 100,
      slack_mentions: 50,
      chars: 4_000
    },
    %{
      gmail_inbox: 18,
      gmail_sent: 24,
      gmail_all: 40,
      slack_messages: 60,
      slack_mentions: 30,
      chars: 2_000
    },
    %{
      gmail_inbox: 8,
      gmail_sent: 12,
      gmail_all: 20,
      slack_messages: 24,
      slack_mentions: 12,
      chars: 1_000
    },
    %{
      gmail_inbox: 4,
      gmail_sent: 4,
      gmail_all: 8,
      slack_messages: 8,
      slack_mentions: 4,
      chars: 500
    }
  ]

  @doc "Fetches one exact account delta and returns either a settled result or a sealed handoff."
  def acquire(account, agent, opts \\ [])

  def acquire(
        %ConnectedAccount{status: "connected"} = account,
        %Agent{} = agent,
        opts
      )
      when is_list(opts) do
    do_acquire(account, agent, opts)
  end

  def acquire(%ConnectedAccount{status: "connected"} = account, nil, opts)
      when is_list(opts) do
    do_acquire(account, nil, opts)
  end

  def acquire(%ConnectedAccount{}, agent, _opts) when is_nil(agent) or is_struct(agent, Agent),
    do: {:skip, :account_not_connected}

  def acquire(_account, _agent, _opts), do: {:error, :invalid_source_discovery_identity}

  defp do_acquire(account, agent, opts) do
    with :ok <- validate_ownership(account, agent),
         {bundle, telemetry, proposals} <- acquire_bundle(account, agent, opts),
         :ok <- validate_complete_acquisition(account, telemetry),
         compact_bundle when is_map(compact_bundle) <- compact_bundle(bundle),
         watermarks <- serialize_watermarks(proposals, account.id),
         source_items <- source_item_count(compact_bundle) do
      if source_items == 0 do
        with :ok <- advance_watermarks(account, watermarks) do
          {:ok,
           %{
             outcome: "empty_delta",
             account_id: account.id,
             source_items: 0,
             model_calls: 0,
             advanced_watermarks: length(watermarks)
           }}
        end
      else
        {:ok,
         %{
           outcome: "handoff_ready",
           account_id: account.id,
           source_items: source_items,
           handoff:
             %{
               "account_id" => account.id,
               "acquisition_job_id" => Keyword.get(opts, :acquisition_job_id),
               "source_bundle" => compact_bundle,
               "watermarks" => watermarks
             }
             |> maybe_put_agent_id(agent)
         }}
      end
    else
      nil -> {:error, :invalid_source_bundle}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_discovery_result}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  @doc "Reasons over one sealed account delta and advances its discovery cursor after writes settle."
  def reason(account, agent, payload, opts \\ [])

  def reason(%ConnectedAccount{} = account, %Agent{} = agent, payload, opts)
      when is_map(payload) and is_list(opts) do
    do_reason(account, agent, payload, opts)
  end

  def reason(%ConnectedAccount{} = account, nil, payload, opts)
      when is_map(payload) and is_list(opts) do
    do_reason(account, nil, payload, opts)
  end

  def reason(_account, _agent, _payload, _opts), do: {:error, :invalid_source_discovery_payload}

  defp do_reason(account, agent, payload, opts) do
    with :ok <- validate_ownership(account, agent),
         {:ok, bundle} <- fetch_map(payload, "source_bundle"),
         {:ok, watermarks} <- fetch_list(payload, "watermarks"),
         :ok <- validate_payload_identity(account, agent, payload),
         {:ok, outcome} <- run_followthrough(account, agent, bundle, opts),
         :ok <- advance_watermarks(account, watermarks) do
      {:ok,
       outcome
       |> Map.put(:account_id, account.id)
       |> Map.put(:source_items, source_item_count(bundle))
       |> Map.put(:advanced_watermarks, length(watermarks))}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_discovery_payload}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  @doc false
  def compact_bundle(bundle) when is_map(bundle) do
    Enum.find_value(@compact_profiles, fn profile ->
      compact = build_compact_bundle(bundle, profile)
      if encoded_bytes(compact) <= @handoff_max_bytes, do: compact
    end)
  end

  def compact_bundle(_bundle), do: nil

  @doc false
  def source_item_count(bundle) when is_map(bundle) do
    gmail_count =
      (SourceBundle.gmail_messages(bundle) ++
         SourceBundle.gmail_inbox_messages(bundle) ++
         SourceBundle.gmail_sent_messages(bundle))
      |> Enum.uniq()
      |> length()

    slack_count =
      (SourceBundle.slack_messages(bundle) ++ SourceBundle.slack_mentions(bundle))
      |> Enum.uniq()
      |> length()

    gmail_count + slack_count
  end

  def source_item_count(_bundle), do: 0

  defp acquire_bundle(account, agent, opts) do
    acquisition = Keyword.get(opts, :acquisition, &Acquisition.build/4)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    source_scope = account_source_scope(account)

    context = %{
      user_id: account.user_id,
      agent_id: agent_id(agent),
      timestamp: now,
      trigger: %{type: :pubsub_event, job_type: "source_account_discovery"},
      event: %{topic: account_event_topic(account), payload: %{}},
      recent_events: [],
      source_scope: source_scope,
      source_watermark_role: "discovery",
      defer_watermark_advance: true,
      exhaustive_account_delta: true,
      account_delta_source: account_delta_source(account)
    }

    acquisition.(
      account.user_id,
      ["followthrough"],
      %{"followthrough" => discovery_config(agent, account.user_id, source_scope)},
      context
    )
  end

  defp run_followthrough(account, agent, bundle, opts) do
    module = Keyword.get(opts, :followthrough_module, Followthrough)
    llm_complete = Keyword.get(opts, :llm_complete, &LLM.complete/1)
    source_scope = account_source_scope(account)
    now = Keyword.get(opts, :now, parse_datetime(bundle["fetched_at"]) || DateTime.utc_now())

    context = %{
      user_id: account.user_id,
      agent_id: agent_id(agent),
      timestamp: now,
      trigger: %{type: :wakeup, job_type: "source_account_discovery_reason"},
      recent_events: [],
      source_scope: source_scope,
      source_bundle: bundle
    }

    state = module.init(discovery_config(agent, account.user_id, source_scope))
    drive_outcome(module.handle_wakeup(state, context), module, context, llm_complete, 0, 0)
  end

  defp drive_outcome(_outcome, _module, _context, _llm_complete, _model_calls, steps)
       when steps >= @max_drive_steps,
       do: {:error, :source_discovery_step_limit}

  defp drive_outcome({:idle, _state}, _module, _context, _llm_complete, model_calls, _steps) do
    {:ok, %{outcome: "idle", model_calls: model_calls}}
  end

  defp drive_outcome(
         {:emit, {event_type, payload}, _state},
         _module,
         _context,
         _llm_complete,
         model_calls,
         _steps
       ) do
    {:ok,
     %{
       outcome: "emitted",
       event_type: to_string(event_type),
       emitted_count: payload_count(payload),
       model_calls: model_calls
     }}
  end

  defp drive_outcome(
         {:continue, state},
         module,
         context,
         llm_complete,
         model_calls,
         steps
       ) do
    drive_outcome(
      module.handle_wakeup(state, context),
      module,
      context,
      llm_complete,
      model_calls,
      steps + 1
    )
  end

  defp drive_outcome(
         {:effect, {:llm_call, params}, state},
         module,
         context,
         llm_complete,
         model_calls,
         steps
       )
       when is_map(params) do
    if pending_llm_kind(state) == :insights and model_calls == 0 do
      with {:ok, response} <- llm_complete.(params) do
        drive_outcome(
          module.handle_effect_result({:llm_call, response}, state, context),
          module,
          context,
          llm_complete,
          model_calls + 1,
          steps + 1
        )
      end
    else
      drive_outcome(
        module.handle_effect_error(
          :llm_call,
          :relationship_learning_deferred_for_source_account_worker,
          state,
          context
        ),
        module,
        context,
        llm_complete,
        model_calls,
        steps + 1
      )
    end
  end

  defp drive_outcome({:effect, _effect, _state}, _module, _context, _llm, _calls, _steps),
    do: {:error, :unsupported_source_discovery_effect}

  defp drive_outcome(_outcome, _module, _context, _llm, _calls, _steps),
    do: {:error, :invalid_source_discovery_outcome}

  defp pending_llm_kind(%{inbox_state: %{pending_llm_kind: kind}}), do: kind
  defp pending_llm_kind(_state), do: nil

  defp discovery_config(agent, user_id, source_scope) do
    agent_config = if is_struct(agent, Agent), do: agent.config || %{}, else: %{}

    Followthrough.default_config()
    |> Map.merge(shared_config(agent_config))
    |> Map.merge(read_map(read_map(agent_config, "skill_configs"), "followthrough"))
    |> Map.put("user_id", user_id)
    |> Map.put("source_scope", source_scope)
    |> Map.put("assistant_behavior", "ai_chief_of_staff")
  end

  defp shared_config(config) do
    ["timezone", "timezone_name", "timezone_offset_hours", "source_policy"]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(config, key, Map.get(config, existing_atom(key))) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp build_compact_bundle(bundle, profile) do
    gmail_messages = SourceBundle.gmail_messages(bundle) |> Enum.take(profile.gmail_all)
    gmail_inbox = SourceBundle.gmail_inbox_messages(bundle) |> Enum.take(profile.gmail_inbox)
    gmail_sent = SourceBundle.gmail_sent_messages(bundle) |> Enum.take(profile.gmail_sent)

    %{
      "trigger" => Map.get(bundle, "trigger"),
      "fetched_at" => Map.get(bundle, "fetched_at"),
      "freshness" => SourceBundle.freshness(bundle),
      "source_scope" => SourceBundle.source_scope(bundle),
      "gmail" => %{
        "messages" => gmail_messages,
        "inbox_messages" => gmail_inbox,
        "sent_messages" => gmail_sent,
        "messages_by_provider" => %{}
      },
      "calendar" => %{"events" => [], "events_by_provider" => %{}},
      "slack" => %{
        "workspaces" => [],
        "messages" => SourceBundle.slack_messages(bundle) |> Enum.take(profile.slack_messages),
        "mentions" => SourceBundle.slack_mentions(bundle) |> Enum.take(profile.slack_mentions)
      }
    }
    |> compact_value(profile.chars)
  end

  defp compact_value(%DateTime{} = value, _max_chars), do: DateTime.to_iso8601(value)
  defp compact_value(%NaiveDateTime{} = value, _max_chars), do: NaiveDateTime.to_iso8601(value)

  defp compact_value(value, max_chars) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), compact_value(nested, max_chars)} end)
  end

  defp compact_value(value, max_chars) when is_list(value),
    do: Enum.map(value, &compact_value(&1, max_chars))

  defp compact_value(value, max_chars) when is_binary(value),
    do: String.slice(value, 0, max_chars)

  defp compact_value(value, _max_chars) when is_atom(value), do: to_string(value)
  defp compact_value(value, _max_chars), do: value

  defp encoded_bytes(value) do
    case Jason.encode(value) do
      {:ok, json} -> byte_size(json)
      {:error, _reason} -> @handoff_max_bytes + 1
    end
  end

  defp serialize_watermarks(proposals, account_id) when is_list(proposals) do
    proposals
    |> Enum.flat_map(fn
      %{
        account: %ConnectedAccount{id: ^account_id},
        kind: kind,
        value: value
      }
      when kind in @allowed_watermark_kinds and is_binary(value) ->
        [%{"account_id" => account_id, "kind" => kind, "value" => value}]

      _other ->
        []
    end)
    |> Enum.uniq_by(&{&1["kind"], &1["value"]})
  end

  defp serialize_watermarks(_proposals, _account_id), do: []

  defp advance_watermarks(account, watermarks) when is_list(watermarks) do
    Enum.reduce_while(watermarks, :ok, fn watermark, :ok ->
      with true <- read_integer(watermark, "account_id") == account.id,
           kind when kind in @allowed_watermark_kinds <- read_string(watermark, "kind"),
           value when is_binary(value) <- read_string(watermark, "value"),
           {:ok, _cursor} <- SourceCursors.put(account, kind, %{"value" => value}) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :source_discovery_watermark_account_mismatch}}
        nil -> {:halt, {:error, :invalid_source_discovery_watermark}}
        {:error, reason} -> {:halt, {:error, {:source_discovery_cursor_advance_failed, reason}}}
        _other -> {:halt, {:error, :invalid_source_discovery_watermark}}
      end
    end)
  end

  defp validate_ownership(%ConnectedAccount{user_id: user_id}, %Agent{user_id: user_id}), do: :ok
  defp validate_ownership(%ConnectedAccount{}, nil), do: :ok
  defp validate_ownership(_account, _agent), do: {:error, :source_discovery_user_mismatch}

  defp validate_payload_identity(account, %Agent{} = agent, payload) do
    if read_integer(payload, "account_id") == account.id and
         read_string(payload, "agent_id") == agent.id do
      :ok
    else
      {:error, :source_discovery_payload_identity_mismatch}
    end
  end

  defp validate_payload_identity(account, nil, payload) do
    if read_integer(payload, "account_id") == account.id and
         is_nil(read_string(payload, "agent_id")) do
      :ok
    else
      {:error, :source_discovery_payload_identity_mismatch}
    end
  end

  defp maybe_put_agent_id(payload, %Agent{id: id}), do: Map.put(payload, "agent_id", id)
  defp maybe_put_agent_id(payload, nil), do: payload

  defp agent_id(%Agent{id: id}), do: id
  defp agent_id(nil), do: nil

  defp account_source_scope(%ConnectedAccount{provider: provider} = account) do
    service = if provider == "google" or String.starts_with?(provider, "google:"), do: "gmail"
    SourceScope.for_account(account, service)
  end

  defp account_event_topic(%ConnectedAccount{provider: "slack:" <> rest}) do
    team_id = rest |> String.split(":", parts: 2) |> List.first()
    "slack:#{team_id}"
  end

  defp account_event_topic(%ConnectedAccount{id: id}), do: "email:account-#{id}"

  defp account_delta_source(%ConnectedAccount{provider: "slack:" <> _rest}), do: "slack"
  defp account_delta_source(%ConnectedAccount{}), do: "gmail"

  defp validate_complete_acquisition(account, telemetry) do
    source = account_delta_source(account)

    if Acquisition.source_complete?(telemetry, source) do
      :ok
    else
      {:error, {:source_discovery_acquisition_incomplete, source}}
    end
  end

  defp payload_count(payload) when is_map(payload) do
    case Map.get(payload, :count, Map.get(payload, "count", 0)) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp payload_count(_payload), do: 0

  defp read_map(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, existing_atom(key), %{})) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp fetch_map(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _other -> {:error, {:missing_map_payload, key}}
    end
  end

  defp fetch_list(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      _other -> {:error, {:missing_list_payload, key}}
    end
  end

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, existing_atom(key))) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp read_integer(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, existing_atom(key))) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp existing_atom(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end
end
