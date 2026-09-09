defmodule MaraithonWeb.AdminNavigation do
  @moduledoc "The task-first workspace shell, shared by web and Electron."
  use MaraithonWeb, :html
  import MaraithonWeb.Components.Sidebar, only: [sidebar_account: 1, icon: 1]

  attr :current_path, :string, default: "/todos"
  attr :current_user, :map, default: nil
  slot :inner_block, required: true
  slot :flash

  def admin_layout(assigns) do
    path = (assigns.current_path || "/todos") |> String.split("?", parts: 2) |> List.first()
    assigns = assign(assigns, :path, path)

    ~H"""
    <div id="workspace-shell" class="workspace-shell" phx-hook="WorkspaceShell">
      <a href="#workspace-content" class="workspace-skip">Skip to content</a>
      <div class="desktop-drag-strip" aria-hidden="true"></div>
      <header class="workspace-mobile-header">
        <button type="button" data-sidebar-toggle aria-label="Open navigation" aria-expanded="false" aria-controls="workspace-sidebar" class="workspace-icon-button">
          <svg class="size-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="M4 6h16M4 12h16M4 18h16" stroke-linecap="round" /></svg>
        </button>
        <.link navigate={~p"/todos"} class="font-semibold tracking-tight">Maraithon</.link>
        <span class="workspace-mark workspace-mark-small" aria-hidden="true">m</span>
      </header>
      <button type="button" data-sidebar-close class="workspace-scrim" aria-label="Close navigation" tabindex="-1"></button>
      <aside id="workspace-sidebar" class="workspace-sidebar runner-noise-surface" aria-label="Main navigation">
        <.link navigate={~p"/todos"} class="workspace-brand">
          <span class="workspace-mark" aria-hidden="true">m</span>
          <span>Maraithon<span class="workspace-brand-caption">Your chief of staff</span></span>
        </.link>
        <.link navigate={~p"/todos"} class="workspace-search" data-task-search>
          <.icon name={:search} class="size-4" /><span>Find a task</span><kbd>/</kbd>
        </.link>
        <nav class="workspace-nav" aria-label="Workspace">
          <span class="workspace-nav-label">Workspace</span>
          <.nav_item path={@path} to="/todos" icon={:todos} label="Tasks" />
          <.nav_item path={@path} to="/briefing" icon={:book} label="Daily brief" />
          <.nav_item path={@path} to="/operator/people" icon={:people} label="People" />
          <.nav_item path={@path} to="/activity" icon={:bolt} label="Activity" />
          <span class="workspace-nav-label mt-6">Connected context</span>
          <.nav_item path={@path} to="/connectors" icon={:connectors} label="Apps" live={false} />
          <button type="button" data-native-sources class="workspace-nav-item desktop-only">
            <.icon name={:settings} class="size-4" /><span>Mac sources</span><span class="workspace-local-label">Local</span>
          </button>
        </nav>
        <div class="workspace-sidebar-bottom">
          <div class="workspace-connection" role="status" data-connection-status>
            <span class="workspace-status-dot"></span><span data-connection-label>Connected</span>
          </div>
          <button type="button" data-theme-toggle class="workspace-nav-item" aria-label="Change appearance">
            <.icon name={:settings} class="size-4" /><span>Appearance</span><span class="workspace-local-label" data-theme-label>System</span>
          </button>
          <div :if={@current_user} class="workspace-account">
            <.sidebar_account email={@current_user.email} name={Map.get(@current_user, :name)} />
          </div>
        </div>
      </aside>
      <main id="workspace-content" class="workspace-content" tabindex="-1">
        <%= render_slot(@flash) %>
        <%= render_slot(@inner_block) %>
      </main>
    </div>
    """
  end

  attr :path, :string, required: true
  attr :to, :string, required: true
  attr :icon, :atom, required: true
  attr :label, :string, required: true
  attr :live, :boolean, default: true

  defp nav_item(assigns) do
    assigns =
      assign(
        assigns,
        :active,
        assigns.path == assigns.to || String.starts_with?(assigns.path, assigns.to <> "/")
      )

    ~H"""
    <.link navigate={@live && @to} href={!@live && @to} class={["workspace-nav-item", @active && "is-active"]} aria-current={@active && "page"}>
      <.icon name={@icon} class="size-4" /><span><%= @label %></span>
    </.link>
    """
  end

  attr :current_path, :string, default: "/todos"
  attr :current_user, :map, default: nil
  def admin_tabs(assigns), do: ~H""
end
