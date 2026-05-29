defmodule MaraithonWeb.Components.CommandPaletteTest do
  use MaraithonWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias MaraithonWeb.Components.CommandPalette

  test "renders global and contextual work commands" do
    assigns = %{current_path: "/todos", current_user: %{is_admin: false}}

    html =
      rendered_to_string(~H"""
      <CommandPalette.command_palette current_path={@current_path} current_user={@current_user} />
      """)

    assert html =~ ~s(id="maraithon-command-palette")
    assert html =~ "Needs action work"
    assert html =~ "Past-due work"
    assert html =~ "People directory"
    assert html =~ "All active work"
    assert html =~ "Automations"
    refute html =~ "Late work"
    refute html =~ "Overdue work"
    refute html =~ "People CRM"
    refute html =~ "todo cards"
    refute html =~ "todo table"
    refute html =~ "Open full todo list"
    refute html =~ "agent runtime"
    refute html =~ "Create an agent"
    assert html =~ "Connect Google account"
    refute html =~ "Admin dashboard"
  end

  test "renders dashboard suggestions without todo or agent jargon" do
    assigns = %{current_path: "/dashboard", current_user: %{is_admin: false}}

    html =
      rendered_to_string(~H"""
      <CommandPalette.command_palette current_path={@current_path} current_user={@current_user} />
      """)

    assert html =~ "Review today&#39;s work"
    assert html =~ "Open full work queue"
    assert html =~ "Create an automation"
    refute html =~ "work cards"
    refute html =~ "todo cards"
    refute html =~ "Open full todo list"
    refute html =~ "Create an agent"
  end

  test "includes admin commands for admin users" do
    assigns = %{current_path: "/dashboard", current_user: %{is_admin: true}}

    html =
      rendered_to_string(~H"""
      <CommandPalette.command_palette current_path={@current_path} current_user={@current_user} />
      """)

    assert html =~ "Settings"
    assert html =~ "Review workspace setup."
    assert html =~ "Admin dashboard"
    assert html =~ "Companion devices"
    refute html =~ "Manage runtime settings."
  end
end
