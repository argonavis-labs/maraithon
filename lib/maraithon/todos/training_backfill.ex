defmodule Maraithon.Todos.TrainingBackfill do
  @moduledoc """
  Resumable, user-scoped import of retained history. No model calls, todo
  mutations, or preference-learning jobs are produced by a backfill.

  Source event time and import time remain distinct. Missing decision-time
  prompts and mutable historical todo text are explicitly marked as missing.
  Deterministic identities make every import safe to repeat after interruption.
  """
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Runtime.{BackgroundJob, SourceAccountDiscovery}

  alias Maraithon.Todos.{
    ActivityEvent,
    Todo,
    TodoLearningEvent,
    TrainingDataset,
    TrainingExample,
    TrainingFeedback,
    TrainingRun
  }

  @job_types ~w(runtime_partition:source_account_discovery_reason runtime_partition:todo_ingestion)
  @missing ~w(original_prompt original_model_identity original_preference_context)

  @doc "Imports a bounded page of old completed jobs. Repeat with next_cursor until complete."
  def jobs(user_id, %DateTime{} = before, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100) |> max(1) |> min(500)

    query =
      from j in BackgroundJob,
        where:
          j.user_id == ^user_id and j.job_type in ^@job_types and
            j.status == "completed" and j.completed_at < ^before,
        order_by: [asc: j.id],
        limit: ^limit

    query =
      case Keyword.get(opts, :cursor) do
        nil -> query
        id -> where(query, [j], j.id > ^id)
      end

    rows = Repo.all(query)

    accounts =
      Repo.all(from a in ConnectedAccount, where: a.user_id == ^user_id) |> Map.new(&{&1.id, &1})

    counts =
      Enum.reduce(rows, %{}, fn job, acc ->
        result = import_job(job, accounts)
        Map.update(acc, result, 1, &(&1 + 1))
      end)

    %{
      scanned: length(rows),
      counts: counts,
      complete: length(rows) < limit,
      next_cursor: if(rows != [], do: List.last(rows).id)
    }
  end

  @doc "Imports saved todos and action history in small independent transactions."
  def history(user_id, %DateTime{} = before) do
    todos = Repo.all(from t in Todo, where: t.user_id == ^user_id and t.inserted_at < ^before)
    Enum.each(todos, &import_todo/1)
    todo_map = Map.new(todos, &{&1.id, &1})

    learning =
      Repo.all(
        from e in TodoLearningEvent, where: e.user_id == ^user_id and e.inserted_at < ^before
      )

    activity_count = import_activity_pages(user_id, before, todo_map, learning, nil, 0)

    Enum.each(learning, fn event ->
      # The activity row is the canonical label when both record the same action.
      type = if(event.resolution_status == "done", do: "marked_done", else: "deleted")
      start = DateTime.add(event.inserted_at, -2, :second)
      stop = DateTime.add(event.inserted_at, 2, :second)

      matched =
        Repo.exists?(
          from a in ActivityEvent,
            where:
              a.user_id == ^user_id and a.todo_id == ^event.todo_id and
                a.actor_type == "user" and a.event_type == ^type and
                a.occurred_at >= ^start and a.occurred_at <= ^stop and a.occurred_at < ^before
        )

      unless matched do
        todo = Map.get(todo_map, event.todo_id)
        name = if(event.resolution_status == "done", do: "completed", else: "dismissed")

        feedback!(
          user_id,
          "learning_event:#{event.id}",
          todo && todo.id,
          name,
          "user",
          event.inserted_at,
          %{
            input_kind: "historical_learning_event",
            original_title: nil,
            learning: learning_snapshot(event),
            current_todo: if(todo, do: TrainingDataset.snapshot(todo)),
            missing: ["decision_time_snapshot", "event_time_todo_text"],
            current_text_is_not_historical: true
          }
        )
      end
    end)

    Enum.each(todos, &import_explicit_feedback(&1, before))

    %{
      todos_scanned: length(todos),
      activity_scanned: activity_count,
      learning_scanned: length(learning),
      totals: counts(user_id)
    }
  end

  def counts(user_id) do
    %{
      runs:
        Repo.aggregate(
          from(r in TrainingRun, where: r.user_id == ^user_id and r.origin == "backfill"),
          :count
        ),
      examples:
        Repo.aggregate(
          from(e in TrainingExample, where: e.user_id == ^user_id and e.origin == "backfill"),
          :count
        ),
      feedback:
        Repo.all(
          from f in TrainingFeedback,
            where: f.user_id == ^user_id and f.origin == "backfill",
            group_by: [f.actor, f.label],
            select: %{actor: f.actor, label: f.label, count: count(f.id)}
        )
    }
  end

  defp import_job(%BackgroundJob{payload_purged_at: time}, _) when not is_nil(time), do: :purged

  defp import_job(job, accounts) do
    key = "background_job:#{job.id}"

    if Repo.exists?(
         from r in TrainingRun, where: r.user_id == ^job.user_id and r.source_key == ^key
       ) do
      :already_imported
    else
      job = BackgroundJob.hydrate_payloads(job)

      case candidates(job, accounts) do
        {:ok, []} ->
          :empty_inputs

        {:ok, candidates} ->
          manifest = Map.get(job.result || %{}, "decision_manifest", [])
          by_ref = Map.new(manifest, &{&1["source_ref"], &1})

          inputs =
            Enum.map(candidates, fn candidate ->
              decision = Map.get(by_ref, candidate["source_ref"])
              todo_id = decision && owned_todo_id(job.user_id, decision["persisted_todo_id"])
              %{candidate: candidate, decision: decision, todo_id: todo_id}
            end)

          run!(job.user_id, key, job.completed_at, inputs, %{
            input_kind: "historical_source_handoff",
            source_job_id: job.id,
            source_job_type: job.job_type,
            source_acquired_at: job.inserted_at,
            projection_version: 1,
            missing: @missing,
            source_bundle: (job.payload || %{})["source_bundle"],
            recorded_result: job.result,
            human_label: "unknown"
          })

          :imported

        {:error, :assistant_account_excluded} ->
          :assistant_account_excluded

        {:error, reason} ->
          raise "historical source projection failed: #{inspect(reason)}"
      end
    end
  end

  defp candidates(
         %BackgroundJob{job_type: "runtime_partition:todo_ingestion", payload: payload},
         _
       ),
       do: {:ok, Map.get(payload || %{}, "candidates", [])}

  defp candidates(job, accounts) do
    case Map.get(accounts, (job.payload || %{})["account_id"]) do
      nil -> {:error, :historical_account_missing}
      account -> SourceAccountDiscovery.historical_candidates(account, job.payload)
    end
  end

  defp import_todo(todo) do
    key = "todo:#{todo.id}"

    input = %{
      candidate: nil,
      decision: nil,
      todo_id: todo.id,
      saved_todo: TrainingDataset.snapshot(todo)
    }

    run!(todo.user_id, key, todo.inserted_at, [input], %{
      input_kind: "historical_todo_snapshot",
      current_text_is_not_historical: true,
      original_todo_created_at: todo.inserted_at,
      snapshot_observed_at: DateTime.utc_now(),
      missing: @missing ++ ["original_candidate", "original_decision"],
      human_label: "unknown"
    })
  end

  defp run!(user_id, key, occurred_at, inputs, context) do
    id = stable_id(user_id, key)

    Repo.transaction(fn ->
      if is_nil(Repo.get(TrainingRun, id)) do
        now = DateTime.utc_now()
        payload = TrainingDataset.pack(context)

        Repo.insert!(
          %TrainingRun{
            id: id,
            user_id: user_id,
            source_key: key,
            origin: "backfill",
            occurred_at: occurred_at,
            candidate_count: length(inputs),
            status: "applied",
            payload: payload,
            payload_hash: TrainingDataset.digest(payload),
            completed_at: now
          }, on_conflict: :nothing, conflict_target: [:user_id, :source_key])

        # Use insert_all to keep a source batch to one encrypted write roundtrip.
        rows =
          inputs
          |> Enum.with_index()
          |> Enum.map(fn {input, index} ->
            action =
              case input.decision do
                %{"action" => action} when action in ["create", "update", "skip"] -> action
                _ -> "unresolved"
              end

            candidate = input.candidate || input[:saved_todo] || %{}

            payload =
              TrainingDataset.pack(%{
                input_kind: context.input_kind,
                candidate: input.candidate,
                decision: input.decision,
                saved_todo: input[:saved_todo],
                missing: context.missing,
                source_key: key,
                source_evidence_hash: TrainingDataset.digest(candidate),
                current_text_is_not_historical:
                  Map.get(context, :current_text_is_not_historical, false),
                human_label: "unknown"
              })

            %{
              id: stable_id(user_id, "#{key}:#{index}"),
              user_id: user_id,
              run_id: id,
              todo_id: input.todo_id,
              candidate_index: index,
              action: action,
              group_key: TrainingDataset.group_key(user_id, candidate),
              origin: "backfill",
              occurred_at: occurred_at,
              payload: payload,
              payload_hash: TrainingDataset.digest(payload),
              inserted_at: now
            }
          end)

        Repo.insert_all(TrainingExample, rows,
          on_conflict: :nothing,
          conflict_target: [:run_id, :candidate_index]
        )
      end
    end)
    |> ensure_committed!()
  end

  defp import_activity_pages(user_id, before, todos, learning, cursor, total) do
    query =
      from a in ActivityEvent,
        where: a.user_id == ^user_id and a.occurred_at < ^before,
        order_by: [asc: a.id],
        limit: 100

    query = if cursor, do: where(query, [a], a.id > ^cursor), else: query
    rows = Repo.all(query)

    Enum.each(rows, fn event ->
      todo = Map.get(todos, event.todo_id)

      related =
        Enum.find(learning, fn e ->
          e.todo_id == event.todo_id and
            abs(DateTime.diff(e.inserted_at, event.occurred_at, :millisecond)) < 2_000 and
            ((event.event_type == "marked_done" and e.resolution_status == "done") or
               (event.event_type == "deleted" and e.resolution_status == "dismissed"))
        end)

      name =
        case event.event_type do
          "marked_done" -> "completed"
          "deleted" -> "dismissed"
          "created" -> if(event.actor_type == "user", do: "user_created", else: "created")
          other -> other
        end

      feedback!(
        user_id,
        "activity:#{event.id}",
        todo && todo.id,
        name,
        event.actor_type,
        event.occurred_at,
        %{
          input_kind: "historical_activity",
          original_title: event.todo_title,
          original_source: event.todo_source,
          metadata: event.metadata,
          learning: if(related, do: learning_snapshot(related)),
          current_todo: if(todo, do: TrainingDataset.snapshot(todo)),
          current_text_is_not_historical: true,
          missing: ["decision_time_snapshot", "event_time_full_todo"]
        }
      )
    end)

    if length(rows) == 100,
      do:
        import_activity_pages(
          user_id,
          before,
          todos,
          learning,
          List.last(rows).id,
          total + length(rows)
        ),
      else: total + length(rows)
  end

  defp import_explicit_feedback(todo, before) do
    evidence = (todo.metadata || %{})["assistant_feedback"] || %{}

    event =
      %{"see_less" => "ignored", "helpful" => "helpful", "not_helpful" => "not_helpful"}[
        evidence["value"]
      ]

    with name when is_binary(name) <- event,
         {:ok, occurred_at, _} <- DateTime.from_iso8601(evidence["recorded_at"] || ""),
         :lt <- DateTime.compare(occurred_at, before) do
      feedback!(
        todo.user_id,
        "explicit_feedback:#{todo.id}:#{evidence["recorded_at"]}",
        todo.id,
        name,
        "user",
        occurred_at,
        %{
          input_kind: "historical_explicit_feedback",
          evidence: evidence,
          current_todo: TrainingDataset.snapshot(todo),
          current_text_is_not_historical: true,
          missing: ["decision_time_snapshot", "event_time_todo_text"]
        }
      )
    else
      _ -> :ok
    end
  end

  defp feedback!(user_id, key, todo_id, event, actor, occurred_at, payload) do
    {label, strength} =
      cond do
        actor != "user" -> {"unknown", "none"}
        event == "completed" -> {"positive", "implicit"}
        event in ["ignored", "not_helpful"] -> {"negative", "explicit"}
        event == "helpful" -> {"positive", "explicit"}
        event == "user_created" -> {"correction", "explicit"}
        true -> {"unknown", "none"}
      end

    id = stable_id(user_id, key)
    # The legacy snapshot is a reconstruction, never the latest live decision.
    example_id = if todo_id, do: stable_id(user_id, "todo:#{todo_id}:0")
    payload = TrainingDataset.pack(Map.put(payload, :source_key, key))

    Repo.insert!(
      %TrainingFeedback{
        id: id,
        user_id: user_id,
        todo_id: todo_id,
        example_id: example_id,
        origin: "backfill",
        occurred_at: occurred_at,
        event: event,
        actor: actor,
        label: label,
        strength: strength,
        dedupe_key: "backfill:v1:#{key}",
        payload: payload,
        payload_hash: TrainingDataset.digest(payload),
        inserted_at: DateTime.utc_now()
      }, on_conflict: :nothing, conflict_target: [:user_id, :dedupe_key])
  end

  defp learning_snapshot(event),
    do:
      Map.take(event, [
        :id,
        :outcome,
        :signal_strength,
        :resolution_status,
        :opened_before_resolution,
        :surface,
        :status,
        :inserted_at
      ])

  defp owned_todo_id(_user_id, nil), do: nil

  defp owned_todo_id(user_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         true <- Repo.exists?(from t in Todo, where: t.user_id == ^user_id and t.id == ^id),
         do: id,
         else: (_ -> nil)
  end

  defp stable_id(user_id, key) do
    <<bytes::binary-size(16), _::binary>> =
      :crypto.hash(:sha256, "todo-training-backfill:v1:#{user_id}:#{key}")

    {:ok, id} = Ecto.UUID.load(bytes)
    id
  end

  defp ensure_committed!({:ok, _}), do: :ok
  defp ensure_committed!({:error, _}), do: raise("training backfill transaction failed")
end
