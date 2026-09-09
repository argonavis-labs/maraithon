defmodule Maraithon.Todos.ActionHandoff do
  @moduledoc """
  Applies an approved action's planned handoff after its durable success receipt.
  Recovery uses the existing per-user completion sweep, never replays the action,
  and never overwrites a later version of the todo.
  """
  import Ecto.Query
  alias Maraithon.{Repo, Todos}
  alias Maraithon.Todos.{Todo, Workflow}
  alias Maraithon.TelegramAssistant.PreparedAction
  require Logger

  @key "_maraithon_workflow_handoff"
  @supported ~w(gmail_send gmail_draft_send slack_post calendar_create_event calendar_update_event)
  @active ~w(you_own working waiting they_own)

  def prepare(user_id, action_type, payload) do
    case Map.pop(payload, "workflow_transition") do
      {nil, payload} ->
        {:ok, Map.delete(payload, @key)}

      {%{} = attrs, payload} when action_type in @supported ->
        with %Todo{} = todo <- Todos.get_for_user(user_id, payload["todo_id"]),
             true <- attrs["state"] in @active,
             {:ok, workflow} <- Todos.preview_workflow(todo, attrs) do
          plan =
            workflow
            |> Map.take(~w(state next_action reason waiting_until))
            |> Map.put("expected_revision", attrs["expected_revision"])
            |> Map.put("owner", workflow["owner"])
            |> Map.put("outcome", workflow["outcome"])

          {:ok,
           Map.put(payload, @key, %{
             "state" => "pending",
             "plan" => plan,
             "payload_hash" => fingerprint(payload)
           })}
        else
          _ -> {:error, "invalid_workflow_handoff"}
        end

      _ ->
        {:error, "invalid_workflow_handoff"}
    end
  end

  def preview(payload) do
    case get_in(payload, [@key, "plan"]) do
      %{"state" => state, "owner" => owner, "next_action" => next} ->
        "\nAfter this succeeds: #{Workflow.label(state)}. Owner: #{owner["label"]}. #{next}"

      _ ->
        ""
    end
  end

  def recover_for_user(user_id) do
    PreparedAction
    |> where([a], a.user_id == ^user_id and a.status == "executed")
    |> where([a], a.workflow_handoff_state == "pending")
    |> order_by([a], asc: a.executed_at)
    |> limit(20)
    |> Repo.all()
    |> Enum.each(&apply_safely/1)
  end

  def apply_safely(%PreparedAction{} = action) do
    action = PreparedAction.hydrate_payload(action)

    if get_in(action.payload || %{}, [@key, "state"]) == "pending" do
      case apply_handoff(action) do
        {:ok, _} -> :ok
        {:error, reason} -> log_failure(reason)
      end
    else
      :ok
    end
  rescue
    error -> log_failure(error)
  end

  defp apply_handoff(action) do
    Repo.transaction(fn ->
      current =
        PreparedAction
        |> where([a], a.id == ^action.id and a.user_id == ^action.user_id)
        |> lock("FOR UPDATE")
        |> Repo.one()
        |> PreparedAction.hydrate_payload()

      if current && current.status == "executed" &&
           get_in(current.payload || %{}, [@key, "state"]) == "pending" do
        handoff = current.payload[@key]

        result =
          if handoff["payload_hash"] == fingerprint(current.payload) do
            attrs =
              handoff["plan"]
              |> Map.put("request_id", "prepared-action:" <> current.id)
              |> Map.update!(
                "reason",
                &String.slice("Confirmed action completed. " <> &1, 0, 1_800)
              )

            apply_current_transition(current, attrs)
          else
            {:error, :edited_action}
          end

        state =
          case result do
            {:ok, _todo} ->
              "applied"

            {:error, reason}
            when reason in [:stale_workflow, :reopen_workflow_first, :not_found] ->
              "superseded"

            {:error, reason} when reason in [:edited_action, :invalid_workflow_owner] ->
              "needs_review"

            {:error, reason} ->
              Repo.rollback(reason)
          end

        payload = put_in(current.payload, [@key, "state"], state)

        case current |> PreparedAction.changeset(%{payload: payload}) |> Repo.update() do
          {:ok, updated} -> updated
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
  end

  defp apply_current_transition(action, attrs) do
    # Validate expected conflicts under the todo lock before entering the context's
    # nested transaction. An inner Repo.rollback would also roll back the outer
    # applied/superseded marker, leaving the same stale receipt pending forever.
    todo =
      Todo
      |> where([t], t.user_id == ^action.user_id and t.id == ^action.payload["todo_id"])
      |> lock("FOR UPDATE")
      |> Repo.one()

    with %Todo{} <- todo,
         {:ok, _} <- Todos.preview_workflow(todo, attrs) do
      Todos.transition_workflow(action.user_id, todo.id, attrs,
        actor_type: "agent",
        actor_id: action.run_id,
        actor_label: "Maraithon",
        source: "confirmed_action"
      )
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  # Internal receipt/claim fields are added during execution. A user's edit to
  # the actual outbound content invalidates the old semantic handoff proposal.
  defp fingerprint(payload) do
    payload
    |> Enum.reject(fn {key, _} -> String.starts_with?(key, "_maraithon_") end)
    |> Map.new()
    |> Maraithon.AssistantHarness.PromptStability.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp log_failure(reason) do
    Logger.warning("Todo handoff will retry from the durable action receipt",
      failure_code: Maraithon.Redaction.error_class(reason)
    )

    {:error, :handoff_pending}
  end
end
