defmodule MaraithonWeb.CoreComponents do
  # Small outline Heroicons used by action controls; rendered without a runtime dependency.
  @action_icons %{
    "hero-arrow-up-right" => "M4.5 19.5l15-15m0 0H8.25m11.25 0v11.25",
    "hero-arrow-up" => "M12 19.5v-15m0 0l-6.75 6.75M12 4.5l6.75 6.75",
    "hero-chevron-down" => "M19.5 8.25L12 15.75l-7.5-7.5",
    "hero-arrow-path" =>
      "M16.023 9.348h4.992V4.356m-.553 10.856A9 9 0 014.038 9.348M3 19.644v-4.992h4.992m-4.44-5.864A9 9 0 0119.962 14.652",
    "hero-calendar-days" =>
      "M6.75 3v2.25m10.5-2.25v2.25M3.75 9h16.5M5.25 5.25h13.5A1.5 1.5 0 0120.25 6.75v12a1.5 1.5 0 01-1.5 1.5H5.25a1.5 1.5 0 01-1.5-1.5v-12a1.5 1.5 0 011.5-1.5zM7.5 12h.008v.008H7.5V12zm4.5 0h.008v.008H12V12zm4.5 0h.008v.008H16.5V12zm-9 4.5h.008v.008H7.5V16.5zm4.5 0h.008v.008H12V16.5z",
    "hero-sparkles" =>
      "M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.091-3.091L2.25 12l2.846-.813a4.5 4.5 0 003.091-3.091L9 5.25l.813 2.846a4.5 4.5 0 003.091 3.091L15.75 12l-2.846.813a4.5 4.5 0 00-3.091 3.091zM18.259 8.715L18 9.75l-.259-1.035a3.375 3.375 0 00-2.456-2.456L14.25 6l1.035-.259a3.375 3.375 0 002.456-2.456L18 2.25l.259 1.035a3.375 3.375 0 002.456 2.456L21.75 6l-1.035.259a3.375 3.375 0 00-2.456 2.456z"
  }
  @moduledoc """
  Core UI components for MaraithonWeb.
  """

  use Phoenix.Component

  attr :name, :string, required: true
  attr :class, :string, default: nil

  def action_icon(assigns) do
    assigns = assign(assigns, :path, Map.fetch!(@action_icons, assigns.name))

    ~H"""
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"
      stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" class={@class}>
      <path d={@path} />
    </svg>
    """
  end

  @doc """
  Catalyst-inspired page heading.
  """
  attr :level, :integer, default: 1
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def heading(assigns) do
    tag = "h#{assigns.level}"
    assigns = assign(assigns, :tag, tag)

    ~H"""
    <.dynamic_tag
      tag_name={@tag}
      class={[
        "text-2xl/8 font-semibold tracking-tight text-zinc-950 sm:text-xl/8",
        @class
      ]}
    >
      <%= render_slot(@inner_block) %>
    </.dynamic_tag>
    """
  end

  @doc """
  Catalyst-inspired muted body text.
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def text(assigns) do
    ~H"""
    <p class={["text-base/6 text-zinc-500 sm:text-sm/6", @class]}>
      <%= render_slot(@inner_block) %>
    </p>
    """
  end

  @doc """
  Catalyst-style page header with optional actions.
  """
  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :string, default: nil
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class={["border-b border-zinc-950/10 pb-5", @class]}>
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <p :if={@eyebrow} class="text-sm/6 font-medium text-zinc-500"><%= @eyebrow %></p>
          <h1 class="mt-1 text-2xl/8 font-semibold tracking-tight text-zinc-950 sm:text-3xl/9">
            <%= @title %>
          </h1>
          <p :if={@subtitle} class="mt-2 max-w-3xl text-sm/6 text-zinc-600"><%= @subtitle %></p>
        </div>
        <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
          <%= render_slot(@actions) %>
        </div>
      </div>
    </header>
    """
  end

  @doc """
  Catalyst-style divider.
  """
  attr :class, :string, default: nil

  def divider(assigns) do
    ~H"""
    <hr class={["border-t border-zinc-950/10", @class]} />
    """
  end

  @doc """
  Catalyst-inspired panel container.
  """
  attr :class, :string, default: nil
  attr :body_class, :string, default: "px-5 py-5"
  attr :rest, :global
  slot :header
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class={["overflow-hidden rounded-lg border border-zinc-950/10 bg-white", @class]} {@rest}>
      <div :if={@header != []} class="border-b border-zinc-950/10 px-5 py-5">
        <%= render_slot(@header) %>
      </div>
      <div class={@body_class}>
        <%= render_slot(@inner_block) %>
      </div>
    </section>
    """
  end

  @doc """
  Catalyst-style alert.
  """
  attr :color, :string, default: "amber"
  attr :title, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def alert(assigns) do
    assigns = assign(assigns, :classes, alert_class(assigns.color, assigns.class))

    ~H"""
    <section class={@classes}>
      <p :if={@title} class="font-medium"><%= @title %></p>
      <div class={[@title && "mt-1", "text-sm/6"]}>
        <%= render_slot(@inner_block) %>
      </div>
    </section>
    """
  end

  @doc """
  Runner button recipes with the existing Phoenix component API.
  """
  attr :type, :string, default: "button"
  attr :href, :string, default: nil
  attr :patch, :string, default: nil
  attr :navigate, :string, default: nil
  attr :variant, :string, default: "solid"
  attr :color, :string, default: "dark"
  attr :disabled, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(target rel download form formnovalidate)
  slot :inner_block, required: true

  def button(assigns) do
    assigns =
      assign(assigns, :classes, button_class(assigns.variant, assigns.color, assigns.class))

    ~H"""
    <.link :if={@patch} patch={@patch} class={@classes} {@rest}>
      <span class="absolute left-1/2 top-1/2 size-[max(100%,44px)] -translate-x-1/2 -translate-y-1/2 sm:hidden" aria-hidden="true" />
      <%= render_slot(@inner_block) %>
    </.link>
    <.link :if={@navigate} navigate={@navigate} class={@classes} {@rest}>
      <span class="absolute left-1/2 top-1/2 size-[max(100%,44px)] -translate-x-1/2 -translate-y-1/2 sm:hidden" aria-hidden="true" />
      <%= render_slot(@inner_block) %>
    </.link>
    <a :if={@href && !@patch && !@navigate} href={@href} class={@classes} {@rest}>
      <span class="absolute left-1/2 top-1/2 size-[max(100%,44px)] -translate-x-1/2 -translate-y-1/2 sm:hidden" aria-hidden="true" />
      <%= render_slot(@inner_block) %>
    </a>
    <button :if={!@href && !@patch && !@navigate} type={@type} disabled={@disabled} class={@classes} {@rest}>
      <span class="absolute left-1/2 top-1/2 size-[max(100%,44px)] -translate-x-1/2 -translate-y-1/2 sm:hidden" aria-hidden="true" />
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  @doc """
  Catalyst-inspired badge.
  """
  attr :color, :string, default: "zinc"
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    assigns = assign(assigns, :classes, badge_class(assigns.color, assigns.class))

    ~H"""
    <span class={["runner-badge", @classes]} data-color={@color}>
      <%= render_slot(@inner_block) %>
    </span>
    """
  end

  @doc """
  Catalyst-inspired table shell.
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def table(assigns) do
    ~H"""
    <div class={["flow-root", @class]}>
      <div class="-mx-5 overflow-x-auto whitespace-nowrap [--gutter:1.25rem]">
        <div class="inline-block min-w-full align-middle sm:px-5">
          <table class="min-w-full text-left text-sm/6 text-zinc-950">
            <%= render_slot(@inner_block) %>
          </table>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Catalyst-style description list.
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def description_list(assigns) do
    ~H"""
    <dl class={["grid grid-cols-1 text-sm/6 sm:grid-cols-[min(50%,20rem)_auto]", @class]}>
      <%= render_slot(@inner_block) %>
    </dl>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def description_term(assigns) do
    ~H"""
    <dt class={["col-start-1 border-t border-zinc-950/5 pt-3 text-zinc-500 first:border-none sm:py-3", @class]}>
      <%= render_slot(@inner_block) %>
    </dt>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def description_details(assigns) do
    ~H"""
    <dd class={["pt-1 pb-3 text-zinc-950 sm:border-t sm:border-zinc-950/5 sm:py-3 sm:[&:nth-of-type(1)]:border-none", @class]}>
      <%= render_slot(@inner_block) %>
    </dd>
    """
  end

  @doc """
  Catalyst-style form field wrapper.
  """
  attr :label, :string, required: true
  attr :description, :string, default: nil
  attr :error, :string, default: nil
  attr :for, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def field(assigns) do
    ~H"""
    <div class={["[&>[data-slot=control]]:mt-3", @class]}>
      <label data-slot="label" for={@for} class="text-sm/6 font-medium text-zinc-950">
        <%= @label %>
      </label>
      <p :if={@description} data-slot="description" class="mt-1 text-sm/6 text-zinc-500">
        <%= @description %>
      </p>
      <div data-slot="control">
        <%= render_slot(@inner_block) %>
      </div>
      <p :if={@error} data-slot="error" class="mt-3 text-sm/6 text-red-600"><%= @error %></p>
    </div>
    """
  end

  @doc """
  Catalyst-style text input.
  """
  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :type, :string, default: "text"
  attr :value, :any, default: nil
  attr :class, :string, default: nil
  attr :autocomplete, :string, default: nil
  attr :min, :any, default: nil
  attr :max, :any, default: nil
  attr :maxlength, :any, default: nil
  attr :required, :boolean, default: false
  attr :rest, :global, include: ~w(readonly)

  def c_input(assigns) do
    ~H"""
    <span data-slot="control" class={["relative block w-full", @class]}>
      <input
        id={@id}
        name={@name}
        type={@type}
        value={@value}
        autocomplete={@autocomplete}
        min={@min}
        max={@max}
        maxlength={@maxlength}
        required={@required}
        class="relative block w-full appearance-none rounded-lg border border-zinc-950/10 bg-white px-3.5 py-2.5 text-base/6 text-zinc-950 shadow-sm placeholder:text-zinc-500 focus:border-clay-500 focus:outline-none focus:ring-2 focus:ring-clay-500/20 sm:px-3 sm:py-1.5 sm:text-sm/6 disabled:opacity-50"
        {@rest}
      />
    </span>
    """
  end

  @doc """
  Catalyst-style textarea.
  """
  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :rows, :integer, default: 4
  attr :class, :string, default: nil
  attr :maxlength, :any, default: nil
  attr :required, :boolean, default: false
  attr :rest, :global, include: ~w(readonly)

  def c_textarea(assigns) do
    ~H"""
    <textarea
      id={@id}
      name={@name}
      rows={@rows}
      maxlength={@maxlength}
      required={@required}
      class={["block w-full resize-y rounded-lg border border-zinc-950/10 bg-white px-3.5 py-2.5 text-base/6 text-zinc-950 shadow-sm placeholder:text-zinc-500 focus:border-clay-500 focus:outline-none focus:ring-2 focus:ring-clay-500/20 sm:px-3 sm:py-1.5 sm:text-sm/6", @class]}
      {@rest}
    ><%= @value %></textarea>
    """
  end

  @doc """
  Catalyst-style select.
  """
  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :class, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true

  def c_select(assigns) do
    ~H"""
    <select
      id={@id}
      name={@name}
      value={@value}
      disabled={@disabled}
      class={["block w-full appearance-none rounded-lg border border-zinc-950/10 bg-white px-3.5 py-2.5 text-base/6 text-zinc-950 shadow-sm focus:border-clay-500 focus:outline-none focus:ring-2 focus:ring-clay-500/20 sm:px-3 sm:py-1.5 sm:text-sm/6", @class]}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </select>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def table_head(assigns) do
    ~H"""
    <thead class={["text-zinc-500", @class]}>
      <%= render_slot(@inner_block) %>
    </thead>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def table_body(assigns) do
    ~H"""
    <tbody class={@class}>
      <%= render_slot(@inner_block) %>
    </tbody>
    """
  end

  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def table_row(assigns) do
    ~H"""
    <tr class={@class} {@rest}>
      <%= render_slot(@inner_block) %>
    </tr>
    """
  end

  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def table_header(assigns) do
    ~H"""
    <th
      class={[
        "border-b border-b-zinc-950/10 px-4 py-2 font-medium first:pl-1 last:pr-1",
        @class
      ]}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </th>
    """
  end

  attr :class, :string, default: nil
  attr :colspan, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def table_cell(assigns) do
    ~H"""
    <td
      colspan={@colspan}
      class={[
        "relative border-b border-zinc-950/5 px-4 py-4 first:pl-1 last:pr-1",
        @class
      ]}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </td>
    """
  end

  @doc """
  Renders flash notices.
  """
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div class="fixed top-4 right-4 z-50 space-y-2">
      <%= if info = flash_value(@flash, :info) do %>
        <div class="rounded-md bg-blue-50 p-4 shadow-lg">
          <div class="flex">
            <div class="ml-3">
              <p class="text-sm font-medium text-blue-800"><%= info %></p>
            </div>
          </div>
        </div>
      <% end %>
      <%= if error = flash_value(@flash, :error) do %>
        <div class="rounded-md bg-red-50 p-4 shadow-lg">
          <div class="flex">
            <div class="ml-3">
              <p class="text-sm font-medium text-red-800"><%= error %></p>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp flash_value(flash, key) when is_map(flash) do
    Map.get(flash, Atom.to_string(key)) || Map.get(flash, key)
  end

  defp flash_value(_flash, _key), do: nil

  @doc """
  Renders a badge with status colors.
  """
  attr :status, :string, required: true

  def status_badge(assigns) do
    color =
      case assigns.status do
        "running" -> "emerald"
        "stopped" -> "zinc"
        "error" -> "red"
        _ -> "amber"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <.badge color={@color}>
      <%= @status %>
    </.badge>
    """
  end

  defp alert_class(color, extra) do
    color_class =
      case color do
        "red" -> "border-red-200 bg-red-50 text-red-800"
        "rose" -> "border-rose-200 bg-rose-50 text-rose-800"
        "blue" -> "border-blue-200 bg-blue-50 text-blue-900"
        "cyan" -> "border-cyan-200 bg-cyan-50 text-cyan-900"
        "emerald" -> "border-emerald-200 bg-emerald-50 text-emerald-900"
        "green" -> "border-green-200 bg-green-50 text-green-900"
        _ -> "border-amber-200 bg-amber-50 text-amber-900"
      end

    ["rounded-lg border px-4 py-3 shadow-sm", color_class, extra]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp button_class(variant, color, extra) do
    base = "runner-button"

    style =
      case {variant, color} do
        {"outline", _} -> "runner-button-secondary"
        {"plain", _} -> "runner-button-tertiary"
        {"solid", "red"} -> "runner-button-destructive"
        {"solid", _} -> "runner-button-primary"
      end

    [base, style, extra]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp badge_class(_color, extra) do
    ["inline-flex items-center gap-x-1.5 rounded-md px-1.5 py-0.5 text-xs font-medium", extra]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end
end
