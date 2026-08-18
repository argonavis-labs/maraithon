defmodule MaraithonWeb.AdminNavigation do
  @moduledoc """
  Minimal authenticated shell for Maraithon's focused todo experience.

  Secondary product surfaces remain available by direct route, but the app
  chrome deliberately presents one destination: the todo list.
  """

  use MaraithonWeb, :html

  import MaraithonWeb.Components.Sidebar, only: [sidebar_account: 1]

  attr :current_path, :string, default: "/todos"
  attr :current_user, :map, default: nil
  slot :inner_block, required: true
  slot :flash

  def admin_layout(assigns) do
    ~H"""
    <div class="min-h-svh bg-zinc-50">
      <header class="border-b border-zinc-950/10 bg-white">
        <div class="mx-auto flex h-14 w-full max-w-6xl items-center justify-between gap-4 px-4 sm:px-6 lg:px-8">
          <.link navigate={~p"/todos"} class="flex min-w-0 items-baseline gap-2">
            <span class="text-sm/5 font-semibold tracking-tight text-zinc-950">Maraithon</span>
            <span class="text-xs/5 text-zinc-500">Todos</span>
          </.link>

          <div :if={@current_user} class="min-w-0 max-w-xs">
            <.sidebar_account
              email={@current_user.email}
              name={Map.get(@current_user, :name)}
            />
          </div>
        </div>
      </header>

      <main class="mx-auto w-full max-w-6xl px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
        <%= render_slot(@flash) %>
        <%= render_slot(@inner_block) %>
      </main>
    </div>
    """
  end

  # Legacy top-tab signature kept for callers outside the focused shell.
  attr :current_path, :string, default: "/todos"
  attr :current_user, :map, default: nil

  def admin_tabs(assigns) do
    _ = assigns
    ~H""
  end
end
