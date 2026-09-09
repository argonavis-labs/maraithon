defmodule Maraithon.TodoBrowser do
  @moduledoc """
  Bounded outbound relay to the user's paired Mac. PostgreSQL owns command
  delivery across serving revisions. A claim is never returned to pending;
  an interrupted interaction requires a fresh page inspection and review.
  """
  import Ecto.Query
  alias Maraithon.{Repo, Todos}
  alias Maraithon.Companion.Device
  alias Maraithon.TodoBrowser.Command

  @read_operations ~w(navigate snapshot show)
  @write_operations ~w(click fill press)
  @timeout_seconds 45

  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "operation" => %{"type" => "string", "enum" => @read_operations ++ @write_operations},
        "url" => %{
          "type" => "string",
          "description" =>
            "Exact http(s) URL from context, or the current page URL for interaction."
        },
        "element_id" => %{
          "type" => "string",
          "description" => "Element ID from the latest snapshot. Never invent an ID."
        },
        "label" => %{
          "type" => "string",
          "description" => "Exact element label from the snapshot."
        },
        "text" => %{
          "type" => "string",
          "description" => "Exact text to fill, or Enter/Tab/Escape for press."
        }
      },
      "required" => ["operation"],
      "additionalProperties" => false
    }
  end

  def validate(args, kind) when is_map(args) do
    operations = if kind == :read, do: @read_operations, else: @write_operations

    cond do
      args["operation"] not in operations ->
        {:error, "Unsupported browser operation."}

      byte_size(Jason.encode!(args)) > 16_384 ->
        {:error, "Browser request is too large."}

      args["operation"] == "navigate" and not web_url?(args["url"]) ->
        {:error, "Provide an exact http(s) page URL."}

      kind == :write and
          not (web_url?(args["url"]) and text?(args["element_id"]) and text?(args["label"])) ->
        {:error, "Inspect the page first and use its exact URL, element ID, and label."}

      args["operation"] == "fill" and not is_binary(args["text"]) ->
        {:error, "Provide the exact text to fill."}

      args["operation"] == "press" and args["text"] not in ~w(Enter Tab Escape) ->
        {:error, "Only Enter, Tab, and Escape are supported."}

      true ->
        :ok
    end
  end

  def execute(args, kind) do
    with :ok <- validate(args, kind),
         todo when not is_nil(todo) <- Todos.get_for_user(args["user_id"], args["todo_id"]),
         {:ok, command} <- enqueue(args) do
      await_result(command.id, System.monotonic_time(:millisecond) + @timeout_seconds * 1_000)
    else
      nil -> {:error, "Open a todo before using its browser."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue(args) do
    id = args["command_id"] || Ecto.UUID.generate()

    case Repo.get_by(Command, id: id, user_id: args["user_id"], todo_id: args["todo_id"]) do
      %Command{} = command ->
        {:ok, command}

      nil ->
        case host(args["user_id"], args["todo_id"]) do
          nil ->
            {:error,
             "Open the updated Maraithon Mac app with Google Chrome installed. Browser work runs on your Mac, including requests from web and iPhone."}

          device_id ->
            Repo.insert(
              %Command{
                id: id,
                user_id: args["user_id"],
                todo_id: args["todo_id"],
                device_id: device_id,
                operation: args["operation"],
                payload: Map.take(args, ~w(url element_id label text)),
                expires_at: DateTime.add(DateTime.utc_now(), @timeout_seconds, :second)
              },
              on_conflict: :nothing,
              conflict_target: :id
            )
        end
    end
  end

  defp host(user_id, todo_id) do
    # Once a todo has a browser, keep using that Mac so a stale element can
    # never be interpreted in another device's unrelated session.
    prior =
      Repo.one(
        from c in Command,
          where: c.user_id == ^user_id and c.todo_id == ^todo_id,
          order_by: [desc: c.inserted_at],
          limit: 1,
          select: c.device_id
      )

    query =
      from h in "todo_browser_hosts",
        join: d in Device,
        on: d.id == h.id,
        where:
          h.user_id == ^user_id and is_nil(d.revoked_at) and
            h.seen_at > fragment("clock_timestamp() - interval '30 seconds'"),
        order_by: [desc: h.seen_at],
        limit: 1,
        select: type(h.id, Ecto.UUID)

    query = if prior, do: from(h in query, where: h.id == type(^prior, Ecto.UUID)), else: query
    Repo.one(query)
  end

  def claim(%Device{} = device, available?) do
    now = DateTime.utc_now()

    if available? do
      Repo.insert_all(
        "todo_browser_hosts",
        [%{id: Ecto.UUID.dump!(device.id), user_id: device.user_id, seen_at: now}],
        on_conflict: {:replace, [:seen_at]},
        conflict_target: :id
      )
    else
      Repo.delete_all(from h in "todo_browser_hosts", where: h.id == type(^device.id, Ecto.UUID))
    end

    expire(device.id)

    if available? do
      Repo.transaction(fn ->
        command =
          Repo.one(
            from c in Command,
              where:
                c.device_id == ^device.id and c.user_id == ^device.user_id and
                  c.status == "pending" and
                  c.expires_at > fragment("clock_timestamp()"),
              order_by: [asc: c.inserted_at],
              limit: 1,
              lock: "FOR UPDATE SKIP LOCKED"
          )

        if command do
          Repo.update!(Ecto.Changeset.change(command, status: "running"))

          %{
            id: command.id,
            todo_id: command.todo_id,
            operation: command.operation,
            payload: command.payload,
            expires_at: command.expires_at
          }
        end
      end)
    else
      {:ok, nil}
    end
  end

  def complete(device, id, result) when is_map(result) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         true <- byte_size(Jason.encode!(result)) <= 65_536 do
      status =
        cond do
          result["error_class"] == "ambiguous" -> "unknown"
          result["error"] -> "failed"
          true -> "completed"
        end

      {count, _} =
        Repo.update_all(
          from(c in Command,
            where:
              c.id == ^id and c.device_id == ^device.id and c.user_id == ^device.user_id and
                c.status == "running" and c.expires_at > fragment("clock_timestamp()")
          ),
          set: [result: result, status: status, updated_at: DateTime.utc_now()]
        )

      if count == 1, do: :ok, else: {:error, :already_settled}
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

    # Browser context belongs in the durable conversation; relay payloads only
    # live for one day. Do not retain a second indefinite browsing archive.
    Repo.delete_all(
      from c in Command, where: c.device_id == ^device_id and c.inserted_at < ago(1, "day")
    )
  end

  defp await_result(id, deadline) do
    case Repo.get(Command, id) do
      %Command{status: "completed", result: result} ->
        {:ok, result}

      %Command{status: "failed", result: result} ->
        {:error, result["error"] || "Browser step failed."}

      %Command{status: status} when status in ~w(unknown expired) ->
        uncertain()

      nil ->
        {:error, "Browser request is no longer available."}

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
       {:browser_unknown,
        "The Mac did not confirm this browser step. Its outcome is uncertain. Inspect the page before proposing another interaction; do not repeat the action automatically."}}

  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  defp web_url?(value) when is_binary(value) do
    uri = URI.parse(value)
    uri.scheme in ~w(http https) and text?(uri.host) and is_nil(uri.userinfo)
  end

  defp web_url?(_), do: false
end
