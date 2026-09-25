defmodule Maraithon.AssistantChat.LegacyMessageDrafts do
  @moduledoc "Upgrades the newest old Messages draft when its todo is opened, without sending or rewriting it."
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.{PreparedAction, Run}
  alias Maraithon.TelegramConversations.Turn
  alias Maraithon.PrivacyErasure.WriteFence

  def prepare(conversation, todo) do
    if todo.status in ~w(triage open snoozed) do
      Repo.transaction(fn ->
        WriteFence.lock_user_writable!(todo.user_id)

        turns =
          Repo.all(
            from t in Turn,
              where: t.conversation_id == ^conversation.id,
              order_by: [desc: t.inserted_at],
              limit: 80,
              lock: "FOR UPDATE"
          )
          |> Enum.map(&Turn.hydrate/1)

        latest =
          Enum.find(turns, fn t ->
            get_in(t.structured_data || %{}, ["draft_card", "provider"]) == "imessage"
          end)

        pending? =
          Repo.exists?(
            from a in PreparedAction,
              where:
                a.user_id == ^todo.user_id and a.conversation_id == ^conversation.id and
                  a.action_type == "imessage_send"
          )

        if latest && !pending? && is_nil(latest.structured_data["prepared_action_id"]) do
          upgrade(latest, conversation, todo)
        end
      end)
    end

    :ok
  end

  defp upgrade(turn, conversation, todo) do
    run_id = turn.structured_data["run_id"]

    run =
      if is_binary(run_id),
        do: Repo.get_by(Run, id: run_id, user_id: todo.user_id, conversation_id: conversation.id)

    card = turn.structured_data["draft_card"]

    if run do
      context = %{
        user_id: todo.user_id,
        run_id: run.id,
        conversation_id: conversation.id,
        chat_id: run.chat_id,
        surface: "mobile"
      }

      args = Map.take(card, ~w(recipient body)) |> Map.put("todo_id", todo.id)

      case Maraithon.AssistantChat.MessageDraft.prepare_action(context, args) do
        {:ok, %{prepared_action_id: id}} ->
          data = Map.put(turn.structured_data, "prepared_action_id", id)

          case turn
               |> Turn.changeset(%{structured_data: data, turn_kind: "approval_prompt"})
               |> Repo.update() do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

        _ ->
          :ok
      end
    end
  end
end
