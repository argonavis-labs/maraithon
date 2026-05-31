defmodule MaraithonWeb.InsightsLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Crm
  alias Maraithon.Crm.Insights, as: CrmInsights
  alias MaraithonWeb.OperationFailureCopy

  @family_relationship_suggestion_metadata %{
    "daughter" => %{
      "relationship_domain" => "family",
      "relationship_preset" => "child",
      "relationship_preset_label" => "Child",
      "family_member" => true,
      "family_role" => "child",
      "family_proxy" => false,
      "dependent_context" => true,
      "sensitivity" => "child_family"
    },
    "son" => %{
      "relationship_domain" => "family",
      "relationship_preset" => "child",
      "relationship_preset_label" => "Child",
      "family_member" => true,
      "family_role" => "child",
      "family_proxy" => false,
      "dependent_context" => true,
      "sensitivity" => "child_family"
    },
    "wife" => %{
      "relationship_domain" => "family",
      "relationship_preset" => "spouse_partner",
      "relationship_preset_label" => "Spouse / partner",
      "family_member" => true,
      "family_role" => "spouse_partner",
      "family_proxy" => false,
      "sensitivity" => "family"
    },
    "husband" => %{
      "relationship_domain" => "family",
      "relationship_preset" => "spouse_partner",
      "relationship_preset_label" => "Spouse / partner",
      "family_member" => true,
      "family_role" => "spouse_partner",
      "family_proxy" => false,
      "sensitivity" => "family"
    },
    "spouse" => %{
      "relationship_domain" => "family",
      "relationship_preset" => "spouse_partner",
      "relationship_preset_label" => "Spouse / partner",
      "family_member" => true,
      "family_role" => "spouse_partner",
      "family_proxy" => false,
      "sensitivity" => "family"
    },
    "mother-in-law" => %{
      "relationship_domain" => "family",
      "relationship_preset" => "extended_family",
      "relationship_preset_label" => "Extended family",
      "family_member" => true,
      "family_role" => "extended_family",
      "family_proxy" => false,
      "sensitivity" => "family"
    },
    "father-in-law" => %{
      "relationship_domain" => "family",
      "relationship_preset" => "extended_family",
      "relationship_preset_label" => "Extended family",
      "family_member" => true,
      "family_role" => "extended_family",
      "family_proxy" => false,
      "sensitivity" => "family"
    }
  }

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

  def handle_event("merge_duplicate_suggestion", %{"id" => suggestion_id}, socket) do
    user_id = current_user_id(socket)
    suggestion = fresh_duplicate_suggestion(user_id, suggestion_id)

    socket =
      case suggestion do
        nil ->
          socket
          |> refresh_crm_insights()
          |> put_flash(:error, "That duplicate suggestion is no longer available.")

        suggestion ->
          merge_duplicate_suggestion(socket, suggestion)
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-6">
        <.page_header
          title="Insights"
          subtitle="People cleanup and relationship suggestions Maraithon can review before changing your data."
        >
          <:actions>
            <.button navigate="/operator/people" variant="outline">Open People</.button>
          </:actions>
        </.page_header>

        <dl class="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <.insight_stat label="Open people insights" value={@crm_insights.total_count} />
          <.insight_stat label="Duplicate suggestions" value={length(@crm_insights.duplicate_suggestions)} />
          <.insight_stat label="Relationship suggestions" value={length(@crm_insights.relationship_suggestions)} />
        </dl>

        <.panel id="crm-cleanup" body_class="p-0">
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 class="text-base/7 font-semibold text-zinc-950">People cleanup</h2>
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
                  Evidence-backed labels you can apply to people.
                </p>
              </div>
              <.badge color="zinc"><%= length(@crm_insights.relationship_suggestions) %></.badge>
            </div>
          </:header>

          <.relationship_suggestion_list suggestions={@crm_insights.relationship_suggestions} />
        </.panel>

        <.panel :if={@crm_insights.total_count == 0} body_class="px-5 py-8">
          <div class="max-w-2xl">
            <h2 class="text-sm/6 font-semibold text-zinc-950">
              Checked records did not surface people insights.
            </h2>
            <p class="mt-1 text-sm/6 text-zinc-500">
              Review People directly if you want to edit relationships or merge contacts manually.
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
        <p class="text-sm/6 text-zinc-500">
          Merge suggestions will appear here after checked records point to the same person.
        </p>
      </div>

      <div :if={@suggestions != []} class="divide-y divide-zinc-950/5">
        <div :for={suggestion <- @suggestions} class="px-5 py-4">
          <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <.badge color="amber">Duplicate</.badge>
              </div>
              <h3 class="mt-2 text-sm/6 font-semibold text-zinc-950"><%= suggestion.title %></h3>
              <p class="mt-1 text-sm/6 text-zinc-600"><%= suggestion.summary %></p>
              <p class="mt-2 text-sm/6 text-zinc-950">
                Suggested action:
                <span class="font-medium">
                  merge these records and keep <%= duplicate_survivor_name(suggestion) %>.
                </span>
              </p>
              <.evidence_list evidence={suggestion.evidence} />
            </div>
            <div class="flex flex-wrap justify-start gap-2 lg:justify-end">
              <.button
                type="button"
                phx-click="merge_duplicate_suggestion"
                phx-value-id={suggestion.id}
              >
                Merge contacts
              </.button>
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
        <p class="text-sm/6 text-zinc-500">
          Relationship suggestions will appear here after checked evidence points to a label you can confirm.
        </p>
      </div>

      <div :if={@suggestions != []} class="divide-y divide-zinc-950/5">
        <div :for={suggestion <- @suggestions} id={"relationship-suggestion-#{suggestion.id}"} class="px-5 py-4">
          <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <.badge color="blue">Relationship</.badge>
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

  defp fresh_duplicate_suggestion(user_id, suggestion_id) do
    user_id
    |> CrmInsights.list_for_user()
    |> Map.get(:duplicate_suggestions, [])
    |> Enum.find(&(&1.id == suggestion_id))
  end

  defp apply_relationship_suggestion(socket, suggestion) do
    person = suggestion.person

    metadata = relationship_apply_metadata(person, suggestion)

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
        put_flash(socket, :error, OperationFailureCopy.relationship(:apply, reason))
    end
  end

  defp relationship_apply_metadata(person, suggestion) do
    metadata = person.metadata || %{}

    metadata
    |> Map.merge(%{
      "relationship_label" => suggestion.relationship,
      "relationship_context_source" => "crm_insights",
      "relationship_context_updated_at" =>
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "relationship_suggestion_id" => suggestion.id,
      "relationship_suggestion_confidence" => suggestion.confidence
    })
    |> maybe_apply_family_relationship_metadata(suggestion.relationship)
  end

  defp maybe_apply_family_relationship_metadata(metadata, relationship) do
    case Map.get(@family_relationship_suggestion_metadata, relationship) do
      nil ->
        metadata

      family_metadata ->
        metadata
        |> Map.drop(~w(proxy_role proxy_for_person_id default_todo_policy))
        |> Map.merge(family_metadata)
        |> Map.put_new("todo_policy", "family_logistics_only")
        |> Map.put_new("push_policy", "time_sensitive_only")
    end
  end

  defp merge_duplicate_suggestion(socket, suggestion) do
    user_id = current_user_id(socket)

    case merge_suggested_people(user_id, suggestion) do
      {:ok, survivor, merged_count} ->
        socket
        |> put_flash(:info, duplicate_merge_flash(survivor, merged_count))
        |> refresh_crm_insights()

      {:error, reason} ->
        socket
        |> refresh_crm_insights()
        |> put_flash(:error, duplicate_merge_error(reason))
    end
  end

  defp merge_suggested_people(user_id, %{people: people, evidence: evidence})
       when is_binary(user_id) and is_list(people) do
    people = Enum.filter(people, &match?(%Maraithon.Crm.Person{}, &1))

    if length(people) < 2 do
      {:error, :not_enough_people}
    else
      survivor = duplicate_survivor(people)
      duplicate_ids = people |> Enum.reject(&(&1.id == survivor.id)) |> Enum.map(& &1.id)

      case merge_duplicate_ids(user_id, survivor, duplicate_ids, evidence) do
        {:ok, merged_count} -> {:ok, survivor, merged_count}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp merge_suggested_people(_user_id, _suggestion), do: {:error, :invalid_suggestion}

  defp merge_duplicate_ids(user_id, survivor, duplicate_ids, evidence) do
    evidence_summary =
      evidence
      |> List.wrap()
      |> Enum.map_join("; ", fn item -> "#{item.label}: #{item.detail}" end)

    Enum.reduce_while(duplicate_ids, {:ok, 0}, fn duplicate_id, {:ok, count} ->
      case Crm.merge_people(user_id, survivor.id, duplicate_id, %{
             "performed_by" => "operator_insights",
             "evidence" => evidence_summary,
             "model_rationale" =>
               "Maraithon suggested this duplicate group from People cleanup, and Merge contacts was confirmed in Insights."
           }) do
        {:ok, _result} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

  defp duplicate_survivor_name(%{people: people}) when is_list(people) do
    people
    |> duplicate_survivor()
    |> case do
      %{display_name: name} when is_binary(name) -> name
      _person -> "the strongest person record"
    end
  end

  defp duplicate_survivor_name(_suggestion), do: "the strongest person record"

  defp duplicate_survivor([person | _] = people) do
    Enum.max_by(people, &duplicate_survivor_score/1, fn -> person end)
  end

  defp duplicate_survivor([]), do: nil

  defp duplicate_survivor_score(person) do
    {
      present_score(person.relationship),
      present_score(person.notes),
      person.relationship_strength || 0,
      person.interaction_count || 0,
      person.affinity_score || 0,
      contact_detail_count(person.contact_details),
      timestamp_score(person.last_interaction_at),
      timestamp_score(person.updated_at),
      timestamp_score(person.inserted_at)
    }
  end

  defp present_score(value) when is_binary(value) do
    if String.trim(value) == "", do: 0, else: 1
  end

  defp present_score(_value), do: 0

  defp contact_detail_count(contact_details) when is_map(contact_details) do
    contact_details
    |> Map.values()
    |> Enum.reduce(0, fn
      value, count when is_list(value) -> count + length(value)
      value, count when is_binary(value) -> count + present_score(value)
      value, count when is_map(value) -> count + map_size(value)
      _value, count -> count
    end)
  end

  defp contact_detail_count(_contact_details), do: 0

  defp timestamp_score(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp timestamp_score(_datetime), do: 0

  defp duplicate_merge_flash(survivor, 1),
    do: "Merged 1 duplicate into #{survivor.display_name}."

  defp duplicate_merge_flash(survivor, count),
    do: "Merged #{count} duplicates into #{survivor.display_name}."

  defp duplicate_merge_error(:not_enough_people), do: "Select at least two people to merge."
  defp duplicate_merge_error(:person_not_found), do: "One of those people could not be found."

  defp duplicate_merge_error(:person_already_merged),
    do: "That duplicate has already been merged."

  defp duplicate_merge_error(:survivor_already_merged), do: "Choose an active person to keep."
  defp duplicate_merge_error(:person_not_active), do: "Only active people can be merged."
  defp duplicate_merge_error(_reason), do: "Could not merge those contacts."

  defp current_user_id(socket), do: socket.assigns.current_user.id
end
