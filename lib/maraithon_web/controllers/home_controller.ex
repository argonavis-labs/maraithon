defmodule MaraithonWeb.HomeController do
  use MaraithonWeb, :controller

  def index(conn, _params) do
    case conn.assigns[:current_user] do
      %{id: user_id} ->
        redirect(conn, to: post_sign_in_path(user_id))

      _ ->
        conn
        |> assign(:page_title, "Maraithon — A chief of staff that stays with you")
        |> render(:index)
    end
  end

  def login(conn, _params) do
    case conn.assigns[:current_user] do
      %{id: user_id} ->
        redirect(conn, to: post_sign_in_path(user_id))

      _ ->
        render(conn, :login,
          page_title: "Sign in — Maraithon",
          form: Phoenix.Component.to_form(%{"email" => ""}, as: :magic_link)
        )
    end
  end

  defp post_sign_in_path(user_id) do
    if is_binary(user_id), do: "/dashboard", else: "/"
  end
end
