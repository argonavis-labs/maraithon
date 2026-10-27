defmodule MaraithonWeb.AdminPageController do
  use MaraithonWeb, :controller

  alias Maraithon.Companion.Devices

  def index(conn, _params) do
    redirect(conn, to: "/settings")
  end

  @doc """
  GET /admin/companion-devices

  Lists every paired companion device for the signed-in admin user with
  per-source row counts. The row owner is identified by the admin's own
  email; the page does not let admins inspect other users' devices.
  """
  def companion_devices(conn, _params) do
    user = conn.assigns.current_user
    user_id = if user, do: user.id, else: nil

    devices_with_stats =
      if user_id do
        user_id
        |> Devices.list_for_user()
        |> Devices.enrich_with_stats()
      else
        []
      end

    render(conn, :companion_devices,
      page_title: "Paired devices",
      current_path: ~p"/admin/companion-devices",
      current_user: user,
      devices: devices_with_stats
    )
  end
end
