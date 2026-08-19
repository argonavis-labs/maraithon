defmodule MaraithonWeb.AdminNavigation do
  @moduledoc """
  Minimal authenticated shell for Maraithon's focused todo experience.

  Todos remain the primary workspace. Apps stays available as a supporting
  destination so people can connect and manage the sources that feed the list.
  """

  use MaraithonWeb, :html

  import MaraithonWeb.Components.Sidebar, only: [sidebar_account: 1]

  attr :current_path, :string, default: "/todos"
  attr :current_user, :map, default: nil
  slot :inner_block, required: true
  slot :flash

  def admin_layout(assigns) do
    assigns = assign(assigns, :normalized_path, normalize_path(assigns.current_path))

    ~H"""
    <div class="min-h-svh bg-zinc-50">
      <header class="border-b border-zinc-950/10 bg-white">
        <div class="mx-auto flex h-14 w-full max-w-6xl items-center justify-between gap-4 px-4 sm:px-6 lg:px-8">
          <div class="flex min-w-0 items-center gap-5">
            <.link navigate={~p"/todos"} class="text-sm/5 font-semibold tracking-tight text-zinc-950">
              Maraithon
            </.link>
            <nav class="flex items-center gap-1" aria-label="Workspace">
              <.link
                navigate={~p"/todos"}
                class={nav_link_class(@normalized_path, "/todos")}
                aria-current={active?(@normalized_path, "/todos") && "page"}
              >
                Todos
              </.link>
              <.link
                href={~p"/connectors"}
                class={nav_link_class(@normalized_path, "/connectors")}
                aria-current={active?(@normalized_path, "/connectors") && "page"}
              >
                Apps
              </.link>
            </nav>
          </div>

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

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.split("?", parts: 2)
    |> List.first()
    |> case do
      nil -> "/todos"
      "" -> "/todos"
      value -> value
    end
  end

  defp normalize_path(_path), do: "/todos"

  defp active?(path, "/todos"), do: path == "/todos" or String.starts_with?(path, "/todos/")
  defp active?(path, "/connectors"), do: String.starts_with?(path, "/connectors")
  defp active?(_path, _destination), do: false

  defp nav_link_class(path, destination) do
    [
      "rounded-md px-2.5 py-1.5 text-sm/5 font-medium transition-colors",
      if(active?(path, destination),
        do: "bg-zinc-950/[0.06] text-zinc-950",
        else: "text-zinc-500 hover:bg-zinc-950/[0.04] hover:text-zinc-950"
      )
    ]
  end

  # Legacy top-tab signature kept for callers outside the focused shell.
  attr :current_path, :string, default: "/todos"
  attr :current_user, :map, default: nil

  def admin_tabs(assigns) do
    _ = assigns
    ~H""
  end
end
