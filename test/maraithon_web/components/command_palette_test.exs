defmodule MaraithonWeb.Components.CommandPaletteTest do
  use MaraithonWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias MaraithonWeb.Components.CommandPalette

  test "renders global and contextual todo commands" do
    assigns = %{current_path: "/todos", current_user: %{is_admin: false}}

    html =
      rendered_to_string(~H"""
      <CommandPalette.command_palette current_path={@current_path} current_user={@current_user} />
      """)

    assert html =~ ~s(id="maraithon-command-palette")
    assert html =~ "Needs action todos"
    assert html =~ "Overdue todos"
    assert html =~ "People CRM"
    assert html =~ "Connect Google account"
    refute html =~ "Admin dashboard"
  end

  test "includes admin commands for admin users" do
    assigns = %{current_path: "/dashboard", current_user: %{is_admin: true}}

    html =
      rendered_to_string(~H"""
      <CommandPalette.command_palette current_path={@current_path} current_user={@current_user} />
      """)

    assert html =~ "Settings"
    assert html =~ "Admin dashboard"
    assert html =~ "Companion devices"
  end
end
