defmodule MaraithonWeb.InsightsLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Crm
  alias Maraithon.Crm.Insights, as: CrmInsights

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Insights",
       current_path: "/insights",
       crm_insights: empty_insights(),
       hidden_relationship_suggestion_ids: MapSet.new()
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply,
     socket
     |> assign(:current_path, current_path_from_uri(uri))
     |> refresh_crm_insights()}
  end

  @impl true
  def handle_event("apply_relationship_suggestion", %{"id" => suggestion_id}, socket) do
    user_id = current_user_id(socket)
    suggestion = fresh_relationship_suggestion(user_id, suggestion_id)

    socket =
      case suggestion do
        nil ->
          socket
          |> refresh_crm_insights()
          |> put_flash(:error, "That relationship suggestion is no longer available.")

        suggestion ->
          apply_relationship_suggestion(socket, suggestion)
      end

    {:noreply, socket}
  end

  def handle_event("hide_relationship_suggestion", %{"id" => suggestion_id}, socket) do
    {:noreply,
     socket
     |> assign(
       :hidden_relationship_suggestion_ids,
       MapSet.put(socket.assigns.hidden_relationship_suggestion_ids, suggestion_id)
     )
     |> refresh_crm_insights()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-6">
        <.page_header
          title="Insights"
          subtitle="CRM cleanup and relationship suggestions Maraithon can review before changing your data."
        >
          <:actions>
            <.button navigate="/operator/people" variant="outline">Open People</.button>
          </:actions>
        </.page_header>

        <dl class="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <.insight_stat label="Open CRM insights" value={@crm_insights.total_count} />
          <.insight_stat label="Duplicate suggestions" value={length(@crm_insights.duplicate_suggestions)} />
          <.insight_stat label="Relationship suggestions" value={length(@crm_insights.relationship_suggestions)} />
        </dl>

        <.panel id="crm-cleanup" body_class="p-0">
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 class="text-base/7 font-semibold text-zinc-950">CRM cleanup</h2>
                <p class="mt-1 text-sm/6 text-zinc-500">
                  Possible duplicates and records that may be safe to combine after review.
                </p>
              </div>
              <.badge color="zinc"><%= length(@crm_insights.duplicate_suggestions) %></.badge>
            </div>
          </:header>

          <.duplicate_suggestion_list suggestions={@crm_insights.duplicate_suggestions} />
        </.panel>

        <.panel id="relationship-suggestions" body_class="p-0">
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 class="text-base/7 font-semibold text-zinc-950">Relationship suggestions</h2>
                <p class="mt-1 text-sm/6 text-zinc-500">
                  Evidence-backed labels you can apply to CRM people.
                </p>
              </div>
              <.badge color="zinc"><%= length(@crm_insights.relationship_suggestions) %></.badge>
            </div>
          </:header>

          <.relationship_suggestion_list suggestions={@crm_insights.relationship_suggestions} />
        </.panel>

        <.panel :if={@crm_insights.total_count == 0} body_class="px-5 py-8">
          <div class="max-w-2xl">
            <h2 class="text-sm/6 font-semibold text-zinc-950">No CRM insights right now.</h2>
            <p class="mt-1 text-sm/6 text-zinc-500">
              The CRM looks clean for this pass. Review People directly if you want to edit relationships or merge contacts.
            </p>
            <.button navigate="/operator/people" variant="outline" class="mt-4">
              Open People
            </.button>
          </div>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp insight_stat(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-950/10 bg-white px-4 py-4 shadow-sm">
      <dt class="text-sm/6 text-zinc-500"><%= @label %></dt>
      <dd class="mt-2 text-2xl/8 font-semibold tracking-tight text-zinc-950"><%= @value %></dd>
    </div>
    """
  end

  attr :suggestions, :list, required: true

  defp duplicate_suggestion_list(assigns) do
    ~H"""
    <div>
      <div :if={@suggestions == []} class="px-5 py-8">
        <p class="text-sm/6 text-zinc-500">No duplicate CRM people found.</p>
      </div>

      <div :if={@suggestions != []} class="divide-y divide-zinc-950/5">
        <div :for={suggestion <- @suggestions} class="px-5 py-4">
          <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <.badge color="amber">Duplicate</.badge>
                <span class="text-xs/5 text-zinc-500">
                  confidence <%= format_confidence(suggestion.confidence) %>
                </span>
              </div>
              <h3 class="mt-2 text-sm/6 font-semibold text-zinc-950"><%= suggestion.title %></h3>
              <p class="mt-1 text-sm/6 text-zinc-600"><%= suggestion.summary %></p>
              <.evidence_list evidence={suggestion.evidence} />
            </div>
            <div class="flex justify-start lg:justify-end">
              <.button navigate={suggestion.action.path} variant="outline">
                Review in People
              </.button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :suggestions, :list, required: true

  defp relationship_suggestion_list(assigns) do
    ~H"""
    <div>
      <div :if={@suggestions == []} class="px-5 py-8">
        <p class="text-sm/6 text-zinc-500">No relationship suggestions found.</p>
      </div>

      <div :if={@suggestions != []} class="divide-y divide-zinc-950/5">
        <div :for={suggestion <- @suggestions} id={"relationship-suggestion-#{suggestion.id}"} class="px-5 py-4">
          <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <.badge color="blue">Relationship</.badge>
                <span class="text-xs/5 text-zinc-500">
                  confidence <%= format_confidence(suggestion.confidence) %>
                </span>
              </div>
              <h3 class="mt-2 text-sm/6 font-semibold text-zinc-950"><%= suggestion.title %></h3>
              <p class="mt-1 text-sm/6 text-zinc-600"><%= suggestion.summary %></p>
              <.evidence_list evidence={suggestion.evidence} />
            </div>
            <div class="flex flex-wrap justify-start gap-2 lg:justify-end">
              <.button
                type="button"
                phx-click="apply_relationship_suggestion"
                phx-value-id={suggestion.id}
              >
                Apply relationship
              </.button>
              <.button navigate={suggestion.review_path} variant="outline">
                Review person
              </.button>
              <.button
                type="button"
                phx-click="hide_relationship_suggestion"
                phx-value-id={suggestion.id}
                variant="plain"
              >
                Hide for now
              </.button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :evidence, :list, required: true

  defp evidence_list(assigns) do
    ~H"""
    <ul :if={@evidence != []} class="mt-3 space-y-2">
      <li :for={item <- @evidence} class="rounded-lg border border-zinc-950/10 bg-zinc-50 px-3 py-2">
        <div class="flex flex-wrap items-center gap-2">
          <span class="text-xs/5 font-medium text-zinc-500"><%= item.source %></span>
          <span class="text-xs/5 font-medium text-zinc-950"><%= item.label %></span>
        </div>
        <p class="mt-1 text-sm/6 text-zinc-600"><%= item.detail %></p>
      </li>
    </ul>
    """
  end

  defp refresh_crm_insights(socket) do
    insights = CrmInsights.list_for_user(current_user_id(socket))
    hidden_ids = socket.assigns.hidden_relationship_suggestion_ids

    relationship_suggestions =
      Enum.reject(insights.relationship_suggestions, &MapSet.member?(hidden_ids, &1.id))

    assign(socket,
      crm_insights: %{
        insights
        | relationship_suggestions: relationship_suggestions,
          total_count: length(insights.duplicate_suggestions) + length(relationship_suggestions)
      }
    )
  end

  defp fresh_relationship_suggestion(user_id, suggestion_id) do
    user_id
    |> CrmInsights.list_for_user()
    |> Map.get(:relationship_suggestions, [])
    |> Enum.find(&(&1.id == suggestion_id))
  end

  defp apply_relationship_suggestion(socket, suggestion) do
    person = suggestion.person

    metadata =
      person.metadata
      |> Kernel.||(%{})
      |> Map.merge(%{
        "relationship_context_source" => "crm_insights",
        "relationship_context_updated_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "relationship_suggestion_id" => suggestion.id,
        "relationship_suggestion_confidence" => suggestion.confidence
      })

    attrs = %{
      "id" => person.id,
      "display_name" => person.display_name,
      "relationship" => suggestion.relationship,
      "metadata" => metadata
    }

    case Crm.upsert_person(current_user_id(socket), attrs) do
      {:ok, updated} ->
        socket
        |> put_flash(:info, "Updated relationship for #{updated.display_name}.")
        |> refresh_crm_insights()

      {:error, reason} ->
        put_flash(socket, :error, "Could not apply relationship: #{inspect(reason)}")
    end
  end

  defp empty_insights do
    %{duplicate_suggestions: [], relationship_suggestions: [], total_count: 0}
  end

  defp current_path_from_uri(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "/insights"
      "" -> "/insights"
      path -> path
    end
  end

  defp format_confidence(value) when is_float(value), do: "#{round(value * 100)}%"
  defp format_confidence(value) when is_integer(value), do: "#{value}%"
  defp format_confidence(_value), do: "unknown"

  defp current_user_id(socket), do: socket.assigns.current_user.id
end
