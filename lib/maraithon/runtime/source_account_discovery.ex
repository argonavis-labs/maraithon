defmodule Maraithon.Runtime.SourceAccountDiscovery do
  @moduledoc """
  Runs one source-account discovery worker as a durable provider/model handoff.

  Provider work fetches only the delta after that account's discovery cursor.
  Empty deltas advance without a model call. Non-empty deltas are partitioned
  into small encrypted reasoning handoffs, and advance only after every
  handoff has made a decision for every source item. An enabled Chief
  contributes its Follow-through configuration; accounts without one use the
  same safe defaults without requiring a long-lived Agent row.
  """

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Agents.Agent
  alias Maraithon.ChiefOfStaff.{Acquisition, SourceBundle, SourceScope}
  alias Maraithon.ChiefOfStaff.Skills.Followthrough
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Todos

  @handoff_max_bytes 500_000
  @handoff_item_limit 5
  @allowed_watermark_kinds ~w(gmail_discovery_watermark slack_discovery_watermark)

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
         watermarks <- serialize_watermarks(proposals, account.id),
         :ok <- validate_watermarks(watermarks),
         {:ok, partitions} <- partition_bundle(bundle),
         source_items <- Enum.sum(Enum.map(partitions, &source_item_count/1)) do
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
        fanout_count = length(partitions)

        handoffs =
          partitions
          |> Enum.with_index(1)
          |> Enum.map(fn {partition, fanout_index} ->
            %{
              "account_id" => account.id,
              "acquisition_job_id" => Keyword.get(opts, :acquisition_job_id),
              "fanout_index" => fanout_index,
              "fanout_count" => fanout_count,
              "source_bundle" => partition,
              "source_item_refs" => source_item_refs(partition),
              "watermarks" => []
            }
            |> maybe_put_agent_id(agent)
          end)

        {:ok,
         %{
           outcome: "fanout_ready",
           account_id: account.id,
           source_items: source_items,
           fanout_count: fanout_count,
           handoffs: handoffs,
           finalizer:
             %{
               "account_id" => account.id,
               "acquisition_job_id" => Keyword.get(opts, :acquisition_job_id),
               "expected_fanouts" => fanout_count,
               "expected_source_items" => source_items,
               "expected_source_refs_digest" =>
                 partitions |> Enum.flat_map(&source_item_refs/1) |> refs_digest(),
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

  @doc "Reasons over one small sealed account-delta partition."
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
         {:ok, source_item_refs} <- fetch_list(payload, "source_item_refs", []),
         :ok <- validate_payload_identity(account, agent, payload),
         source_items when source_items > 0 <- source_item_count(bundle),
         ^source_items <- length(source_item_refs),
         ^source_item_refs <- source_item_refs(bundle),
         {:ok, outcome} <- run_todo_decisions(account, bundle, opts),
         ^source_items <- Map.get(outcome, :decision_count),
         ^source_item_refs <- Map.get(outcome, :decision_refs),
         :ok <- advance_watermarks(account, watermarks) do
      {:ok,
       outcome
       |> Map.put(:account_id, account.id)
       |> Map.put(:source_items, source_items)
       |> Map.put(:fanout_index, read_integer(payload, "fanout_index"))
       |> Map.put(:fanout_count, read_integer(payload, "fanout_count"))
       |> Map.put(:advanced_watermarks, length(watermarks))}
    else
      false -> {:error, :source_discovery_partition_identity_mismatch}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_discovery_payload}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  @doc "Advances a discovery cursor only after all child partitions prove exact decisions."
  def finalize(account, agent, payload, child_results)

  def finalize(%ConnectedAccount{} = account, agent, payload, child_results)
      when (is_nil(agent) or is_struct(agent, Agent)) and is_map(payload) and
             is_list(child_results) do
    with :ok <- validate_ownership(account, agent),
         :ok <- validate_payload_identity(account, agent, payload),
         {:ok, watermarks} <- fetch_list(payload, "watermarks"),
         expected_fanouts when is_integer(expected_fanouts) and expected_fanouts > 0 <-
           read_integer(payload, "expected_fanouts"),
         expected_source_items
         when is_integer(expected_source_items) and expected_source_items > 0 <-
           read_integer(payload, "expected_source_items"),
         expected_source_refs_digest when is_binary(expected_source_refs_digest) <-
           read_string(payload, "expected_source_refs_digest"),
         :ok <-
           validate_child_results(
             child_results,
             expected_fanouts,
             expected_source_items,
             expected_source_refs_digest
           ),
         :ok <- advance_watermarks(account, watermarks) do
      {:ok,
       %{
         outcome: "finalized",
         account_id: account.id,
         fanout_count: expected_fanouts,
         source_items: expected_source_items,
         decision_count: expected_source_items,
         model_calls: Enum.sum(Enum.map(child_results, &result_integer(&1, "model_calls"))),
         advanced_watermarks: length(watermarks)
       }}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_discovery_finalizer}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  def finalize(_account, _agent, _payload, _child_results),
    do: {:error, :invalid_source_discovery_finalizer}

  @doc false
  def partition_bundle(bundle) when is_map(bundle) do
    if source_identities_complete?(bundle) do
      partitions =
        bundle
        |> source_records()
        |> grouped_source_records()
        |> pack_source_groups(@handoff_item_limit)
        |> Enum.map(&compact_partition(bundle, &1))

      if Enum.all?(partitions, &is_map/1),
        do: {:ok, partitions},
        else: {:error, :source_discovery_partition_too_large}
    else
      {:error, :source_discovery_item_identity_missing}
    end
  end

  def partition_bundle(_bundle), do: {:error, :invalid_source_bundle}

  @doc false
  def compact_bundle(bundle) when is_map(bundle) do
    compact = build_compact_bundle(bundle)
    if encoded_bytes(compact) <= @handoff_max_bytes, do: compact
  end

  def compact_bundle(_bundle), do: nil

  @doc false
  def source_item_count(bundle) when is_map(bundle) do
    bundle |> source_records() |> length()
  end

  def source_item_count(_bundle), do: 0

  @doc false
  def source_item_refs(bundle) when is_map(bundle) do
    Enum.map(source_records(bundle), fn record ->
      Atom.to_string(record.source) <> ":" <> record.identity
    end)
  end

  def source_item_refs(_bundle), do: []

  @doc false
  def refs_digest(refs) when is_list(refs) do
    refs
    |> Enum.sort()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

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

  defp run_todo_decisions(account, bundle, opts) do
    now = Keyword.get(opts, :now, parse_datetime(bundle["fetched_at"]) || DateTime.utc_now())
    candidates = todo_candidates(account, bundle)
    source_refs = Enum.map(candidates, & &1["source_ref"])

    intelligence_opts =
      [
        exact_decisions: true,
        existing_limit: 80,
        now: now,
        semantic_dedupe: false,
        source: "source_account_discovery"
      ]
      |> maybe_put_llm_complete(opts)

    with true <- candidates != [] and length(candidates) == length(source_item_refs(bundle)),
         {:ok, result} <- Todos.ingest_many(account.user_id, candidates, intelligence_opts),
         decisions when is_list(decisions) <- Map.get(result, :decisions),
         indexes <- decisions |> Enum.map(&Map.get(&1, :candidate_index)) |> Enum.sort(),
         true <- indexes == Enum.to_list(0..(length(candidates) - 1)),
         decision_refs <- Enum.map(decisions, &Enum.at(source_refs, &1.candidate_index)),
         true <- Enum.sort(decision_refs) == Enum.sort(source_refs) do
      {:ok,
       %{
         outcome: "evaluated",
         model_calls: 1,
         todo_count: length(Map.get(result, :todos, [])),
         skipped_count: Map.get(result, :skipped_count, 0),
         decision_count: length(decisions),
         decision_refs: decision_refs
       }}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :source_discovery_incomplete_decisions}
    end
  end

  defp maybe_put_llm_complete(intelligence_opts, opts) do
    case Keyword.get(opts, :llm_complete) do
      fun when is_function(fun, 1) -> Keyword.put(intelligence_opts, :llm_complete, fun)
      _other -> intelligence_opts
    end
  end

  defp todo_candidates(account, bundle) do
    account_label = source_account_label(account)

    bundle
    |> source_records()
    |> Enum.map(fn record ->
      source = Atom.to_string(record.source)
      source_ref = source <> ":" <> record.identity
      item = record.item

      %{
        "source_ref" => source_ref,
        "source" => source,
        "kind" => if(source == "gmail", do: "gmail_triage", else: "general"),
        "title" => candidate_title(record),
        "summary" => candidate_summary(record),
        "next_action" => "Decide from the supplied source evidence whether you need to act.",
        "source_account_id" => account.id,
        "source_account_label" => account_label,
        "source_item_id" => source_item_id(record),
        "source_occurred_at" => source_occurred_at(record),
        "dedupe_key" => "source-discovery:#{account.id}:#{short_digest(source_ref)}",
        "metadata" => %{
          "source_ref" => source_ref,
          "source_record" => item,
          "source_roles" => record.roles |> MapSet.to_list() |> Enum.map(&Atom.to_string/1)
        }
      }
    end)
  end

  defp candidate_title(%{source: :gmail, item: item}),
    do: read_string(item, "subject") || "New Gmail message"

  defp candidate_title(%{source: :slack, item: item}),
    do:
      read_string(item, "channel_name") || read_string(item, "channel_id") || "New Slack message"

  defp candidate_summary(%{source: :gmail, item: item}) do
    (read_string(item, "body_text") || read_string(item, "text_body") ||
       read_string(item, "body") || read_string(item, "snippet") || "Gmail message")
    |> candidate_excerpt()
  end

  defp candidate_summary(%{source: :slack, item: item}) do
    (read_string(item, "text_resolved") || read_string(item, "text") || "Slack message")
    |> candidate_excerpt()
  end

  defp candidate_excerpt(value), do: String.slice(value, 0, 1_000)

  defp source_item_id(%{source: :gmail, item: item}),
    do: read_string(item, "message_id") || read_string(item, "id")

  defp source_item_id(%{source: :slack, item: item}) do
    channel_id = read_string(item, "channel_id")
    ts = read_string(item, "ts")
    if channel_id && ts, do: channel_id <> ":" <> ts
  end

  defp source_occurred_at(%{source: :gmail, item: item}) do
    item
    |> Map.get("internal_date", Map.get(item, "date"))
    |> normalize_source_datetime(:millisecond)
  end

  defp source_occurred_at(%{source: :slack, item: item}) do
    item
    |> Map.get("date", Map.get(item, "ts"))
    |> normalize_source_datetime(:second)
  end

  defp normalize_source_datetime(%DateTime{} = value, _unit), do: DateTime.to_iso8601(value)

  defp normalize_source_datetime(value, unit) when is_integer(value) do
    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _other -> nil
    end
  end

  defp normalize_source_datetime(value, unit) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.to_iso8601(datetime)

      _other ->
        case Float.parse(value) do
          {number, ""} ->
            normalize_source_datetime(round(number * unit_multiplier(unit)), :microsecond)

          _invalid ->
            nil
        end
    end
  end

  defp normalize_source_datetime(_value, _unit), do: nil

  defp unit_multiplier(:second), do: 1_000_000
  defp unit_multiplier(:millisecond), do: 1_000

  defp source_account_label(%ConnectedAccount{metadata: metadata, provider: provider}) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    read_string(metadata, "account_email") || read_string(metadata, "team_name") || provider
  end

  defp short_digest(value) do
    :crypto.hash(:sha256, value)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 24)
  end

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

  defp build_compact_bundle(bundle) do
    %{
      "trigger" => Map.get(bundle, "trigger"),
      "fetched_at" => Map.get(bundle, "fetched_at"),
      "freshness" => SourceBundle.freshness(bundle),
      "source_scope" => SourceBundle.source_scope(bundle),
      "gmail" => %{
        "messages" => SourceBundle.gmail_messages(bundle),
        "inbox_messages" => SourceBundle.gmail_inbox_messages(bundle),
        "sent_messages" => SourceBundle.gmail_sent_messages(bundle),
        "messages_by_provider" => %{}
      },
      "calendar" => %{"events" => [], "events_by_provider" => %{}},
      "slack" => %{
        "workspaces" => [],
        "messages" => SourceBundle.slack_messages(bundle),
        "mentions" => SourceBundle.slack_mentions(bundle)
      }
    }
  end

  defp compact_partition(bundle, records) do
    partition = partition_source_bundle(bundle, records)
    compact_bundle(partition)
  end

  defp partition_source_bundle(bundle, records) do
    gmail_records = Enum.filter(records, &(&1.source == :gmail))
    slack_records = Enum.filter(records, &(&1.source == :slack))

    %{
      "trigger" => Map.get(bundle, "trigger"),
      "fetched_at" => Map.get(bundle, "fetched_at"),
      "freshness" => SourceBundle.freshness(bundle),
      "source_scope" => SourceBundle.source_scope(bundle),
      "gmail" => %{
        "messages" => Enum.map(gmail_records, & &1.item),
        "inbox_messages" =>
          gmail_records |> Enum.filter(&MapSet.member?(&1.roles, :inbox)) |> Enum.map(& &1.item),
        "sent_messages" =>
          gmail_records |> Enum.filter(&MapSet.member?(&1.roles, :sent)) |> Enum.map(& &1.item),
        "messages_by_provider" => %{}
      },
      "calendar" => %{"events" => [], "events_by_provider" => %{}},
      "slack" => %{
        "workspaces" => [],
        "messages" => Enum.map(slack_records, & &1.item),
        "mentions" =>
          slack_records
          |> Enum.filter(&MapSet.member?(&1.roles, :mention))
          |> Enum.map(& &1.item)
      }
    }
  end

  defp source_records(bundle) do
    gmail_inbox_ids = bundle |> SourceBundle.gmail_inbox_messages() |> identity_set(:gmail)
    gmail_sent_ids = bundle |> SourceBundle.gmail_sent_messages() |> identity_set(:gmail)
    slack_mention_ids = bundle |> SourceBundle.slack_mentions() |> identity_set(:slack)

    gmail =
      (SourceBundle.gmail_messages(bundle) ++
         SourceBundle.gmail_inbox_messages(bundle) ++
         SourceBundle.gmail_sent_messages(bundle))
      |> unique_source_items(:gmail)
      |> Enum.map(fn {identity, item} ->
        roles =
          MapSet.new()
          |> maybe_put_role(:inbox, MapSet.member?(gmail_inbox_ids, identity))
          |> maybe_put_role(:sent, MapSet.member?(gmail_sent_ids, identity))

        %{source: :gmail, identity: identity, item: item, roles: roles}
      end)

    slack =
      (SourceBundle.slack_messages(bundle) ++ SourceBundle.slack_mentions(bundle))
      |> unique_source_items(:slack)
      |> Enum.map(fn {identity, item} ->
        roles =
          maybe_put_role(MapSet.new(), :mention, MapSet.member?(slack_mention_ids, identity))

        %{source: :slack, identity: identity, item: item, roles: roles}
      end)

    gmail ++ slack
  end

  defp grouped_source_records(records) do
    {order, groups} =
      Enum.reduce(records, {[], %{}}, fn record, {order, groups} ->
        key = source_group_identity(record)

        if Map.has_key?(groups, key) do
          {order, Map.update!(groups, key, &(&1 ++ [record]))}
        else
          {order ++ [key], Map.put(groups, key, [record])}
        end
      end)

    Enum.map(order, &Map.fetch!(groups, &1))
  end

  defp source_group_identity(%{source: :gmail, identity: identity, item: item}) do
    provider = read_string(item, "google_provider") || "unknown"
    {:gmail, provider, read_string(item, "thread_id") || identity}
  end

  defp source_group_identity(%{source: :slack, identity: identity, item: item}) do
    {:slack, read_string(item, "team_id"), read_string(item, "channel_id"),
     read_string(item, "thread_ts") || read_string(item, "ts") || identity}
  end

  defp pack_source_groups(groups, limit) do
    {partitions, current} =
      Enum.reduce(groups, {[], []}, fn group, {partitions, current} ->
        cond do
          current == [] ->
            {partitions, group}

          length(current) + length(group) <= limit ->
            {partitions, current ++ group}

          true ->
            {partitions ++ [current], group}
        end
      end)

    if current == [], do: partitions, else: partitions ++ [current]
  end

  defp source_identities_complete?(bundle) do
    gmail_items =
      SourceBundle.gmail_messages(bundle) ++
        SourceBundle.gmail_inbox_messages(bundle) ++ SourceBundle.gmail_sent_messages(bundle)

    slack_items = SourceBundle.slack_messages(bundle) ++ SourceBundle.slack_mentions(bundle)

    Enum.all?(gmail_items, &(is_map(&1) and not is_nil(source_identity(&1, :gmail)))) and
      Enum.all?(slack_items, &(is_map(&1) and not is_nil(source_identity(&1, :slack))))
  end

  defp identity_set(items, source) do
    items
    |> unique_source_items(source)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp unique_source_items(items, source) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.reduce([], fn item, acc ->
      case source_identity(item, source) do
        nil -> acc
        identity -> [{identity, item} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp source_identity(item, :gmail) do
    provider = read_string(item, "google_provider") || "unknown"
    id = read_string(item, "message_id") || read_string(item, "id")
    if id, do: provider <> ":" <> id
  end

  defp source_identity(item, :slack) do
    team_id = read_string(item, "team_id")
    channel_id = read_string(item, "channel_id")
    ts = read_string(item, "ts")
    if team_id && channel_id && ts, do: Enum.join([team_id, channel_id, ts], ":")
  end

  defp maybe_put_role(roles, role, true), do: MapSet.put(roles, role)
  defp maybe_put_role(roles, _role, false), do: roles

  defp validate_child_results(
         child_results,
         expected_fanouts,
         expected_source_items,
         expected_source_refs_digest
       ) do
    indexes =
      child_results
      |> Enum.map(&result_integer(&1, "fanout_index"))
      |> Enum.sort()

    decision_count = Enum.sum(Enum.map(child_results, &result_integer(&1, "decision_count")))
    source_items = Enum.sum(Enum.map(child_results, &result_integer(&1, "source_items")))
    decision_refs = Enum.flat_map(child_results, &result_string_list(&1, "decision_refs"))

    if length(child_results) == expected_fanouts and indexes == Enum.to_list(1..expected_fanouts) and
         decision_count == expected_source_items and source_items == expected_source_items and
         length(decision_refs) == expected_source_items and
         length(Enum.uniq(decision_refs)) == expected_source_items and
         refs_digest(decision_refs) == expected_source_refs_digest do
      :ok
    else
      {:error, :source_discovery_incomplete_decisions}
    end
  end

  defp result_integer(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, existing_atom(key), 0)) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp result_integer(_result, _key), do: 0

  defp result_string_list(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, existing_atom(key), [])) do
      values when is_list(values) -> Enum.filter(values, &(is_binary(&1) and &1 != ""))
      _other -> []
    end
  end

  defp result_string_list(_result, _key), do: []

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

  defp validate_watermarks([%{"account_id" => account_id, "kind" => kind, "value" => value}])
       when is_integer(account_id) and kind in @allowed_watermark_kinds and is_binary(value) and
              value != "",
       do: :ok

  defp validate_watermarks(_watermarks), do: {:error, :source_discovery_watermark_invalid}

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

  defp fetch_list(map, key, default \\ :missing) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      :error when is_list(default) -> {:ok, default}
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
