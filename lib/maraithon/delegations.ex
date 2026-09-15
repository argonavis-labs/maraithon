defmodule Maraithon.Delegations do
  @moduledoc "User-authorised conversations attached to existing todos."
  import Ecto.Query
  alias Maraithon.{Repo, DurablePayload}
  alias Maraithon.Delegations.{Delegation, Grant, Gates, Scope, Lifecycle, Outbox}
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Todos.{Todo, Workflow}
  alias Maraithon.TelegramAssistant.PreparedAction

  def preview(user_id, todo_id, attrs \\ %{}) do
    with true <- Gates.enabled?(user_id),
         {:ok, _} <- Ecto.UUID.cast(todo_id),
         %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id) do
      Scope.preview(todo, attrs)
    else
      false -> {:error, :delegations_disabled}
      _ -> {:error, :todo_not_found}
    end
  end

  def delegate(user_id, todo_id, attrs) when is_map(attrs) do
    request_hash = Scope.hash(%{"todo_id" => todo_id, "action" => "delegate", "attrs" => attrs})

    with true <- valid_request?(attrs),
         :new <- replay(user_id, attrs["request_id"], request_hash),
         {:ok, scope} <- preview(user_id, todo_id, attrs),
         true <- attrs["scope_hash"] == scope["scope_hash"] do
      transaction(user_id, fn ->
        case replay(user_id, attrs["request_id"], request_hash) do
          :new -> create!(user_id, todo_id, attrs, scope, request_hash)
          {:ok, row} -> row
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> after_control(user_id)
    else
      {:ok, row} -> {:ok, row}
      {:error, _} = error -> error
      _ -> {:error, :scope_changed}
    end
  end

  def pause(user_id, id, attrs), do: control(user_id, id, "pause", attrs)
  def resume(user_id, id, attrs), do: control(user_id, id, "resume", attrs)
  def take_over(user_id, id, attrs), do: control(user_id, id, "take_over", attrs)
  def stop(user_id, id, attrs), do: control(user_id, id, "stop", attrs)

  def answer(user_id, id, answer, attrs),
    do: control(user_id, id, "answer", Map.put(attrs, "answer", answer))

  def get(user_id, id) do
    with {:ok, _} <- Ecto.UUID.cast(id) do
      Repo.get_by(Delegation, id: id, user_id: user_id) |> Delegation.hydrate()
    else
      _ -> nil
    end
  end

  def for_todos(user_id, ids) when is_list(ids) do
    Repo.all(
      from d in Delegation,
        where: d.user_id == ^user_id and d.todo_id in ^ids,
        distinct: d.todo_id,
        order_by: [asc: d.todo_id, desc: d.inserted_at]
    )
    |> Map.new(fn row -> {row.todo_id, Delegation.hydrate(row)} end)
  end

  def collection_version(user_id) do
    Repo.one(
      from d in Delegation,
        where: d.user_id == ^user_id,
        select: {count(d.id), max(d.updated_at)}
    )
  end

  def for_todo(user_id, todo_id), do: Map.get(for_todos(user_id, [todo_id]), todo_id)

  @doc "Delegated todos use their conversation ledger instead of an automatic brief or reply draft."
  def attached?(%Todo{user_id: user_id, id: todo_id}),
    do: Repo.exists?(from d in Delegation, where: d.user_id == ^user_id and d.todo_id == ^todo_id)

  def available?(todo),
    do:
      Gates.enabled?(todo.user_id) and todo.status in ~w(open snoozed) and
        todo.source in ~w(gmail slack) and is_integer(todo.source_account_id)

  def current_grant(%Delegation{} = d),
    do:
      Repo.get_by!(Grant, id: d.current_grant_id, delegation_id: d.id, user_id: d.user_id)
      |> Grant.hydrate()

  def summary(nil), do: nil

  def summary(%Delegation{} = d) do
    data = d.data || %{}
    identity = data["identity"] || %{}
    sends? = Gates.sends_enabled?(d.user_id, d.provider)

    %{
      "id" => d.id,
      "state" => d.state,
      "actor" => d.actor,
      "revision" => d.revision,
      "actor_label" =>
        if(d.actor == "as_user",
          do: "As you",
          else: "#{identity["display_name"] || "Your assistant"}, as your assistant"
        ),
      "status_line" => status_line(d, sends?),
      "waiting_for" => data["counterparty_label"],
      "last_action" => data["last_action"],
      "next_follow_up" => iso(d.follow_up_at),
      "next_wake_at" => iso(d.next_wake_at),
      "question" => data["question"],
      "controls" => controls(d.state),
      "evidence" => data["evidence"] || [],
      "sends_enabled" => sends?,
      "task_owner" => data["task_owner"],
      "hold_reason" => data["hold_reason"]
    }
  end

  def changed(%Delegation{} = d) do
    Phoenix.PubSub.broadcast(
      Maraithon.PubSub,
      "delegations:#{d.user_id}",
      {:delegation_changed, d.id}
    )

    :ok
  end

  defp create!(user_id, todo_id, attrs, scope, request_hash) do
    todo =
      Repo.one!(
        from t in Todo, where: t.id == ^todo_id and t.user_id == ^user_id, lock: "FOR UPDATE"
      )

    if Scope.todo_fingerprint(todo) != scope["todo_fingerprint"] or
         attrs["expected_revision"] != Workflow.current(todo)["revision"],
       do: Repo.rollback(:todo_changed)

    if Repo.exists?(
         from d in Delegation,
           where:
             d.todo_id == ^todo_id and d.user_id == ^user_id and
               d.state not in ^Delegation.terminal_states()
       ),
       do: Repo.rollback(:already_delegated)

    now = DatabaseClock.now!()

    d =
      %Delegation{user_id: user_id}
      |> Delegation.changeset(%{
        todo_id: todo_id,
        kind: scope["kind"],
        actor: scope["actor"],
        provider: scope["provider"],
        connected_account_id: scope["identity"]["account_id"],
        provider_thread_id: scope["thread_id"],
        slack_channel: scope["channel"],
        workflow_revision: scope["workflow_revision"],
        next_wake_at: now,
        data:
          Map.take(
            scope,
            ~w(identity counterparty_label counterparty_id outcome task_owner evidence)
          )
      })
      |> Repo.insert!()

    grant = insert_grant!(d, 1, "active", scope, attrs["request_id"], request_hash)
    d = d |> Delegation.changeset(%{current_grant_id: grant.id}) |> Repo.update!()

    Outbox.append!(
      d,
      "user_action",
      "user:#{attrs["request_id"]}",
      %{"action" => "start", "grant_version" => 1},
      %{occurred_at: now}
    )

    d
  end

  def control(user_id, id, action, attrs)
      when action in ~w(pause resume take_over stop answer) and is_map(attrs) do
    request_hash = Scope.hash(%{"id" => id, "action" => action, "attrs" => attrs})

    with true <- valid_request?(attrs), {:ok, _} <- Ecto.UUID.cast(id) do
      transaction(user_id, fn ->
        case replay(user_id, attrs["request_id"], request_hash) do
          {:ok, row} ->
            row

          {:error, reason} ->
            Repo.rollback(reason)

          :new ->
            d =
              Repo.one(
                from d in Delegation,
                  where: d.id == ^id and d.user_id == ^user_id,
                  lock: "FOR UPDATE"
              )
              |> Delegation.hydrate()

            if is_nil(d), do: Repo.rollback(:not_found)

            if d.revision != attrs["expected_revision"],
              do: Repo.rollback({:conflict, summary(d)})

            if action not in controls(d.state), do: Repo.rollback(:invalid_control)
            grant = current_grant(d)
            scope = answer_scope!(grant.data["scope"], d, action, attrs)
            state = control_state(d, action)

            control =
              if action == "stop",
                do: "revoked",
                else: if(state == "paused", do: "paused", else: "active")

            next_grant =
              insert_grant!(
                d,
                grant.version + 1,
                control,
                scope,
                attrs["request_id"],
                request_hash
              )

            now = DatabaseClock.now!()
            data = Map.drop(d.data, ~w(question hold_reason))

            data =
              if d.state in ~w(sending reconciling),
                do: Map.put(data, "hold_reason", "send_may_be_in_flight"),
                else: data

            changed =
              d
              |> Delegation.changeset(%{
                state: state,
                current_grant_id: next_grant.id,
                revision: d.revision + 1,
                next_wake_at: if(state in ~w(ready reconciling), do: now),
                data: data
              })
              |> Repo.update!()

            entered? = Maraithon.Delegations.Actions.supersede_unentered!(d)

            changed =
              if not entered? and changed.data["hold_reason"] == "send_may_be_in_flight" do
                changed
                |> Delegation.changeset(%{data: Map.delete(changed.data, "hold_reason")})
                |> Repo.update!()
              else
                changed
              end

            Outbox.append!(
              changed,
              "user_action",
              "user:#{attrs["request_id"]}",
              %{"action" => action, "grant_version" => next_grant.version},
              %{occurred_at: now}
            )

            changed
        end
      end)
      |> after_control(user_id)
    else
      _ -> {:error, :invalid_control_request}
    end
  end

  def control(_, _, _, _), do: {:error, :invalid_control_request}

  defp insert_grant!(d, version, control, scope, request_id, request_hash) do
    %Grant{user_id: d.user_id}
    |> Grant.changeset(%{
      delegation_id: d.id,
      version: version,
      origin_request_id: request_id,
      control_state: control,
      data: %{"scope" => scope, "scope_hash" => Scope.hash(scope), "request_hash" => request_hash}
    })
    |> Repo.insert!()
  end

  defp answer_scope!(scope, d, "answer", attrs) do
    answer = attrs["answer"]

    if not is_binary(answer) or String.trim(answer) == "" or byte_size(answer) > 2_000,
      do: Repo.rollback(:invalid_answer)

    answers =
      (scope["user_answers"] || []) ++ [%{"question" => d.data["question"], "answer" => answer}]

    if length(answers) > 20, do: Repo.rollback(:answer_history_full)
    Map.put(scope, "user_answers", answers)
  end

  defp answer_scope!(scope, _, _, _), do: scope

  defp control_state(_, action) when action in ~w(pause take_over), do: "paused"
  defp control_state(_, "stop"), do: "stopped"

  defp control_state(d, _) do
    if d.last_action_id &&
         Repo.exists?(
           from a in PreparedAction,
             where:
               a.id == ^d.last_action_id and a.user_id == ^d.user_id and
                 a.status in ~w(confirmed execution_unknown)
         ),
       do: "reconciling",
       else: "ready"
  end

  defp replay(user_id, request_id, request_hash) do
    case Repo.get_by(Grant, user_id: user_id, origin_request_id: request_id) |> Grant.hydrate() do
      nil ->
        :new

      grant ->
        if grant.data["request_hash"] == request_hash,
          do: {:ok, get(user_id, grant.delegation_id)},
          else: {:error, :request_conflict}
    end
  end

  defp transaction(user_id, fun),
    do:
      Repo.transaction(fn ->
        if job = Maraithon.AssistantChat.Execution.capture_authority(),
          do: Maraithon.Runtime.JobAuthority.fence!(job)

        DurablePayload.require_current_mutation!()
        WriteFence.lock_user_writable!(user_id)
        fun.()
      end)

  defp after_control({:ok, d}, user_id) do
    job = Maraithon.AssistantChat.Execution.capture_authority()
    _ = Lifecycle.ensure(user_id, if(job, do: [job: job], else: []))
    changed(d)
    {:ok, get(user_id, d.id)}
  end

  defp after_control(error, _), do: error

  defp valid_request?(attrs),
    do:
      is_map(attrs) and is_binary(attrs["request_id"]) and
        byte_size(attrs["request_id"]) in 1..200 and is_integer(attrs["expected_revision"]) and
        attrs["expected_revision"] >= 0

  defp controls("paused"), do: ~w(resume stop)
  defp controls("needs_user"), do: ~w(answer pause take_over stop)
  defp controls(state) when state in ~w(completed stopped expired), do: []
  defp controls(_), do: ~w(pause take_over stop)
  defp iso(nil), do: nil
  defp iso(dt), do: DateTime.to_iso8601(dt)

  defp status_line(%{schema_version: version}, _) when version != 1,
    do: "Waiting for an app update"

  defp status_line(%{state: state}, _) when state in ~w(completed stopped expired paused),
    do: String.capitalize(state)

  defp status_line(_, false), do: "Sends are off"

  defp status_line(%{data: %{"hold_reason" => "execution_not_ready"}}, _),
    do: "Waiting for sending to be available"

  defp status_line(%{state: "waiting_reply", data: data}, _),
    do: "Waiting for #{data["counterparty_label"] || "a reply"}"

  defp status_line(%{state: "needs_user"}, _), do: "Needs your decision"

  defp status_line(%{state: "waiting_capacity", data: %{"hold_reason" => reason}}, _)
       when reason in ~w(rate_limited llm_busy),
       do: "Model is busy. Retrying automatically."

  defp status_line(%{state: "waiting_capacity"}, _), do: "Waiting for capacity"
  defp status_line(%{state: "reconciling"}, _), do: "Checking whether the message was sent"
  defp status_line(_, _), do: "Maraithon is working on this"
end
