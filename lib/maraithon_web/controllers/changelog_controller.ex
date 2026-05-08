defmodule MaraithonWeb.ChangelogController do
  use MaraithonWeb, :controller

  alias Maraithon.Changelog

  def index(conn, _params) do
    render(conn, :index,
      page_title: "Changelog",
      current_path: ~p"/changelog",
      current_user: conn.assigns[:current_user],
      days: Changelog.days(),
      generated_at: Changelog.generated_at()
    )
  end
end
