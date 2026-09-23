defmodule MaraithonWeb.TodoTrainingController do
  use MaraithonWeb, :controller
  alias Maraithon.Todos.TrainingDataset

  def health(conn, _params) do
    conn |> private_response() |> json(TrainingDataset.health(conn.assigns.current_user.id))
  end

  def export(conn, %{"kind" => kind} = params) when kind in ["runs", "examples", "feedback"] do
    with {:ok, cursor} <- TrainingDataset.decode_cursor(params["cursor"]),
         {:ok, as_of} <- as_of(params["as_of"]) do
      page =
        TrainingDataset.page(conn.assigns.current_user.id, kind, cursor: cursor, as_of: as_of)

      if params["format"] == "jsonl" do
        manifest = Map.delete(page, :records) |> Map.put(:record_type, "manifest")
        body = Enum.map_join([manifest | page.records], "\n", &Jason.encode!/1) <> "\n"

        conn
        |> private_response()
        |> put_resp_content_type("application/x-ndjson")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="todo-training-#{kind}.jsonl")
        )
        |> send_resp(200, body)
      else
        conn |> private_response() |> json(page)
      end
    else
      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid export cursor or as_of timestamp"})
    end
  end

  def export(conn, _params),
    do: conn |> put_status(:bad_request) |> json(%{error: "Choose runs, examples, or feedback"})

  def review(conn, %{"id" => id, "verdict" => verdict, "request_id" => request_id} = params) do
    case TrainingDataset.review(
           conn.assigns.current_user.id,
           id,
           verdict,
           request_id,
           params["note"]
         ) do
      {:ok, _} ->
        conn |> private_response() |> json(%{recorded: true})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Candidate not found"})

      {:error, :request_conflict} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Request ID already used for different feedback"})

      _ ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid review"})
    end
  end

  def review(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{error: "Verdict and request_id are required"})

  defp as_of(nil), do: {:ok, DateTime.utc_now()}

  defp as_of(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} ->
        if DateTime.compare(time, DateTime.utc_now()) != :gt, do: {:ok, time}, else: :error

      _ ->
        :error
    end
  end

  defp as_of(_), do: :error
  defp private_response(conn), do: put_resp_header(conn, "cache-control", "private, no-store")
end
