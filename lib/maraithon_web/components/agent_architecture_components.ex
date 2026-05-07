defmodule MaraithonWeb.AgentArchitectureComponents do
  @moduledoc """
  Shared UI components for agent architecture manifests.
  """

  use Phoenix.Component

  alias Maraithon.AgentArchitecture

  attr :architecture, :map, required: true
  attr :mode, :string, default: "compact", values: ["compact", "full"]

  def architecture_card(assigns) do
    assigns =
      assigns
      |> assign(:metrics, AgentArchitecture.metrics(assigns.architecture))
      |> assign(
        :components,
        AgentArchitecture.preview_components(assigns.architecture, limit: limit(assigns.mode))
      )

    ~H"""
    <section class={section_class(@mode)}>
      <div class={header_class(@mode)}>
        <div class="flex items-start justify-between gap-3">
          <div>
            <p class={eyebrow_class(@mode)}>Architecture</p>
            <h3 class={title_class(@mode)}><%= @architecture.label %></h3>
          </div>
          <span class={category_class(@mode)}>
            <%= @architecture.category %>
          </span>
        </div>
        <p class={summary_class(@mode)}><%= @architecture.summary %></p>
      </div>

      <div class={metrics_class(@mode)}>
        <div :for={metric <- @metrics} class="rounded-xl bg-slate-50 px-3 py-2">
          <p class="font-semibold uppercase tracking-[0.14em] text-slate-500"><%= metric.label %></p>
          <p class="mt-1 text-sm font-semibold text-slate-900"><%= metric.value %></p>
        </div>
      </div>

      <div :if={@mode == "full"} class="border-t border-slate-100 px-4 py-4">
        <div class="mb-3 flex items-center justify-between gap-3 text-xs">
          <span class="font-semibold uppercase tracking-[0.18em] text-slate-500">Runtime contract</span>
          <span class="font-mono text-slate-500"><%= @architecture.contract.behaviour %></span>
        </div>
        <.component_grid components={@components} columns="two" />
      </div>

      <div :if={@mode == "compact"} class="mt-4 space-y-2">
        <.component_grid components={@components} columns="one" />
      </div>
    </section>
    """
  end

  attr :components, :list, required: true
  attr :columns, :string, required: true, values: ["one", "two"]

  defp component_grid(assigns) do
    ~H"""
    <div class={component_grid_class(@columns)}>
      <div :for={component <- @components} class="rounded-xl border border-slate-200 px-3 py-2">
        <div class="flex items-center justify-between gap-3">
          <p class="text-sm font-medium text-slate-900"><%= component.label %></p>
          <span class="rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-slate-500">
            <%= component.kind %>
          </span>
        </div>
        <p class="mt-1 line-clamp-2 text-xs text-slate-500">
          <%= AgentArchitecture.component_detail(component) %>
        </p>
      </div>
    </div>
    """
  end

  defp limit("full"), do: 8
  defp limit(_mode), do: 8

  defp section_class("full"), do: "overflow-hidden rounded-2xl border border-cyan-100 bg-white"
  defp section_class(_mode), do: "rounded-2xl bg-white p-5 shadow"

  defp header_class("full"), do: "border-b border-cyan-100 bg-cyan-50/70 px-4 py-4"
  defp header_class(_mode), do: ""

  defp eyebrow_class("full"),
    do: "text-xs font-semibold uppercase tracking-[0.18em] text-cyan-700"

  defp eyebrow_class(_mode), do: "text-xs font-semibold uppercase tracking-[0.2em] text-slate-500"

  defp title_class("full"), do: "mt-1 text-lg font-semibold text-slate-900"
  defp title_class(_mode), do: "mt-2 text-base font-semibold text-slate-900"

  defp category_class("full"),
    do:
      "rounded-full bg-white px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-cyan-800 shadow-sm"

  defp category_class(_mode),
    do:
      "rounded-full bg-cyan-100 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-cyan-800"

  defp summary_class("full"), do: "mt-2 text-sm text-cyan-900/75"
  defp summary_class(_mode), do: "mt-3 text-sm text-slate-600"

  defp metrics_class("full"), do: "grid grid-cols-2 gap-3 px-4 py-4 text-xs sm:grid-cols-4"
  defp metrics_class(_mode), do: "mt-4 grid grid-cols-2 gap-2 text-xs"

  defp component_grid_class("two"), do: "grid grid-cols-1 gap-2 md:grid-cols-2"
  defp component_grid_class(_columns), do: "space-y-2"
end
