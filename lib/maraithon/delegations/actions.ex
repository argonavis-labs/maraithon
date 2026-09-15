defmodule Maraithon.Delegations.Actions do
  @moduledoc "Prepared-action changes made while holding a delegation's control lock."
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Delegations.Turn
  alias Maraithon.TelegramAssistant.{PreparedAction, Run}

  @doc "Cancel only work with no provider entry. Returns whether a send may be in flight."
  def supersede_unentered!(d) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "control requires a transaction")

    Repo.all(
      from t in Turn,
        where:
          t.user_id == ^d.user_id and t.delegation_id == ^d.id and
            t.status in ~w(deciding validated dispatched),
        order_by: t.id,
        lock: "FOR UPDATE"
    )
    |> Enum.reduce(false, fn row, entered? ->
      turn = Turn.hydrate(row)

      if turn.run_id,
        do:
          Repo.one!(
            from r in Run,
              where: r.id == ^turn.run_id and r.user_id == ^d.user_id,
              lock: "FOR UPDATE"
          )

      action =
        if turn.prepared_action_id,
          do:
            Repo.one!(
              from a in PreparedAction,
                where: a.id == ^turn.prepared_action_id and a.user_id == ^d.user_id,
                lock: "FOR UPDATE"
            )
            |> PreparedAction.hydrate_payload()

      cond do
        is_nil(action) ->
          supersede!(turn)
          entered?

        action.authorization_kind != "delegation_grant" or action.delegation_id != d.id or
          action.delegation_turn_id != turn.id or action.run_id != turn.run_id ->
          Repo.rollback(:delegation_action_mismatch)

        unentered?(action) ->
          action
          |> PreparedAction.changeset(%{status: "rejected", error: "delegation_superseded"})
          |> Repo.update!()

          supersede!(turn)
          entered?

        action.status in ~w(rejected expired failed) ->
          supersede!(turn)
          entered?

        true ->
          entered? or action.status in ~w(confirmed execution_unknown)
      end
    end)
  end

  def unentered?(%PreparedAction{status: status, payload: payload})
      when status in ~w(awaiting_confirmation confirmed),
      do:
        (payload["_maraithon_execution_attempts"] || 0) == 0 and
          is_nil(payload["_maraithon_execution_token"])

  def unentered?(_), do: false

  defp supersede!(turn), do: turn |> Turn.changeset(%{status: "superseded"}) |> Repo.update!()
end
