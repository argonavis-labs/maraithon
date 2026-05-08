defmodule MaraithonWeb.AgentLibraryLive do
  @moduledoc """
  Marketing-style detail page for a single agent template in the
  library. Lets the operator read the full description, see what each
  agent reads from / writes to, which connectors it needs, and install
  it with a single click.
  """

  use MaraithonWeb, :live_view

  alias Maraithon.AgentBuilder
  alias Maraithon.Connections
  alias Maraithon.Runtime

  @impl true
  def mount(%{"behavior" => behavior_id}, _session, socket) do
    case AgentBuilder.behavior_spec(behavior_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Agent template not found")
         |> push_navigate(to: ~p"/agents")}

      spec ->
        provider_map = provider_status_map(socket)

        {:ok,
         assign(socket,
           page_title: spec.label,
           current_path: "/agents",
           current_user: socket.assigns[:current_user],
           spec: spec,
           requirements: connector_requirements(spec, provider_map)
         )}
    end
  end

  defp provider_status_map(socket) do
    case current_user_id(socket) do
      nil ->
        %{}

      user_id ->
        case Connections.safe_dashboard_snapshot(user_id) do
          %{providers: providers} when is_list(providers) ->
            providers
            |> Enum.map(fn provider ->
              {to_string(provider.provider), Map.get(provider, :status, :not_configured)}
            end)
            |> Map.new()

          _ ->
            %{}
        end
    end
  end

  @impl true
  def handle_event("install", _params, socket) do
    user_id = current_user_id(socket)
    spec = socket.assigns.spec
    launch = Map.put(AgentBuilder.default_launch_params(), "behavior", spec.id)

    with {:ok, params} <- AgentBuilder.build_start_params(launch, user_id),
         {:ok, agent} <- Runtime.start_agent(params) do
      {:noreply,
       socket
       |> put_flash(:info, "Installed #{display_name(agent)}")
       |> push_navigate(to: ~p"/agents?id=#{agent.id}")}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, "Could not install: #{message}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, "Could not install: #{changeset_errors(changeset)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not install: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-12">
        <header>
          <.link
            navigate={~p"/agents"}
            class="inline-flex items-center gap-1 text-xs/5 font-medium text-zinc-500 hover:text-zinc-950"
          >
            <span aria-hidden="true">←</span> Library
          </.link>

          <div class="mt-2 flex flex-wrap items-end justify-between gap-4">
            <div class="min-w-0 max-w-3xl">
              <div class="flex items-center gap-2">
                <span class="inline-flex items-center rounded-md bg-zinc-100 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700">
                  <%= @spec.category %>
                </span>
                <span class="text-xs/5 text-zinc-500"><%= @spec.id %></span>
              </div>
              <h1 class="mt-2 text-2xl/8 font-semibold tracking-tight text-zinc-950 sm:text-2xl/8">
                <%= @spec.label %>
              </h1>
              <p class="mt-2 text-base/7 text-zinc-600">
                <%= @spec.summary %>
              </p>
            </div>
            <form phx-submit="install" class="shrink-0">
              <.button type="submit" phx-disable-with="Installing...">
                Install agent
              </.button>
            </form>
          </div>
        </header>

        <div class="grid grid-cols-1 gap-12 lg:grid-cols-2">
          <section>
            <div class="border-b border-zinc-950/10 pb-1">
              <h2 class="text-base/7 font-semibold text-zinc-950">What goes in</h2>
            </div>
            <ul role="list" class="mt-2 divide-y divide-zinc-950/5">
              <li :for={line <- @spec.inputs} class="py-2.5 text-sm/6 text-zinc-700">
                <%= line %>
              </li>
            </ul>
          </section>

          <section>
            <div class="border-b border-zinc-950/10 pb-1">
              <h2 class="text-base/7 font-semibold text-zinc-950">What comes out</h2>
            </div>
            <ul role="list" class="mt-2 divide-y divide-zinc-950/5">
              <li :for={line <- @spec.outputs} class="py-2.5 text-sm/6 text-zinc-700">
                <%= line %>
              </li>
            </ul>
          </section>
        </div>

        <section :if={@requirements != []}>
          <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
            <h2 class="text-base/7 font-semibold text-zinc-950">Connected apps required</h2>
            <.link
              navigate={~p"/connectors"}
              class="text-xs/5 font-medium text-zinc-500 hover:text-zinc-950"
            >
              Manage connectors →
            </.link>
          </div>
          <ul role="list" class="mt-2 divide-y divide-zinc-950/5">
            <li
              :for={req <- @requirements}
              class="flex flex-wrap items-start justify-between gap-3 py-3"
            >
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <p class="text-sm/6 font-medium text-zinc-950"><%= req.label %></p>
                  <span
                    :if={not req.required?}
                    class="text-xs/5 text-zinc-500"
                  >Optional</span>
                </div>
                <p :if={req.description} class="mt-0.5 text-sm/6 text-zinc-600">
                  <%= req.description %>
                </p>
              </div>
              <.badge
                color={req.status_color}
                class="whitespace-nowrap"
              >
                <%= req.status_label %>
              </.badge>
            </li>
          </ul>
        </section>

        <section :if={@spec.suggestions != []}>
          <div class="border-b border-zinc-950/10 pb-1">
            <h2 class="text-base/7 font-semibold text-zinc-950">Suggested setup</h2>
          </div>
          <ul role="list" class="mt-2 list-disc space-y-1.5 pl-5 text-sm/6 text-zinc-700">
            <li :for={tip <- @spec.suggestions}><%= tip %></li>
          </ul>
        </section>

        <section class="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-zinc-950/10 bg-zinc-50 px-5 py-4">
          <div>
            <h2 class="text-sm/6 font-semibold text-zinc-950">Ready to install <%= @spec.label %>?</h2>
            <p class="mt-0.5 text-sm/6 text-zinc-500">
              We'll spin it up with sensible defaults. You can edit the prompt and budgets afterwards.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <.link
              navigate={~p"/agents/new?behavior=#{@spec.id}"}
              class="text-xs/5 font-medium text-zinc-500 hover:text-zinc-950"
            >
              Customize first →
            </.link>
            <form phx-submit="install">
              <.button type="submit" phx-disable-with="Installing...">
                Install agent
              </.button>
            </form>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp connector_requirements(%{requirements: requirements}, provider_map) do
    requirements
    |> Enum.filter(&connector_requirement?/1)
    |> Enum.map(&decorate_requirement(&1, provider_map))
  end

  defp connector_requirements(_spec, _map), do: []

  defp connector_requirement?(%{kind: kind, provider: provider})
       when kind in [:provider, :provider_service] and is_binary(provider),
       do: true

  defp connector_requirement?(_), do: false

  defp decorate_requirement(req, provider_map) do
    status = Map.get(provider_map, req.provider, :not_configured)

    Map.merge(req, %{
      status: status,
      status_label: status_label(status),
      status_color: status_color(status)
    })
  end

  defp status_label(:connected), do: "Connected"
  defp status_label(:partial), do: "Partial"
  defp status_label(:needs_refresh), do: "Needs refresh"
  defp status_label(:disconnected), do: "Disconnected"
  defp status_label(:not_configured), do: "Not configured"
  defp status_label(_), do: "Unknown"

  defp status_color(:connected), do: "emerald"
  defp status_color(:partial), do: "amber"
  defp status_color(:needs_refresh), do: "rose"
  defp status_color(_), do: "zinc"

  defp current_user_id(socket) do
    case socket.assigns[:current_user] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp display_name(%{config: %{"name" => name}}) when is_binary(name) and name != "", do: name
  defp display_name(%{behavior: behavior}), do: behavior
  defp display_name(_), do: "agent"

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end
end
