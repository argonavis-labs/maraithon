defmodule MaraithonWeb.MobileBriefController do
  use MaraithonWeb, :controller

  alias Maraithon.Briefs
  alias MaraithonWeb.MobileJSON

  @max_limit 30

  def index(conn, params) do
    user_id = conn.assigns.current_user.id
    limit = parse_limit(params["limit"], 14)
    cadence = params["cadence"] || "morning"

    briefs =
      user_id
      |> Briefs.list_recent_for_user(limit: limit * 2)
      |> Enum.filter(&(cadence == "all" or &1.cadence == cadence))
      |> Enum.take(limit)

    json(conn, %{briefs: Enum.map(briefs, &MobileJSON.brief/1)})
  end

  def show(conn, %{"id" => brief_id}) do
    user_id = conn.assigns.current_user.id

    case Briefs.get_for_user(user_id, brief_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: MobileJSON.error(:not_found)})

      brief ->
        json(conn, %{brief: MobileJSON.brief(brief)})
    end
  end

  defp parse_limit(value, default) do
    case Integer.parse(to_string(value || "")) do
      {parsed, _rest} when parsed > 0 -> min(parsed, @max_limit)
      _other -> default
    end
  end
end
