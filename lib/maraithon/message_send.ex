defmodule Maraithon.MessageSend do
  @moduledoc "Single-delivery relay for human-approved Messages sends on a paired Mac."
  import Ecto.Query
  alias Maraithon.{Repo, TelegramAssistant}
  alias Maraithon.Companion.Device
  alias Maraithon.MessageSend.Command
  alias Maraithon.PrivacyErasure.WriteFence

  @timeout 45

  def execute(action) do
    with :ok <- WriteFence.check_user(action.user_id),
         %{
           status: "confirmed",
           action_type: "imessage_send",
           authorization_kind: "human_confirmed"
         } = current <- TelegramAssistant.get_prepared_action(action.id),
         true <- current.user_id == action.user_id,
         {:ok, command} <- enqueue(current) do
      await_result(command.id, System.monotonic_time(:millisecond) + @timeout * 1_000)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "This message needs your approval before sending."}
    end
  end

  def available?(user_id), do: not is_nil(host(user_id))

  defp host(user_id) do
    Repo.one(
      from h in "message_send_hosts",
        join: d in Device,
        on: d.id == h.id,
        where:
          h.user_id == ^user_id and is_nil(d.revoked_at) and
            h.seen_at > fragment("clock_timestamp() - interval '30 seconds'"),
        order_by: [desc: h.seen_at],
        limit: 1,
        select: type(h.id, Ecto.UUID)
    )
  end

  defp enqueue(action) do
    Repo.transaction(fn ->
      WriteFence.lock_user_writable!(action.user_id)

      case enqueue_locked(action) do
        {:ok, command} -> command
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp enqueue_locked(action) do
    case Repo.get_by(Command, id: action.id, user_id: action.user_id) do
      %Command{} = command ->
        {:ok, command}

      nil ->
        with device_id when is_binary(device_id) <- host(action.user_id),
             todo when not is_nil(todo) <-
               Maraithon.Todos.get_for_user(action.user_id, action.payload["todo_id"]) do
          result =
            Repo.insert(
              %Command{
                id: action.id,
                user_id: action.user_id,
                device_id: device_id,
                todo_id: todo.id,
                payload: Map.take(action.payload, ~w(recipient body chat_key)),
                expires_at: DateTime.add(DateTime.utc_now(), @timeout, :second)
              }, on_conflict: :nothing, conflict_target: :id)

          case result do
            {:ok, _} -> {:ok, Repo.get!(Command, action.id)}
            error -> error
          end
        else
          _ -> {:error, "Open Maraithon on your paired Mac to send with Messages."}
        end
    end
  end

  def claim(%Device{} = device, available?) do
    with :ok <- WriteFence.check_user(device.user_id) do
      Repo.transaction(fn ->
        WriteFence.lock_user_writable!(device.user_id)

        if available? do
          Repo.insert_all(
            "message_send_hosts",
            [
              %{
                id: Ecto.UUID.dump!(device.id),
                user_id: device.user_id,
                seen_at: DateTime.utc_now()
              }
            ], on_conflict: {:replace, [:seen_at]}, conflict_target: :id)
        end

        expire(device.id)

        if available? do
          command =
            Repo.one(
              from c in Command,
                where:
                  c.device_id == ^device.id and c.user_id == ^device.user_id and
                    c.status == "pending" and c.expires_at > fragment("clock_timestamp()"),
                order_by: [asc: c.inserted_at],
                limit: 1,
                lock: "FOR UPDATE SKIP LOCKED"
            )

          if command do
            Repo.update!(Ecto.Changeset.change(command, status: "running"))
            %{id: command.id, payload: command.payload, expires_at: command.expires_at}
          end
        end
      end)
    end
  end

  def complete(device, id, result) when is_map(result) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         :ok <- WriteFence.check_user(device.user_id),
         true <- result["status"] in ~w(sent failed unknown),
         true <- byte_size(Jason.encode!(result)) <= 4_096 do
      status = if result["status"] == "sent", do: "completed", else: result["status"]

      Repo.transaction(fn ->
        WriteFence.lock_user_writable!(device.user_id)

        {count, _} =
          Repo.update_all(
            from(c in Command,
              where:
                c.id == ^id and c.device_id == ^device.id and c.user_id == ^device.user_id and
                  c.status == "running"
            ),
            set: [
              result: Map.take(result, ~w(status error sent_at)),
              status: status,
              updated_at: DateTime.utc_now()
            ]
          )

        if count == 1, do: :ok, else: Repo.rollback(:already_settled)
      end)
      |> case do
        {:ok, :ok} -> :ok
        error -> error
      end
    else
      _ -> {:error, :invalid_result}
    end
  end

  def complete(_, _, _), do: {:error, :invalid_result}

  defp expire(device_id) do
    for {from_status, to_status} <- [{"pending", "expired"}, {"running", "unknown"}] do
      Repo.update_all(
        from(c in Command,
          where:
            c.device_id == ^device_id and c.status == ^from_status and
              c.expires_at <= fragment("clock_timestamp()")
        ),
        set: [status: to_status, updated_at: DateTime.utc_now()]
      )
    end

    # Keep command identities so a late retry can never send a second copy.
    Repo.update_all(
      from(c in Command,
        where:
          c.device_id == ^device_id and c.inserted_at < ago(1, "day") and
            c.status not in ["pending", "running"] and is_nil(c.payload_purged_at)
      ),
      set: [payload: %{}, result: %{}, payload_purged_at: DateTime.utc_now()]
    )
  end

  defp await_result(id, deadline) do
    case Repo.get(Command, id) do
      %Command{status: "completed", result: result} ->
        {:ok,
         Map.put(
           result || %{},
           "message",
           "Sent via Messages on your Mac. The todo remains open."
         )}

      %Command{status: "failed", result: result} ->
        {:error, result["error"] || "Messages could not send this draft."}

      %Command{status: "expired"} ->
        {:error, "Your Mac did not pick up the message. Nothing was sent."}

      %Command{status: "unknown"} ->
        uncertain()

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          uncertain()
        else
          receive do
          after
            500 -> await_result(id, deadline)
          end
        end
    end
  end

  defp uncertain,
    do:
      {:error,
       {:provider_error, "imessage", :timeout,
        "Your Mac has not confirmed the send. Check Messages before preparing another copy."}}
end
