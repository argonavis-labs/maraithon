defmodule MaraithonWeb.Components.Sidebar do
  @moduledoc """
  Catalyst-styled sidebar primitives for the Maraithon admin layout.

  Mirrors the structural pieces of `@catalyst/sidebar.tsx`:
  `sidebar`, `sidebar_header`, `sidebar_body`, `sidebar_footer`,
  `sidebar_section`, `sidebar_heading`, `sidebar_item`, plus a
  small `icon/1` helper for inline heroicons used in the nav.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def sidebar(assigns) do
    ~H"""
    <nav class={["flex h-full min-h-0 flex-col", @class]}>
      <%= render_slot(@inner_block) %>
    </nav>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def sidebar_header(assigns) do
    ~H"""
    <div class={[
      "flex flex-col border-b border-zinc-950/5 p-4",
      "[&>[data-slot=section]+[data-slot=section]]:mt-2.5",
      @class
    ]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def sidebar_body(assigns) do
    ~H"""
    <div class={[
      "flex flex-1 flex-col overflow-y-auto p-4",
      "[&>[data-slot=section]+[data-slot=section]]:mt-8",
      @class
    ]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def sidebar_footer(assigns) do
    ~H"""
    <div class={[
      "flex flex-col border-t border-zinc-950/5 p-4",
      "[&>[data-slot=section]+[data-slot=section]]:mt-2.5",
      @class
    ]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def sidebar_section(assigns) do
    ~H"""
    <div data-slot="section" class={["flex flex-col gap-0.5", @class]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def sidebar_heading(assigns) do
    ~H"""
    <h3 class={["mb-1 px-2 text-xs/6 font-medium text-zinc-500", @class]}>
      <%= render_slot(@inner_block) %>
    </h3>
    """
  end

  attr :class, :string, default: nil

  def sidebar_spacer(assigns) do
    ~H"""
    <div aria-hidden="true" class={["mt-8 flex-1", @class]} />
    """
  end

  attr :href, :string, default: nil
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :current, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def sidebar_item(assigns) do
    classes = [
      "group relative flex w-full items-center gap-3 rounded-lg px-2 py-2 text-left text-sm/5 font-medium",
      "text-zinc-950 hover:bg-zinc-950/5",
      "focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500/40",
      "[&_svg]:size-5 [&_svg]:shrink-0",
      if(assigns.current,
        do: "bg-zinc-950/[0.04] text-zinc-950 [&_svg]:text-zinc-950",
        else: "[&_svg]:text-zinc-500 hover:[&_svg]:text-zinc-950"
      ),
      assigns.class
    ]

    assigns = assign(assigns, :classes, classes)

    ~H"""
    <span class="relative">
      <span
        :if={@current}
        class="pointer-events-none absolute inset-y-1.5 -left-4 w-0.5 rounded-full bg-zinc-950"
        aria-hidden="true"
      />
      <.link
        :if={@navigate}
        navigate={@navigate}
        class={@classes}
        aria-current={@current && "page"}
        {@rest}
      >
        <%= render_slot(@inner_block) %>
      </.link>
      <.link
        :if={@patch}
        patch={@patch}
        class={@classes}
        aria-current={@current && "page"}
        {@rest}
      >
        <%= render_slot(@inner_block) %>
      </.link>
      <a
        :if={@href && !@navigate && !@patch}
        href={@href}
        class={@classes}
        aria-current={@current && "page"}
        {@rest}
      >
        <%= render_slot(@inner_block) %>
      </a>
    </span>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def sidebar_label(assigns) do
    ~H"""
    <span class={["truncate", @class]}>
      <%= render_slot(@inner_block) %>
    </span>
    """
  end

  @doc """
  Brand chip rendered at the top of the sidebar header.

  Shows a square logo tile and a stacked label/sublabel. The whole
  thing is wrapped in a button-like row so it can sit alongside an
  optional trailing chevron without breaking the Catalyst rhythm.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :navigate, :string, default: "/"

  def sidebar_brand(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-3 rounded-lg px-2 py-2 text-left",
        "hover:bg-zinc-950/5 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500/40"
      ]}
    >
      <span class="flex size-7 shrink-0 items-center justify-center rounded-md bg-zinc-950 text-white">
        <svg viewBox="0 0 16 16" class="size-4 fill-current" aria-hidden="true">
          <path d="M2.5 2h2.4l3.1 5.4L11.1 2h2.4v12h-1.9V5.5L8.6 11.1H7.4L4.4 5.5V14H2.5V2Z" />
        </svg>
      </span>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-sm/5 font-semibold text-zinc-950">
          <%= @title %>
        </span>
        <span :if={@subtitle} class="block truncate text-xs/4 text-zinc-500">
          <%= @subtitle %>
        </span>
      </span>
    </.link>
    """
  end

  @doc """
  Footer cluster showing the signed-in user with a logout form
  tucked behind a trailing icon button. Keeps the visual weight
  identical to the Catalyst demo's account dropdown.
  """
  attr :email, :string, required: true
  attr :name, :string, default: nil
  attr :logout_path, :string, default: "/logout"

  def sidebar_account(assigns) do
    initials =
      assigns
      |> Map.get(:name)
      |> Kernel.||(assigns.email)
      |> Kernel.||("?")
      |> initials_for()

    assigns = assign(assigns, :initials, initials)

    ~H"""
    <div class="flex items-center gap-3 rounded-lg px-2 py-2">
      <span class="flex size-9 shrink-0 items-center justify-center rounded-md bg-zinc-100 text-xs font-semibold text-zinc-700">
        <%= @initials %>
      </span>
      <span class="min-w-0 flex-1">
        <span :if={@name} class="block truncate text-sm/5 font-medium text-zinc-950">
          <%= @name %>
        </span>
        <span class={[
          "block truncate",
          if(@name, do: "text-xs/4 text-zinc-500", else: "text-sm/5 text-zinc-950")
        ]}>
          <%= @email %>
        </span>
      </span>
      <.form for={%{}} action={@logout_path} method="post" class="shrink-0">
        <input type="hidden" name="_method" value="delete" />
        <button
          type="submit"
          class="-m-1.5 inline-flex size-8 items-center justify-center rounded-md text-zinc-500 hover:bg-zinc-950/5 hover:text-zinc-950 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500/40"
          aria-label="Sign out"
        >
          <svg viewBox="0 0 20 20" class="size-5 fill-current" aria-hidden="true">
            <path
              fill-rule="evenodd"
              d="M3 4.75A2.75 2.75 0 0 1 5.75 2h4.5A2.75 2.75 0 0 1 13 4.75v1.5a.75.75 0 0 1-1.5 0v-1.5c0-.69-.56-1.25-1.25-1.25h-4.5C4.81 3.5 4.25 4.06 4.25 4.75v10.5c0 .69.56 1.25 1.25 1.25h4.5c.69 0 1.25-.56 1.25-1.25v-1.5a.75.75 0 0 1 1.5 0v1.5A2.75 2.75 0 0 1 10.25 18h-4.5A2.75 2.75 0 0 1 3 15.25V4.75Zm11.97 1.97a.75.75 0 0 1 1.06 0l2.25 2.25c.3.3.3.77 0 1.06l-2.25 2.25a.75.75 0 1 1-1.06-1.06l.97-.97H8.75a.75.75 0 0 1 0-1.5h7.19l-.97-.97a.75.75 0 0 1 0-1.06Z"
              clip-rule="evenodd"
            />
          </svg>
        </button>
      </.form>
    </div>
    """
  end

  @doc """
  Inline 20×20 heroicon (solid). Keeps the sidebar self-contained so
  we don't pull in a runtime heroicons dependency just for nav glyphs.
  """
  attr :name, :atom, required: true
  attr :class, :string, default: nil

  def icon(assigns) do
    assigns = assign(assigns, :path, icon_path(assigns.name))

    ~H"""
    <svg
      viewBox="0 0 20 20"
      class={["fill-current", @class]}
      aria-hidden="true"
    >
      <%= Phoenix.HTML.raw(@path) %>
    </svg>
    """
  end

  defp icon_path(:home),
    do:
      ~s|<path fill-rule="evenodd" d="M9.293 2.293a1 1 0 0 1 1.414 0l7 7A1 1 0 0 1 17 11h-1v6a1 1 0 0 1-1 1h-3a1 1 0 0 1-1-1v-3H9v3a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-6H3a1 1 0 0 1-.707-1.707l7-7Z" clip-rule="evenodd" />|

  defp icon_path(:agents),
    do:
      ~s|<path d="M10 2a4 4 0 0 1 4 4v1h.5A2.5 2.5 0 0 1 17 9.5v.5a3 3 0 0 1-1.4 2.54A5 5 0 0 1 10.5 18h-1A5 5 0 0 1 4.4 12.54 3 3 0 0 1 3 10v-.5A2.5 2.5 0 0 1 5.5 7H6V6a4 4 0 0 1 4-4Zm-2 4v1h4V6a2 2 0 1 0-4 0Zm0 5.25a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm4 0a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z" />|

  defp icon_path(:todos),
    do:
      ~s|<path fill-rule="evenodd" d="M4.75 3A2.75 2.75 0 0 0 2 5.75v8.5A2.75 2.75 0 0 0 4.75 17h10.5A2.75 2.75 0 0 0 18 14.25v-8.5A2.75 2.75 0 0 0 15.25 3H4.75Zm9.53 4.28a.75.75 0 0 0-1.06-1.06L8.75 10.69 6.78 8.72a.75.75 0 0 0-1.06 1.06l2.5 2.5c.3.3.77.3 1.06 0l5-5Z" clip-rule="evenodd" />|

  defp icon_path(:goals),
    do:
      ~s|<path fill-rule="evenodd" d="M10 2a8 8 0 1 0 0 16 8 8 0 0 0 0-16Zm0 2a6 6 0 1 1 0 12 6 6 0 0 1 0-12Zm0 2.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7Zm0 2a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3Z" clip-rule="evenodd" />|

  defp icon_path(:connectors),
    do:
      ~s|<path fill-rule="evenodd" d="M11.78 3.22a4.5 4.5 0 0 1 6.36 6.36l-2.122 2.122a.75.75 0 1 1-1.06-1.06l2.121-2.122a3 3 0 1 0-4.243-4.243l-2.121 2.122a.75.75 0 1 1-1.061-1.061L11.78 3.22Zm-3.535 8.485a.75.75 0 0 1 0 1.06l-1.06 1.061a3 3 0 1 0 4.242 4.243l1.061-1.061a.75.75 0 0 1 1.06 1.06l-1.06 1.061a4.5 4.5 0 0 1-6.364-6.364l1.061-1.06a.75.75 0 0 1 1.06 0Zm-.53 4.596a.75.75 0 0 1 0-1.06l5.66-5.66a.75.75 0 0 1 1.06 1.06l-5.66 5.66a.75.75 0 0 1-1.06 0Z" clip-rule="evenodd" />|

  defp icon_path(:insights),
    do:
      ~s|<path d="M10 2a6 6 0 0 0-3.9 10.56c.43.37.65.82.65 1.27V14A2.75 2.75 0 0 0 9.5 16.75h1A2.75 2.75 0 0 0 13.25 14v-.17c0-.45.22-.9.65-1.27A6 6 0 0 0 10 2Zm-1.75 12c0-.93-.47-1.8-1.18-2.42a4.5 4.5 0 1 1 5.86 0c-.71.62-1.18 1.49-1.18 2.42H8.25ZM8.5 17.5a.75.75 0 0 0 0 1.5h3a.75.75 0 0 0 0-1.5h-3Z" />|

  defp icon_path(:people),
    do:
      ~s|<path d="M7 8a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm7.5 1a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5ZM2 16.25C2 13.35 4.24 11 7 11s5 2.35 5 5.25a.75.75 0 0 1-.75.75h-8.5A.75.75 0 0 1 2 16.25Zm11.5.75h3.75a.75.75 0 0 0 .75-.75C18 13.9 16.21 12 14 12c-.77 0-1.49.23-2.1.63.92 1.01 1.5 2.36 1.6 3.87Z" />|

  defp icon_path(:memory),
    do:
      ~s|<path d="M10 2C5.58 2 2 3.57 2 5.5v9C2 16.43 5.58 18 10 18s8-1.57 8-3.5v-9C18 3.57 14.42 2 10 2Zm0 2c3.53 0 5.62.96 5.95 1.5C15.62 6.04 13.53 7 10 7s-5.62-.96-5.95-1.5C4.38 4.96 6.47 4 10 4Zm6 4.24V10.5c0 .55-2.12 1.5-6 1.5s-6-.95-6-1.5V8.24C5.47 8.72 7.56 9 10 9s4.53-.28 6-.76Zm-6 7.76c-3.88 0-6-.95-6-1.5v-1.76c1.47.48 3.56.76 6 .76s4.53-.28 6-.76v1.76c0 .55-2.12 1.5-6 1.5Z" />|

  defp icon_path(:book),
    do:
      ~s|<path d="M4 3.5A1.5 1.5 0 0 1 5.5 2h7A2.5 2.5 0 0 1 15 4.5V16a1 1 0 0 1-1.514.857L10 14.81l-3.486 2.046A1 1 0 0 1 5 16V4.75A1.25 1.25 0 0 1 6.25 3.5H4ZM6 5v9.063l4-2.351 4 2.351V4.5a1 1 0 0 0-1-1H7a1 1 0 0 0-1 1v.5Z" />|

  defp icon_path(:settings),
    do:
      ~s|<path fill-rule="evenodd" d="M7.84 1.804A1 1 0 0 1 8.82 1h2.36a1 1 0 0 1 .98.804l.331 1.652a6.993 6.993 0 0 1 1.929 1.115l1.598-.54a1 1 0 0 1 1.186.447l1.18 2.044a1 1 0 0 1-.205 1.251l-1.267 1.113a7.047 7.047 0 0 1 0 2.228l1.267 1.113a1 1 0 0 1 .206 1.25l-1.18 2.045a1 1 0 0 1-1.187.447l-1.598-.54a6.993 6.993 0 0 1-1.929 1.115l-.33 1.652a1 1 0 0 1-.98.804H8.82a1 1 0 0 1-.98-.804l-.331-1.652a6.993 6.993 0 0 1-1.929-1.115l-1.598.54a1 1 0 0 1-1.186-.447l-1.18-2.044a1 1 0 0 1 .205-1.251l1.267-1.114a7.05 7.05 0 0 1 0-2.227L1.821 7.773a1 1 0 0 1-.206-1.25l1.18-2.045a1 1 0 0 1 1.187-.447l1.598.54A6.993 6.993 0 0 1 7.51 3.456l.33-1.652ZM10 13a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z" clip-rule="evenodd" />|

  defp icon_path(:bolt),
    do:
      ~s|<path fill-rule="evenodd" d="M11.983 1.907a.75.75 0 0 0-1.292-.657l-8.5 9.5A.75.75 0 0 0 2.75 12h6.572l-1.305 6.093a.75.75 0 0 0 1.292.657l8.5-9.5A.75.75 0 0 0 17.25 8h-6.572l1.305-6.093Z" clip-rule="evenodd" />|

  defp icon_path(:lifebuoy),
    do:
      ~s|<path fill-rule="evenodd" d="M18 10c0 4.418-3.582 8-8 8s-8-3.582-8-8 3.582-8 8-8 8 3.582 8 8Zm-3.5 0a4.5 4.5 0 1 1-9 0 4.5 4.5 0 0 1 9 0Zm-1.193-3.317-1.59 1.59a3 3 0 0 0-1.078-.62l.49-2.165a6.487 6.487 0 0 1 2.178 1.195Zm-3.713-1.195.49 2.166a3 3 0 0 0-1.078.62l-1.59-1.59a6.487 6.487 0 0 1 2.178-1.196Zm-3.298 2.282 1.59 1.59a3 3 0 0 0-.62 1.078l-2.166-.49a6.487 6.487 0 0 1 1.196-2.178Zm-1.196 3.713 2.166-.49a3 3 0 0 0 .62 1.078l-1.59 1.59a6.487 6.487 0 0 1-1.196-2.178Zm2.282 3.298 1.59-1.59a3 3 0 0 0 1.078.62l-.49 2.166a6.487 6.487 0 0 1-2.178-1.196Zm3.713 1.196-.49-2.166a3 3 0 0 0 1.078-.62l1.59 1.59a6.487 6.487 0 0 1-2.178 1.196Zm3.298-2.282-1.59-1.59a3 3 0 0 0 .62-1.078l2.166.49a6.487 6.487 0 0 1-1.196 2.178Zm1.196-3.713-2.166.49a3 3 0 0 0-.62-1.078l1.59-1.59a6.487 6.487 0 0 1 1.196 2.178Z" clip-rule="evenodd" />|

  defp icon_path(:plus),
    do:
      ~s|<path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" />|

  defp icon_path(:search),
    do:
      ~s|<path fill-rule="evenodd" d="M9 3.5a5.5 5.5 0 1 0 3.44 9.79l2.64 2.64a.75.75 0 0 0 1.06-1.06l-2.64-2.64A5.5 5.5 0 0 0 9 3.5ZM5 9a4 4 0 1 1 8 0 4 4 0 0 1-8 0Z" clip-rule="evenodd" />|

  defp icon_path(_), do: ""

  defp initials_for(text) when is_binary(text) do
    text
    |> String.split(["@", " ", "."], trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      letters -> letters
    end
  end

  defp initials_for(_), do: "?"

  # Silence unused import warning if JS isn't used downstream.
  _ = JS
end
