defmodule Maraithon.Todos.TrainingDataset do
  @moduledoc """
  Versioned, encrypted training evidence collected by ordinary product use.

  Model outputs are observations, never human labels. Human feedback is an
  append-only stream, including reversals; absence of feedback is unknown.
  Writes run in the same transaction as their product mutation. No model call
  or provider availability is required to preserve a label.
  """
  import Ecto.Query
  alias Maraithon.{LLM, Repo}
  alias Maraithon.Todos.{Todo, TrainingExample, TrainingFeedback, TrainingRun}
  require Logger

  @version 1
  @max_payload_bytes 2_000_000
  @snapshot_fields ~w(id user_id source source_account_id source_account_label kind attention_mode title summary next_action due_at notes action_plan action_draft owner_user_id owner_label priority status workflow snoozed_until closed_at model_selected_at first_user_opened_at source_item_id source_occurred_at dedupe_key metadata direction counterparty_person_id counterparty_label inserted_at updated_at)a
  @editable_fields ~w(title summary next_action due_at notes action_plan action_draft priority attention_mode workflow snoozed_until)a

  def with_run(user_id, prompt, candidates, request, fun) do
    payload =
      pack(%{
        version: @version,
        policy: "todo_intelligence_v1",
        prompt: prompt,
        request: Map.delete(request, "messages"),
        configured_model: LLM.model(),
        configured_provider: LLM.provider_name(),
        revision: System.get_env("K_REVISION"),
        input_kind: "decision_time"
      })

    run =
      Repo.insert!(%TrainingRun{
        user_id: user_id,
        occurred_at: DateTime.utc_now(),
        candidate_count: length(candidates),
        payload: payload,
        payload_hash: digest(payload)
      })

    try do
      case fun.(run) do
        {:ok, _} = success ->
          success

        error ->
          finish!(run, "failed", %{error: error_code(error)})
          error
      end
    rescue
      exception ->
        # Preserve the original failure. A failed status write leaves a pending
        # run for the daily reconciliation instead of fabricating success.
        Logger.error("todo training run interrupted", run_id: run.id)
        reraise exception, __STACKTRACE__
    end
  end

  @doc false
  def capture_decisions!(nil, _todos), do: :ok

  def capture_decisions!(
        %{run: run, candidates: candidates, decisions: decisions, provenance: provenance},
        todos
      ) do
    true = Repo.in_transaction?()
    selected = Enum.filter(decisions, &(&1.action in ["create", "update"]))
    saved = Enum.zip(selected, todos) |> Map.new(fn {d, t} -> {d.candidate_index, t} end)
    by_index = Map.new(decisions, &{&1.candidate_index, &1})
    now = DateTime.utc_now()

    candidates
    |> Enum.with_index()
    |> Enum.each(fn {candidate, index} ->
      decision = Map.get(by_index, index)
      todo = Map.get(saved, index)

      payload =
        pack(%{
          candidate: candidate,
          decision: decision,
          saved_todo: if(todo, do: snapshot(todo)),
          input_kind: "decision_time",
          human_label: "unknown"
        })

      Repo.insert!(%TrainingExample{
        user_id: run.user_id,
        occurred_at: now,
        run_id: run.id,
        todo_id: todo && todo.id,
        candidate_index: index,
        action: if(decision, do: decision.action, else: "unresolved"),
        group_key: group_key(run.user_id, candidate),
        payload: payload,
        payload_hash: digest(payload),
        inserted_at: now
      })
    end)

    finish!(run, "applied", provenance)
    :ok
  end

  defp finish!(run, status, result) do
    result = pack(result)
    now = DateTime.utc_now()

    from(r in TrainingRun,
      where: r.id == ^run.id and r.user_id == ^run.user_id and r.status == "pending"
    )
    |> Repo.update_all(
      set: [
        status: status,
        result: result,
        result_hash: digest(result),
        completed_at: now,
        updated_at: now
      ]
    )
  end

  @doc false
  def record_change!(previous, updated, opts) do
    event = change_event(previous, updated, opts)
    if event, do: record!(previous, updated, event, opts)
    :ok
  end

  @doc false
  def record_created!(todo, opts) do
    if user?(opts), do: record!(nil, todo, "user_created", opts)
    :ok
  end

  @doc false
  def record_feedback!(previous, updated, feedback, opts) do
    record!(previous, updated, feedback, opts)
    :ok
  end

  @doc false
  def freeze_learning_input!(event, previous, updated, opts) do
    record!(
      previous,
      updated,
      "learning_input",
      opts |> Keyword.put(:learning_event_id, event.id)
    )

    :ok
  end

  def learning_todo(event) do
    case Repo.get_by(TrainingFeedback, user_id: event.user_id, learning_event_id: event.id) do
      nil ->
        Repo.get_by(Todo, id: event.todo_id, user_id: event.user_id)

      row ->
        payload = verified_payload!(row)
        # Load through Ecto to restore datetimes without creating atoms from
        # externally supplied keys. Historical events retain their old fallback.
        case payload["before"] || payload["after"] do
          nil ->
            nil

          frozen ->
            %Todo{id: event.todo_id, user_id: event.user_id}
            |> Ecto.Changeset.cast(frozen, @snapshot_fields -- [:id, :user_id])
            |> Ecto.Changeset.apply_changes()
        end
    end
  end

  def record_opened(user_id, todo_id, opts) do
    Repo.transaction(fn ->
      todo =
        Repo.one(
          from t in Todo, where: t.user_id == ^user_id and t.id == ^todo_id, lock: "FOR UPDATE"
        )

      if is_nil(todo), do: Repo.rollback(:not_found)

      if user?(opts) do
        record!(todo, todo, "opened", Keyword.put(opts, :observation_day, Date.utc_today()))

        if todo.status in ["triage", "open", "snoozed"] and is_nil(todo.first_user_opened_at) do
          todo
          |> Ecto.Changeset.change(first_user_opened_at: DateTime.utc_now())
          |> Repo.update!()
        end
      end

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  defp record!(previous, todo, event, opts) do
    true = Repo.in_transaction?()
    actor = if user?(opts), do: "user", else: "agent"
    {label, strength} = label(event, actor)
    example = latest_example(todo.user_id, todo.id)

    payload =
      pack(%{
        before: if(previous, do: snapshot(previous)),
        after: snapshot(todo),
        source: Keyword.get(opts, :source) || Keyword.get(opts, :surface),
        note: Keyword.get(opts, :note),
        input_kind: if(example, do: "linked_decision", else: "legacy_or_manual_observation")
      })

    dedupe =
      digest(%{
        todo: todo.id,
        event: event,
        actor: actor,
        version:
          if(event == "opened",
            do: Keyword.get(opts, :observation_day),
            else: previous && previous.updated_at
          ),
        learning_event: Keyword.get(opts, :learning_event_id),
        target:
          if(event == "opened",
            do: nil,
            else: Map.drop(snapshot(todo), ["updated_at", "closed_at"])
          )
      })

    Repo.insert!(
      %TrainingFeedback{
        user_id: todo.user_id,
        occurred_at: DateTime.utc_now(),
        todo_id: todo.id,
        example_id: example && example.id,
        learning_event_id: Keyword.get(opts, :learning_event_id),
        event: event,
        actor: actor,
        label: label,
        strength: strength,
        dedupe_key: dedupe,
        payload: payload,
        payload_hash: digest(payload),
        inserted_at: DateTime.utc_now()
      },
      on_conflict: :nothing,
      conflict_target: [:user_id, :dedupe_key]
    )
  end

  defp latest_example(user_id, todo_id) do
    Repo.one(
      from e in TrainingExample,
        where: e.user_id == ^user_id and e.todo_id == ^todo_id and e.origin == "live",
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
    )
  end

  defp change_event(previous, updated, opts) do
    cond do
      previous.status == "triage" and updated.status == "open" ->
        "accepted"

      previous.status != updated.status and Keyword.get(opts, :relevance_feedback) == :see_less ->
        "ignored"

      previous.status != updated.status and updated.status == "done" ->
        "completed"

      previous.status != updated.status and updated.status == "dismissed" ->
        "dismissed"

      previous.status != updated.status and updated.status == "open" ->
        "reopened"

      previous.status != updated.status and updated.status == "snoozed" ->
        "snoozed"

      Map.take(previous, @editable_fields) != Map.take(updated, @editable_fields) ->
        "edited"

      true ->
        nil
    end
  end

  defp label(_, "agent"), do: {"unknown", "none"}

  defp label(event, "user") when event in ["ignored", "not_helpful", "review_negative"],
    do: {"negative", "explicit"}

  defp label(event, "user") when event in ["accepted", "helpful", "review_positive"],
    do: {"positive", "explicit"}

  defp label("completed", "user"), do: {"positive", "implicit"}

  defp label(event, "user") when event in ["edited", "user_created"],
    do: {"correction", "explicit"}

  defp label(_, _), do: {"unknown", "none"}
  defp user?(opts), do: Keyword.get(opts, :actor_type) in ["user", :user]

  @doc "Explicit review can label a skipped candidate, including a false negative."
  def review(user_id, example_id, verdict, request_id, note \\ nil)

  def review(user_id, example_id, verdict, request_id, note)
      when verdict in ["positive", "negative", "unknown"] do
    with {:ok, _} <- Ecto.UUID.cast(example_id),
         {:ok, _} <- Ecto.UUID.cast(request_id),
         example when not is_nil(example) <-
           Repo.get_by(TrainingExample, id: example_id, user_id: user_id) do
      payload =
        pack(%{
          note: if(is_binary(note), do: String.slice(note, 0, 4000)),
          input_kind: "candidate_review"
        })

      row = %TrainingFeedback{
        user_id: user_id,
        occurred_at: DateTime.utc_now(),
        example_id: example.id,
        todo_id: example.todo_id,
        event: "review_#{verdict}",
        actor: "user",
        label: verdict,
        strength: if(verdict == "unknown", do: "none", else: "explicit"),
        dedupe_key: "review:#{request_id}",
        payload: payload,
        payload_hash: digest(payload),
        inserted_at: DateTime.utc_now()
      }

      Repo.transaction(fn ->
        inserted =
          Repo.insert!(row, on_conflict: :nothing, conflict_target: [:user_id, :dedupe_key])

        stored = Repo.get_by!(TrainingFeedback, user_id: user_id, dedupe_key: row.dedupe_key)

        if stored.example_id != row.example_id or stored.label != row.label or
             stored.payload_hash != row.payload_hash,
           do: Repo.rollback(:request_conflict)

        inserted
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  def review(_, _, _, _, _), do: {:error, :invalid_review}

  @doc "Keyset-paginated portable records. A fixed as_of prevents future label leakage."
  def page(user_id, kind, opts \\ []) when kind in ["runs", "examples", "feedback"] do
    schema =
      %{"runs" => TrainingRun, "examples" => TrainingExample, "feedback" => TrainingFeedback}[
        kind
      ]

    as_of = Keyword.get(opts, :as_of, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 16) |> min(16) |> max(1)

    query =
      from r in schema,
        where: r.user_id == ^user_id and r.inserted_at <= ^as_of,
        order_by: [asc: r.inserted_at, asc: r.id],
        limit: ^limit

    query =
      case Keyword.get(opts, :cursor) do
        {time, id} ->
          where(query, [r], r.inserted_at > ^time or (r.inserted_at == ^time and r.id > ^id))

        nil ->
          query
      end

    rows = Repo.all(query)

    %{
      version: @version,
      kind: kind,
      as_of: as_of,
      records:
        rows
        |> Enum.filter(&Maraithon.Todos.TrainingEligibility.eligible?/1)
        |> Enum.map(&export_record(&1, as_of)),
      excluded_records:
        Enum.count(rows, &(not Maraithon.Todos.TrainingEligibility.eligible?(&1))),
      next_cursor: if(length(rows) == limit, do: encode_cursor(List.last(rows)))
    }
  end

  def decode_cursor(nil), do: {:ok, nil}

  def decode_cursor(cursor) when is_binary(cursor) and byte_size(cursor) < 200 do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [time, id] <- String.split(decoded, "|", parts: 2),
         {:ok, time, _} <- DateTime.from_iso8601(time),
         {:ok, id} <- Ecto.UUID.cast(id),
         do: {:ok, {time, id}},
         else: (_ -> {:error, :invalid_cursor})
  end

  def decode_cursor(_), do: {:error, :invalid_cursor}

  defp encode_cursor(row),
    do: Base.url_encode64("#{DateTime.to_iso8601(row.inserted_at)}|#{row.id}", padding: false)

  defp export_record(%TrainingRun{completed_at: time} = row, as_of) when not is_nil(time) do
    if DateTime.compare(time, as_of) == :gt do
      export_record(%{
        row
        | status: "pending",
          completed_at: nil,
          result: nil,
          result_hash: nil,
          updated_at: row.inserted_at
      })
    else
      export_record(row)
    end
  end

  defp export_record(row, _as_of), do: export_record(row)

  defp export_record(row) do
    payload = verified_payload!(row)

    base =
      row
      |> Map.from_struct()
      |> Map.drop([:__meta__, :payload_hash, :result_hash, :payload, :result])
      |> json_value()

    base =
      base
      |> Map.put("payload", payload)
      |> Map.put("occurred_at", row.occurred_at || row.inserted_at)

    case row do
      %TrainingRun{result: result, result_hash: hash} when not is_nil(result) ->
        if digest(result) != hash, do: raise("training result integrity mismatch")
        Map.put(base, "result", result)

      _ ->
        base
    end
  end

  defp verified_payload!(row) do
    if digest(row.payload) != row.payload_hash, do: raise("training payload integrity mismatch")
    row.payload
  end

  def health(user_id) do
    since = DateTime.add(DateTime.utc_now(), -24, :hour)

    %{
      version: @version,
      label_counts_include_excluded_history: true,
      runs: counts(TrainingRun, user_id, :status, nil),
      decisions: counts(TrainingExample, user_id, :action, nil),
      human_labels: counts(TrainingFeedback, user_id, :label, "user"),
      last_day: %{
        runs: recent_count(TrainingRun, user_id, since),
        examples: recent_count(TrainingExample, user_id, since),
        feedback: recent_count(TrainingFeedback, user_id, since)
      },
      latest_capture_at:
        Repo.one(
          from e in TrainingExample, where: e.user_id == ^user_id, select: max(e.inserted_at)
        ),
      stale_pending:
        Repo.aggregate(
          from(r in TrainingRun,
            where:
              r.user_id == ^user_id and r.status == "pending" and
                r.inserted_at < ^DateTime.add(DateTime.utc_now(), -2, :hour)
          ),
          :count
        )
    }
  end

  defp counts(schema, user_id, field, actor) do
    query =
      from r in schema,
        where: r.user_id == ^user_id,
        group_by: field(r, ^field),
        select: {field(r, ^field), count(r.id)}

    query =
      if actor,
        do: where(query, [r], r.actor == ^actor and r.event != "learning_input"),
        else: query

    Repo.all(query) |> Map.new()
  end

  defp recent_count(schema, user_id, since),
    do:
      Repo.aggregate(
        from(r in schema, where: r.user_id == ^user_id and r.inserted_at >= ^since),
        :count
      )

  @doc "Daily durable recurring job: reconcile interrupted runs and log content-free collection health."
  def daily_health do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -2, :hour)

    stale =
      from r in TrainingRun,
        where: r.status == "pending" and r.inserted_at < ^cutoff,
        order_by: r.inserted_at,
        limit: 500,
        select: r.id

    {abandoned, _} =
      from(r in TrainingRun, where: r.id in subquery(stale))
      |> Repo.update_all(set: [status: "abandoned", completed_at: now, updated_at: now])

    since = DateTime.add(now, -24, :hour)

    report = %{
      abandoned: abandoned,
      failed:
        Repo.aggregate(
          from(r in TrainingRun, where: r.inserted_at >= ^since and r.status == "failed"),
          :count
        ),
      runs: Repo.aggregate(from(r in TrainingRun, where: r.inserted_at >= ^since), :count),
      examples:
        Repo.aggregate(from(e in TrainingExample, where: e.inserted_at >= ^since), :count),
      feedback:
        Repo.aggregate(
          from(f in TrainingFeedback,
            where: f.inserted_at >= ^since and f.event != "learning_input"
          ),
          :count
        )
    }

    if abandoned > 0 or report.failed > 0,
      do: Logger.warning("todo_training_daily_health #{Jason.encode!(report)}"),
      else: Logger.info("todo_training_daily_health #{Jason.encode!(report)}")

    {:ok, report}
  end

  def snapshot(todo), do: todo |> Map.take(@snapshot_fields) |> json_value()

  @doc false
  def group_key(user_id, candidate) do
    metadata = Map.get(candidate, "metadata") || %{}
    source_record = Map.get(metadata, "source_record") || %{}
    # Prefer conversation identity over individual messages. Export consumers
    # must also co-locate shared todo_id and run_id to avoid related-row leakage.
    identity =
      Enum.find_value(
        ~w(gmail_thread_id thread_id slack_thread_ts thread_ts conversation_id),
        &(Map.get(metadata, &1) || Map.get(source_record, &1))
      ) ||
        Map.get(candidate, "source_item_id") || Map.get(candidate, "dedupe_key") ||
        digest(candidate)

    digest([
      user_id,
      candidate["source"],
      candidate["source_account_id"],
      source_record["channel_id"],
      identity
    ])
  end

  @doc false
  def pack(value) do
    value = json_value(value)
    encoded = Jason.encode!(value)

    if byte_size(encoded) <= @max_payload_bytes,
      do: value,
      else: %{
        "snapshot_omitted" => "size_limit",
        "original_bytes" => byte_size(encoded),
        "original_hash" => digest(value)
      }
  end

  @doc false
  def digest(value),
    do:
      :crypto.hash(:sha256, Maraithon.AssistantHarness.PromptStability.encode!(json_value(value)))
      |> Base.encode16(case: :lower)

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_value(%_{} = value), do: value |> Map.from_struct() |> json_value()

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), json_value(v)} end)

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_value()

  defp json_value(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp json_value(value), do: value
  defp error_code({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_), do: "decision_failed"
end
