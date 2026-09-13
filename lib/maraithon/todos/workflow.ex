defmodule Maraithon.Todos.Workflow do
  @moduledoc """
  The todo's outcome state machine. Every state has an owner and a next move.
  PostgreSQL stores the current state and transition history; this pure module
  defines transitions without adding a process or a second execution owner.
  """

  @states ~w(you_own working waiting they_own cancelled done)
  @terminal ~w(cancelled done)
  @labels %{
    "you_own" => "You own the action",
    "working" => "Working",
    "waiting" => "Waiting",
    "they_own" => "They own the action",
    "cancelled" => "Cancelled",
    "done" => "Done"
  }

  def input_schema do
    %{
      "type" => "object",
      "required" => ~w(todo_id state owner expected_revision reason next_action),
      "properties" => %{
        "todo_id" => %{"type" => "string"},
        "state" => %{"type" => "string", "enum" => @states},
        "owner" => %{
          "type" => "object",
          "required" => ["kind"],
          "properties" => %{
            "kind" => %{"type" => "string", "enum" => ["user", "person"]},
            "id" => %{
              "type" => "string",
              "description" =>
                "Verified People ID, required for a person. The runtime supplies the user identity."
            }
          }
        },
        "expected_revision" => %{"type" => "integer", "minimum" => 0},
        "outcome" => %{
          "type" => "string",
          "description" =>
            "The actual goal. Preserve it through intermediate actions. Do not broaden it without user direction or source evidence."
        },
        "next_action" => %{
          "type" => "string",
          "description" => "What this state's owner must do next."
        },
        "reason" => %{
          "type" => "string",
          "description" =>
            "Evidence or explicit user instruction that justifies the change. A draft is not evidence of a send."
        },
        "waiting_until" => %{
          "type" => "string",
          "description" =>
            "Optional ISO-8601 date when a wait should be reviewed. Elapsed time does not prove completion."
        },
        "outcome_confirmed" => %{
          "type" => "boolean",
          "description" => "Required true for done, only after the actual outcome is confirmed."
        },
        "request_id" => %{
          "type" => "string",
          "description" => "Optional stable ID for retrying this exact transition."
        }
      }
    }
  end

  def states, do: @states
  def label(state), do: Map.get(@labels, state, "You own the action")

  def current(todo) do
    stored = Map.get(todo, :workflow) || %{}

    state =
      case Map.get(todo, :status) do
        "done" -> "done"
        "dismissed" -> "cancelled"
        _ -> Map.get(stored, "state") || legacy_state(todo)
      end

    %{
      "state" => state,
      "label" => label(state),
      "owner" => Map.get(stored, "owner") || legacy_owner(todo),
      "outcome" => Map.get(stored, "outcome") || Map.get(todo, :title),
      "next_action" => Map.get(todo, :next_action),
      "reason" => Map.get(stored, "reason"),
      "waiting_until" => Map.get(stored, "waiting_until") || iso(Map.get(todo, :snoozed_until)),
      "revision" => Map.get(stored, "revision", 0),
      "changed_at" => Map.get(stored, "changed_at")
    }
  end

  @doc "Who owns the next move, including accountability while waiting."
  def ball_label(%{"state" => state, "owner" => owner}) do
    user? = owner["kind"] == "user"
    name = if user?, do: "You", else: owner["label"]

    cond do
      state in @terminal -> "Owner: " <> name
      state == "waiting" and user? -> "You own follow-up"
      state == "waiting" -> name <> " owns follow-up"
      user? -> "Your move"
      true -> name <> "’s move"
    end
  end

  def outcome_tracked?(todo), do: is_binary(get_in(Map.get(todo, :workflow) || %{}, ["outcome"]))

  def user_owner(todo) do
    %{
      "kind" => "user",
      "id" => Map.get(todo, :user_id),
      "label" => "You"
    }
  end

  def transition(todo, attrs, owner, now \\ DateTime.utc_now()) do
    current = current(todo)
    state = attrs["state"]
    reason = attrs["reason"]
    outcome = attrs["outcome"] || current["outcome"]
    next_action = attrs["next_action"] || current["next_action"]

    waiting_until =
      case Map.get(attrs, "waiting_until", current["waiting_until"]) do
        "" -> nil
        value -> value
      end

    cond do
      attrs["expected_revision"] != current["revision"] ->
        {:error, :stale_workflow}

      state not in @states ->
        {:error, :invalid_workflow_state}

      current["state"] in @terminal and state not in [current["state"], "you_own"] ->
        {:error, :reopen_workflow_first}

      not valid_owner?(state, owner) ->
        {:error, :invalid_workflow_owner}

      not text?(reason, 2_000) ->
        {:error, :workflow_reason_required}

      not text?(outcome, 2_000) ->
        {:error, :workflow_outcome_required}

      not text?(next_action, 1_000) ->
        {:error, :workflow_next_action_required}

      state == "done" and attrs["outcome_confirmed"] != true ->
        {:error, :outcome_not_confirmed}

      not valid_wait?(waiting_until) ->
        {:error, :invalid_waiting_until}

      true ->
        {:ok,
         %{
           "state" => state,
           "owner" => owner,
           "outcome" => String.trim(outcome),
           "reason" => String.trim(reason),
           "next_action" => String.trim(next_action),
           "waiting_until" => if(state == "waiting", do: waiting_until),
           "revision" => current["revision"] + 1,
           "changed_at" => DateTime.to_iso8601(now)
         }}
    end
  end

  def status("done"), do: "done"
  def status("cancelled"), do: "dismissed"
  def status(_), do: "open"

  def valid?(workflow) when workflow == %{}, do: true

  def valid?(%{"state" => state, "owner" => owner, "revision" => revision} = workflow) do
    state in @states and valid_owner?(state, owner) and is_integer(revision) and revision >= 0 and
      text?(workflow["outcome"], 2_000) and text?(workflow["reason"], 2_000) and
      text?(workflow["next_action"], 1_000) and valid_wait?(workflow["waiting_until"]) and
      is_binary(workflow["changed_at"]) and valid_wait?(workflow["changed_at"]) and
      valid_request_id?(workflow["request_id"])
  end

  def valid?(_), do: false

  def valid_request_id?(nil), do: true
  def valid_request_id?(value), do: text?(value, 128)

  def public(workflow) when is_map(workflow) do
    workflow
    |> Map.take(
      ~w(state label owner outcome next_action reason waiting_until revision changed_at)
    )
    |> Map.update("owner", nil, fn
      owner when is_map(owner) -> Map.take(owner, ~w(kind id label))
      _ -> nil
    end)
    |> Map.put("label", label(workflow["state"]))
  end

  # Compatibility with explicit Done, Cancel and Reopen controls. They record
  # their actor through the existing activity log and retain the outcome.
  def sync_status(changeset) do
    import Ecto.Changeset

    todo = changeset.data
    before = current(todo)
    status = get_field(changeset, :status)

    state =
      case status do
        "done" ->
          "done"

        "dismissed" ->
          "cancelled"

        "snoozed" ->
          "waiting"

        "open" ->
          if before["state"] in @terminal or todo.status == "snoozed",
            do: "you_own",
            else: before["state"]

        _ ->
          before["state"]
      end

    next_action = get_field(changeset, :next_action)

    waiting_until =
      cond do
        status == "snoozed" -> iso(get_field(changeset, :snoozed_until))
        state == "waiting" -> before["waiting_until"]
        true -> nil
      end

    if fetch_change(changeset, :workflow) == :error and outcome_tracked?(todo) and
         (state != before["state"] or next_action != before["next_action"] or
            waiting_until != before["waiting_until"]) do
      workflow =
        before
        |> Map.drop(["label"])
        |> Map.merge(%{
          "state" => state,
          "owner" => if(state == "you_own", do: user_owner(todo), else: before["owner"]),
          "next_action" => next_action,
          "reason" => "The todo's status or next action was updated.",
          "revision" => before["revision"] + 1,
          "changed_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "waiting_until" => waiting_until
        })

      if before["state"] in @terminal and state not in [before["state"], "you_own"] do
        add_error(changeset, :workflow, "reopen this outcome before resuming work")
      else
        put_change(changeset, :workflow, workflow)
      end
    else
      changeset
    end
  end

  defp legacy_state(%{status: "snoozed"}), do: "waiting"

  defp legacy_state(%{
         direction: "owed_to_me",
         counterparty_person_id: id,
         counterparty_label: label
       })
       when is_binary(id) and is_binary(label),
       do: "they_own"

  defp legacy_state(%{direction: "owed_to_me"}), do: "waiting"
  defp legacy_state(%{attention_mode: "monitor"}), do: "waiting"
  defp legacy_state(_), do: "you_own"

  defp legacy_owner(%{
         direction: "owed_to_me",
         counterparty_person_id: id,
         counterparty_label: label
       })
       when is_binary(id) and is_binary(label),
       do: %{"kind" => "person", "id" => id, "label" => label}

  defp legacy_owner(todo), do: user_owner(todo)

  defp valid_owner?(state, %{"kind" => kind, "id" => id, "label" => label}) do
    kind in ["user", "person"] and text?(id, 320) and text?(label, 255) and
      (state != "you_own" or kind == "user") and (state != "they_own" or kind == "person")
  end

  defp valid_owner?(_, _), do: false

  defp text?(value, limit),
    do:
      is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and
        String.trim(value) != ""

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(_), do: nil

  defp valid_wait?(nil), do: true

  defp valid_wait?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_wait?(_), do: false
end
