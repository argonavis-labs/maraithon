defmodule MaraithonWeb.AssistantProgressController do
  use MaraithonWeb, :controller
  alias Maraithon.AssistantChat.Progress
  alias MaraithonWeb.AssistantProgress

  @lifetime_ms 50_000
  @reconcile_ms 5_000
  @refresh_ms 300
  @max_frame_bytes 3_900_000

  def show(conn, %{"id" => thread_id}) do
    user_id = conn.assigns.current_user.id

    case Ecto.UUID.cast(thread_id) do
      :error ->
        send_resp(conn, 404, "")

      {:ok, thread_id} ->
        Progress.subscribe(user_id, thread_id)

        try do
          case AssistantProgress.snapshot(user_id, thread_id) do
            {:ok, snapshot} -> stream(conn, user_id, thread_id, snapshot)
            {:error, :not_found} -> send_resp(conn, 404, "")
          end
        after
          Progress.unsubscribe(user_id, thread_id)
        end
    end
  end

  defp stream(conn, user_id, thread_id, snapshot) do
    cursor = conn |> get_req_header("last-event-id") |> List.first()

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    result =
      if cursor == snapshot.cursor,
        do: chunk(conn, ": resumed\n\n"),
        else: frame(conn, "snapshot", snapshot, snapshot.cursor)

    case result do
      {:ok, conn} ->
        now = now()

        loop(conn, %{
          user_id: user_id,
          thread_id: thread_id,
          cursor: snapshot.cursor,
          deadline: now + @lifetime_ms,
          reconcile: now + interval(snapshot),
          heartbeat: now + @reconcile_ms,
          refresh_at: nil,
          preview: nil,
          preview_at: now
        })

      _ ->
        conn
    end
  end

  defp loop(conn, state) do
    now = now()

    cond do
      now >= state.deadline ->
        conn

      now >= state.reconcile or (state.refresh_at && now >= state.refresh_at) ->
        case AssistantProgress.snapshot(state.user_id, state.thread_id) do
          {:ok, snapshot} ->
            result =
              if snapshot.cursor == state.cursor,
                do: chunk(conn, ": keepalive\n\n"),
                else: frame(conn, "snapshot", snapshot, snapshot.cursor)

            continue(result, conn, %{
              state
              | cursor: snapshot.cursor,
                reconcile: now + interval(snapshot),
                heartbeat: now + @reconcile_ms,
                refresh_at: nil
            })

          _ ->
            conn
        end

      now >= state.heartbeat ->
        continue(chunk(conn, ": keepalive\n\n"), conn, %{state | heartbeat: now + @reconcile_ms})

      state.preview && now >= state.preview_at ->
        continue(frame(conn, "preview", state.preview), conn, %{
          state
          | preview: nil,
            preview_at: now + @refresh_ms
        })

      true ->
        receive do
          {:assistant_progress, thread_id} when thread_id == state.thread_id ->
            loop(conn, %{state | refresh_at: state.refresh_at || now() + @refresh_ms})

          {:assistant_preview, thread_id, preview} when thread_id == state.thread_id ->
            loop(conn, %{state | preview: preview})
        after
          100 -> loop(conn, state)
        end
    end
  end

  defp continue({:ok, next}, _conn, state), do: loop(next, state)
  defp continue(_, conn, _state), do: conn

  defp frame(conn, event, payload, cursor \\ nil) do
    data = Jason.encode!(payload)

    if byte_size(data) <= @max_frame_bytes do
      id = if cursor, do: "id: #{cursor}\n", else: ""
      chunk(conn, [id, "event: ", event, "\ndata: ", data, "\n\n"])
    else
      {:error, :frame_too_large}
    end
  end

  defp interval(%{thread: %{pending_run: nil}}), do: 30_000
  defp interval(_), do: @reconcile_ms

  defp now, do: System.monotonic_time(:millisecond)
end
