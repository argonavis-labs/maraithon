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
            <p class={eyebrow_class(@mode)}>Operating model</p>
            <h3 class={title_class(@mode)}><%= @architecture.label %></h3>
          </div>
          <span class={category_class(@mode)}>
            <%= @architecture.category %>
          </span>
        </div>
        <p class={summary_class(@mode)}><%= @architecture.summary %></p>
      </div>

      <dl class={metrics_class(@mode)}>
        <div :for={metric <- @metrics} class="flex items-baseline justify-between gap-3">
          <dt class="text-xs/5 text-zinc-500"><%= metric.label %></dt>
          <dd class="text-sm/6 font-medium text-zinc-950"><%= metric.value %></dd>
        </div>
      </dl>

      <div :if={@mode == "full"} class="border-t border-zinc-950/10 px-4 py-4">
        <div class="mb-3 flex items-center justify-between gap-3 text-xs/5">
          <span class="font-medium text-zinc-500">Run controls</span>
          <span class="text-zinc-500"><%= run_controls_summary(@architecture) %></span>
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
      <div :for={component <- @components} class="rounded-lg border border-zinc-950/10 px-3 py-2">
        <div class="flex items-center justify-between gap-3">
          <p class="text-sm/6 font-medium text-zinc-950"><%= component.label %></p>
          <span class="inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-600">
            <%= component_kind_label(component.kind) %>
          </span>
        </div>
        <p class="mt-1 line-clamp-2 text-xs/5 text-zinc-500">
          <%= AgentArchitecture.component_detail(component) %>
        </p>
      </div>
    </div>
    """
  end

  defp limit("full"), do: 12
  defp limit(_mode), do: 10

  defp section_class("full"),
    do: "overflow-hidden rounded-lg border border-zinc-950/10 bg-white shadow-sm"

  defp section_class(_mode), do: "rounded-lg border border-zinc-950/10 bg-white p-5 shadow-sm"

  defp header_class("full"), do: "border-b border-zinc-950/10 bg-zinc-50 px-4 py-4"
  defp header_class(_mode), do: ""

  defp eyebrow_class("full"), do: "text-xs/5 font-medium text-zinc-500"

  defp eyebrow_class(_mode), do: "text-xs/5 font-medium text-zinc-500"

  defp title_class("full"), do: "mt-1 text-base/7 font-semibold text-zinc-950"
  defp title_class(_mode), do: "mt-2 text-base/7 font-semibold text-zinc-950"

  defp category_class("full"),
    do:
      "inline-flex rounded-md bg-white px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700 shadow-sm ring-1 ring-zinc-950/10"

  defp category_class(_mode),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp summary_class("full"), do: "mt-2 text-sm/6 text-zinc-600"
  defp summary_class(_mode), do: "mt-3 text-sm/6 text-zinc-600"

  defp metrics_class("full"),
    do: "grid grid-cols-1 gap-y-2 px-4 py-4 sm:grid-cols-2 sm:gap-x-6"

  defp metrics_class(_mode),
    do: "mt-4 divide-y divide-zinc-950/5 border-y border-zinc-950/5 [&>div]:py-2"

  defp component_grid_class("two"), do: "grid grid-cols-1 gap-2 md:grid-cols-2"
  defp component_grid_class(_columns), do: "space-y-2"

  defp component_kind_label(:runtime), do: "Service"
  defp component_kind_label(:behavior), do: "Automation"
  defp component_kind_label(:skill), do: "Skill"
  defp component_kind_label(:tool), do: "Action"
  defp component_kind_label(:subscription), do: "Topic"
  defp component_kind_label(:memory), do: "Memory"
  defp component_kind_label(:scope), do: "Scope"
  defp component_kind_label(:connector), do: "Connection"
  defp component_kind_label(kind), do: kind |> to_string() |> String.capitalize()

  defp run_controls_summary(architecture) do
    components = Map.get(architecture, :components, [])
    action_count = count_components(components, :tool)
    topic_count = count_components(components, :subscription)

    "#{pluralize(action_count, "approved action")} / #{pluralize(topic_count, "watched topic")}"
  end

  defp count_components(components, kind), do: Enum.count(components, &(&1.kind == kind))

  defp pluralize(1, label), do: "1 #{label}"
  defp pluralize(count, label), do: "#{count} #{label}s"
end
