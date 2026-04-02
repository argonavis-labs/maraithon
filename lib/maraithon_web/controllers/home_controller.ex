defmodule MaraithonWeb.HomeController do
  use MaraithonWeb, :controller

  def index(conn, _params) do
    case conn.assigns[:current_user] do
      %{id: user_id} ->
        redirect(conn, to: post_sign_in_path(user_id))

      _ ->
        render(conn, :index,
          page_title: "Maraithon",
          form: Phoenix.Component.to_form(%{"email" => ""}, as: :magic_link)
        )
    end
  end

  defp post_sign_in_path(user_id) do
    if is_binary(user_id), do: "/dashboard", else: "/"
  end
end
