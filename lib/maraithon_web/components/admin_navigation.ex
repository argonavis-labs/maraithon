defmodule MaraithonWeb.AdminNavigation do
  @moduledoc """
  Catalyst-styled sidebar navigation for the Maraithon admin surfaces.

  This module owns the layout chrome: sidebar (desktop), mobile nav,
  and account footer. It renders the same set of routes regardless of
  surface so deep-link navigation feels predictable.
  """

  use MaraithonWeb, :html

  import MaraithonWeb.Components.Sidebar

  @primary_nav [
    %{label: "Dashboard", path: "/dashboard", icon: :home},
    %{label: "Agents", path: "/agents", icon: :agents},
    %{label: "Connectors", path: "/connectors", icon: :connectors},
    %{label: "How it works", path: "/how-it-works", icon: :book}
  ]

  @admin_nav [
    %{label: "Settings", path: "/settings", icon: :settings}
  ]

  @secondary_nav [
    %{label: "Support", path: "mailto:kent.fenwick@gmail.com", icon: :lifebuoy},
    %{label: "Changelog", path: "/changelog", icon: :bolt}
  ]

  attr :current_path, :string, default: "/dashboard"
  attr :current_user, :map, default: nil
  slot :inner_block, required: true
  slot :flash

  def admin_layout(assigns) do
    assigns =
      assigns
      |> assign(:normalized_path, normalize_path(assigns.current_path))
      |> assign(:primary_nav, @primary_nav)
      |> assign(:secondary_nav, @secondary_nav)
      |> assign(:admin_nav, if(admin_user?(assigns.current_user), do: @admin_nav, else: []))

    ~H"""
    <div class="relative isolate flex min-h-svh w-full bg-zinc-50 max-lg:flex-col lg:bg-zinc-100">
      <aside
        id="maraithon-sidebar"
        class={[
          "fixed inset-y-0 left-0 z-30 w-64 bg-white",
          "max-lg:hidden"
        ]}
      >
        <.maraithon_sidebar
          primary_nav={@primary_nav}
          secondary_nav={@secondary_nav}
          admin_nav={@admin_nav}
          normalized_path={@normalized_path}
          current_user={@current_user}
        />
      </aside>

      <div
        id="maraithon-mobile-sidebar"
        class={[
          "fixed inset-y-0 left-0 z-40 w-72 max-w-[85vw] bg-white shadow-xl lg:hidden",
          "translate-x-[-100%] transition-transform duration-200 ease-out",
          "data-[open=true]:translate-x-0"
        ]}
        data-open="false"
        aria-hidden="true"
      >
        <.maraithon_sidebar
          primary_nav={@primary_nav}
          secondary_nav={@secondary_nav}
          admin_nav={@admin_nav}
          normalized_path={@normalized_path}
          current_user={@current_user}
        />
      </div>
      <div
        id="maraithon-mobile-sidebar-backdrop"
        class={[
          "fixed inset-0 z-30 bg-zinc-950/30 transition-opacity duration-200 lg:hidden",
          "pointer-events-none opacity-0",
          "data-[open=true]:pointer-events-auto data-[open=true]:opacity-100"
        ]}
        data-open="false"
        phx-click={hide_mobile_sidebar()}
      />

      <header class="flex items-center gap-2 px-4 py-2 lg:hidden">
        <button
          type="button"
          phx-click={show_mobile_sidebar()}
          class="-m-2 inline-flex size-10 items-center justify-center rounded-lg text-zinc-500 hover:bg-zinc-950/5 hover:text-zinc-950"
          aria-label="Open navigation"
        >
          <svg viewBox="0 0 20 20" class="size-5 fill-current" aria-hidden="true">
            <path d="M2 6.75A.75.75 0 0 1 2.75 6h14.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 6.75Zm0 6.5A.75.75 0 0 1 2.75 12.5h14.5a.75.75 0 0 1 0 1.5H2.75a.75.75 0 0 1-.75-.75Z" />
          </svg>
        </button>
        <span class="text-sm/5 font-semibold tracking-tight text-zinc-950">Maraithon</span>
      </header>

      <main class="flex flex-1 flex-col pb-2 lg:min-w-0 lg:pt-2 lg:pr-2 lg:pl-64">
        <div class="grow p-4 sm:p-6 lg:rounded-lg lg:bg-white lg:p-10 lg:shadow-xs lg:ring-1 lg:ring-zinc-950/5">
          <div class="mx-auto w-full max-w-6xl">
            <%= render_slot(@flash) %>
            <%= render_slot(@inner_block) %>
          </div>
        </div>
      </main>
    </div>
    """
  end

  attr :primary_nav, :list, required: true
  attr :secondary_nav, :list, required: true
  attr :admin_nav, :list, required: true
  attr :normalized_path, :string, required: true
  attr :current_user, :map, default: nil

  defp maraithon_sidebar(assigns) do
    ~H"""
    <.sidebar class="border-r border-zinc-950/5">
      <.sidebar_header>
        <.sidebar_brand title="Maraithon" subtitle="Agent runtime" navigate="/dashboard" />
      </.sidebar_header>

      <.sidebar_body>
        <.sidebar_section>
          <.sidebar_item
            :for={item <- @primary_nav}
            navigate={item.path}
            current={active?(@normalized_path, item.path)}
          >
            <.icon name={item.icon} class="size-5" />
            <.sidebar_label><%= item.label %></.sidebar_label>
          </.sidebar_item>
          <.sidebar_item
            :for={item <- @admin_nav}
            navigate={item.path}
            current={active?(@normalized_path, item.path)}
          >
            <.icon name={item.icon} class="size-5" />
            <.sidebar_label><%= item.label %></.sidebar_label>
          </.sidebar_item>
        </.sidebar_section>

        <.sidebar_spacer />

        <.sidebar_section>
          <.sidebar_item :for={item <- @secondary_nav} href={item.path}>
            <.icon name={item.icon} class="size-5" />
            <.sidebar_label><%= item.label %></.sidebar_label>
          </.sidebar_item>
        </.sidebar_section>
      </.sidebar_body>

      <.sidebar_footer :if={@current_user}>
        <.sidebar_account email={@current_user.email} name={Map.get(@current_user, :name)} />
      </.sidebar_footer>
    </.sidebar>
    """
  end

  # Legacy top-tab signature kept for any caller that hasn't migrated to
  # `admin_layout/1` yet. Renders nothing so old templates degrade
  # cleanly until they're refactored.
  attr :current_path, :string, default: "/dashboard"
  attr :current_user, :map, default: nil

  def admin_tabs(assigns) do
    _ = assigns
    ~H""
  end

  defp show_mobile_sidebar(js \\ %Phoenix.LiveView.JS{}) do
    js
    |> Phoenix.LiveView.JS.set_attribute({"data-open", "true"}, to: "#maraithon-mobile-sidebar")
    |> Phoenix.LiveView.JS.set_attribute({"data-open", "true"},
      to: "#maraithon-mobile-sidebar-backdrop"
    )
    |> Phoenix.LiveView.JS.set_attribute({"aria-hidden", "false"},
      to: "#maraithon-mobile-sidebar"
    )
  end

  defp hide_mobile_sidebar(js \\ %Phoenix.LiveView.JS{}) do
    js
    |> Phoenix.LiveView.JS.set_attribute({"data-open", "false"}, to: "#maraithon-mobile-sidebar")
    |> Phoenix.LiveView.JS.set_attribute({"data-open", "false"},
      to: "#maraithon-mobile-sidebar-backdrop"
    )
    |> Phoenix.LiveView.JS.set_attribute({"aria-hidden", "true"}, to: "#maraithon-mobile-sidebar")
  end

  defp normalize_path(nil), do: "/dashboard"

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.split("?", parts: 2)
    |> List.first()
    |> case do
      nil -> "/dashboard"
      "" -> "/dashboard"
      value -> value
    end
  end

  defp normalize_path(_path), do: "/dashboard"

  defp active?(current_path, "/dashboard"),
    do: current_path in ["/dashboard", "/admin", "/"]

  defp active?(current_path, "/agents"),
    do: String.starts_with?(current_path, "/agents")

  defp active?(current_path, "/connectors"),
    do: String.starts_with?(current_path, "/connectors")

  defp active?(current_path, "/settings"),
    do: String.starts_with?(current_path, "/settings")

  defp active?(current_path, path), do: current_path == path

  defp admin_user?(%{is_admin: true}), do: true
  defp admin_user?(_), do: false
end
