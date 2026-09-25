defmodule MaraithonWeb.TodoWorkspaceComponents do
  use MaraithonWeb, :html

  attr :todo, :any, required: true
  attr :brief, :any, default: nil
  attr :state, :map, required: true
  attr :user_id, :string, required: true
  attr :brief_state, :atom, default: :idle
  attr :brief_progress, :string, default: nil
  slot :summary, required: true

  def workspace(assigns) do
    thread = assigns.state.thread
    messages = if thread, do: thread.messages, else: []

    reviews =
      messages
      |> Enum.reverse()
      |> Enum.filter(&is_map(&1.structured_data["draft_card"]))
      |> Enum.uniq_by(fn message ->
        card = message.structured_data["draft_card"]
        {card["provider"], card["recipient"]}
      end)
      |> Enum.take(4)

    assigns =
      assigns
      |> assign(:messages, Enum.take(messages, -assigns.state.history_limit))
      |> assign(:more?, length(messages) > assigns.state.history_limit)
      |> assign(:reviews, reviews)
      |> assign(:timeline, if(thread, do: Map.get(thread, :todo_timeline, []), else: []))
      |> assign(:run, thread && thread.pending_run)
      |> assign(
        :receipts,
        messages
        |> Enum.filter(&(&1.role == "user"))
        |> Enum.map(& &1.client_message_id)
        |> Enum.reject(&is_nil/1)
      )
      |> assign(:people, (assigns.brief || %{})["people"] || [])
      |> assign(:actions, (assigns.brief || %{})["suggested_actions"] || [])
      |> assign(:delegated?, Maraithon.Delegations.attached?(assigns.todo))

    ~H"""
    <div id={"todo-workspace-#{@todo.id}"} phx-hook="TodoWorkspace"
      data-storage-key={"maraithon:todo:#{@user_id}:#{@todo.id}"}
      data-receipts={Jason.encode!(@receipts)} data-busy={to_string(@state.busy?)}
      class="grid min-w-0 gap-8 xl:grid-cols-2">
      <div class="min-w-0 space-y-6">
        <.live_component module={MaraithonWeb.DelegationPanel} id={"delegation-#{@todo.id}"} todo={@todo} />
        <section :if={not @delegated?} aria-label="Maraithon’s read" class="space-y-3">
          <p :if={@brief && @brief["summary"]} class="whitespace-pre-line text-base/7 text-zinc-800"><%= @brief["summary"] %></p>
          <p :if={@brief && @brief["done_when"]} class="text-sm/6 text-zinc-600"><span class="font-medium text-zinc-950">Done when:</span> <%= @brief["done_when"] %></p>
          <div :if={@brief && (@brief["open_questions"] || []) != []} class="space-y-1 text-sm/6 text-zinc-700">
            <p class="font-medium text-zinc-950">Your decision</p>
            <p :for={question <- @brief["open_questions"]}><%= question %></p>
          </div>
          <p :if={@brief_progress} role="status" class="text-sm/6 text-zinc-500"><%= @brief_progress %></p>
          <div :if={@todo.status in ~w(triage open snoozed)} class="flex flex-wrap items-center gap-3">
            <.button :if={@brief_state not in [:generating, :waiting]} phx-click="regenerate_brief" variant="plain">Refresh context</.button>
          </div>
        </section>

        <section :if={@reviews != []} aria-label="Action reviews" class="space-y-2">
          <.draft_review :for={message <- @reviews} message={message} busy?={@state.busy? || @state.loading?} />
        </section>

        <section :if={not @delegated? && @todo.status in ~w(triage open snoozed) && @actions != []} aria-labelledby="todo-next-actions-title">
          <h2 id="todo-next-actions-title" class="text-sm/6 font-semibold text-zinc-950">Suggested next actions</h2>
          <div class="mt-2 divide-y divide-zinc-950/10 border-y border-zinc-950/10">
            <.button :for={action <- @actions} variant="plain" class="w-full justify-start py-3 text-left"
              data-workspace-prompt={action_request(action)} disabled={@state.busy? || @state.loading? || @run != nil || is_nil(@state.thread)}>
              <.provider_mark provider={action["provider"]} />
              <span class="min-w-0 flex-1"><span class="block"><%= action["label"] %></span>
                <span class="block text-xs/5 font-normal text-zinc-500"><%= action["purpose"] %></span>
              </span>
              <.icon name="hero-arrow-up-right" class="size-4 shrink-0 text-zinc-400" />
            </.button>
          </div>
        </section>

        <details class="border-b border-zinc-950/10 pb-4">
          <summary class="cursor-pointer text-sm/6 font-medium text-zinc-600">Context and source</summary>
          <div class="mt-3 space-y-4"><%= render_slot(@summary) %></div>
        </details>


        <.activity_timeline entries={@timeline} />
      <aside class="min-w-0 border-t border-zinc-950/10 pt-5" aria-labelledby="todo-people-title">
        <details id={"todo-people-#{@todo.id}"} >
          <summary id="todo-people-title" class="cursor-pointer text-sm/6 font-semibold text-zinc-950">People <span class="ml-1 font-normal text-zinc-400"><%= length(@people) %></span></summary>
          <div class="mt-4 divide-y divide-zinc-950/10">
            <article :for={person <- @people} class="space-y-2 py-4 first:pt-0">
              <div class="flex items-center gap-3">
                <span class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-zinc-100 text-xs font-medium text-zinc-600" aria-hidden="true"><%= initials(person["name"]) %></span>
                <div class="min-w-0"><h3 class="text-sm/6 font-medium text-zinc-950"><.link navigate={~p"/operator/people/confirm?#{%{todo_id: @todo.id, reference: person["id"]}}"}><%= person["name"] %></.link></h3>
                  <p :if={person["relationship"]} class="text-xs/5 text-zinc-500"><%= person["relationship"] %></p>
                </div>
              </div>
              <p :if={person["context"]} class="text-sm/6 text-zinc-600"><%= person["context"] %></p>

              <div class="flex flex-wrap gap-1">
                <.button navigate={~p"/operator/people/confirm?#{%{todo_id: @todo.id, reference: person["id"]}}"} variant="plain" class="text-xs">Confirm details</.button>
                <.button variant="plain" class="text-xs" disabled={@state.busy? || @state.loading? || @run != nil || is_nil(@state.thread)}
                  data-workspace-prompt={"Who is #{person["name"]}, how do I know them, and what should I know for this todo? Check our real relationship and source history."}>Ask Maraithon</.button>
              </div>
            </article>
            <p :if={@people == []} class="text-sm/6 text-zinc-500">No people identified in this todo yet.</p>
          </div>
        </details>
      </aside>
      </div>
      <div class="min-w-0 xl:border-l xl:border-zinc-950/10 xl:pl-6">
        <section id="todo-conversation" class="min-w-0 scroll-mt-6" aria-labelledby="todo-conversation-title">
          <div class="mb-3 flex items-center justify-between gap-3">
            <h2 id="todo-conversation-title" class="text-sm/6 font-semibold text-zinc-950">Chat</h2>
            <.button variant="plain" phx-click="workspace_refresh" disabled={@state.loading? || @state.busy?} aria-label="Refresh conversation">
              <.icon name="hero-arrow-path" class="size-4" />
            </.button>
          </div>
          <div id={"todo-timeline-#{@todo.id}"} phx-hook="TodoTimeline" data-last-message={List.last(@messages) && List.last(@messages).id}
            class="max-h-[28rem] min-h-40 space-y-5 overflow-y-auto overscroll-contain rounded-lg border border-zinc-950/10 bg-white p-4 sm:p-5"
            role="log" aria-label="Todo conversation" tabindex="0">
            <.button :if={@more?} variant="plain" phx-click="workspace_earlier">Load earlier messages</.button>
            <p :if={is_nil(@state.thread)} role="status" class="text-sm/6 text-zinc-500">
              <%= if @state.loading?, do: "Opening your conversation…", else: "Conversation unavailable. Refresh to try again." %>
            </p>
            <p :if={@state.thread && @messages == []} class="text-sm/6 text-zinc-500">Tell Maraithon what to do with this task. Try “Add this to my calendar tomorrow.”</p>
            <article :for={message <- @messages} id={"workspace-message-#{message.id}"}
              class={if(message.role == "user", do: "ml-6 rounded-lg bg-zinc-50 px-4 py-3", else: "min-w-0")}>
              <p class="mb-1 text-xs/5 font-medium text-zinc-500"><%= if message.role == "user", do: "You", else: "Maraithon" %></p>
              <p class="whitespace-pre-wrap break-words text-sm/6 text-zinc-800"><%= message.body %></p>
              <p :if={message.work_summary && message.work_summary["headline"]} class="mt-2 text-xs/5 text-zinc-500"><%= message.work_summary["headline"] %></p>
              <.review_reference :if={message.structured_data["draft_card"]} message={message} reviews={@reviews} busy?={@state.busy? || @state.loading?} />
            </article>
            <div :if={@run} role="status" class="text-sm/6 text-zinc-500">
              <span class="mr-2 inline-block size-2 animate-pulse rounded-full bg-zinc-400" />
              <%= get_in(@run, [:work_summary, "headline"]) || "Working on your todo…" %>
              <p :if={get_in(@run, [:work_summary, "preview"])} class="mt-2 whitespace-pre-wrap text-zinc-800"><%= @run.work_summary["preview"] %></p>
            </div>
          </div>
          <p :if={@state.error} role="alert" class="mt-3 text-sm/6 text-red-700"><%= @state.error %></p>
          <p data-workspace-status role="status" class="mt-2 text-sm/6 text-zinc-500" />
          <.button data-retry-request hidden variant="outline" class="mt-2 [&[hidden]]:hidden" disabled={@state.busy? || @state.loading? || @run != nil}>Retry pending message</.button>
          <form id={"todo-composer-#{@todo.id}"} data-workspace-composer class="mt-3">
            <.c_textarea id="todo-chat-input" name="body" rows={3} maxlength="16000"
              aria-label="Message about this todo" placeholder="Tell Maraithon what to do…" required />
            <div class="mt-2 flex items-center justify-end gap-2">
              <span data-workspace-connection hidden class="mr-auto text-xs text-amber-700">Reconnecting… Your draft is kept.</span>
              <.button type="submit" disabled={is_nil(@state.thread) || @state.loading? || @state.busy? || not is_nil(@run)} data-workspace-send>
                <.icon name="hero-arrow-up" class="size-4" /> <span data-send-label>Send</span>
              </.button>
            </div>
          </form>
        </section>
      </div>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :busy?, :boolean, required: true

  def draft_review(assigns) do
    card = assigns.message.structured_data["draft_card"]

    editable? =
      card["provider"] != "browser" && not terminal?(card) &&
        (card["editable"] == true || card["prepared_action_id"] || card["provider"] == "imessage")

    assigns =
      assigns
      |> assign(:card, card)
      |> assign(:editable?, !!editable?)
      |> assign(:card_id, "review-" <> assigns.message.id)

    ~H"""
    <details open={!terminal?(@card)} id={@card_id} data-workspace-review data-provider={@card["provider"]} data-message-id={@message.id}
      data-editable={to_string(@editable?)} class="group rounded-lg border border-zinc-950/10 bg-white">
      <summary class="flex cursor-pointer list-none items-center gap-3 p-4">
        <.provider_mark provider={@card["provider"]} />
        <div class="min-w-0 flex-1"><span class="block text-sm/6 font-medium text-zinc-950"><%= @card["title"] || provider_label(@card["provider"]) %></span>
          <span class="block truncate text-xs/5 text-zinc-500"><%= @card["recipient_name"] || @card["recipient"] || @card["from"] %></span>
        </div>
        <span class="max-w-36 text-right text-xs/5 text-zinc-500"><%= @card["status"] || "Review draft" %></span>
        <.icon name="hero-chevron-down" class="size-4 shrink-0 text-zinc-400 group-open:rotate-180" />
      </summary>
      <form data-workspace-draft data-action-id={@card["prepared_action_id"]} data-from={@card["from"]} class="space-y-4 border-t border-zinc-950/10 p-4 sm:p-5">
        <details :if={(@card["conversation"] || []) != []} open class="border-b border-zinc-950/10 pb-3">
          <summary class="cursor-pointer text-sm font-medium text-zinc-700">Conversation</summary>
          <div class="mt-3 max-h-64 space-y-4 overflow-y-auto">
            <div :for={message <- @card["conversation"]} class="border-l-2 border-zinc-200 pl-3">
              <p class="text-xs/5 text-zinc-500"><%= message[:speaker] || message["speaker"] %>
                <time :if={message[:at] || message["at"]} datetime={message[:at] || message["at"]} data-workspace-time><%= message[:at] || message["at"] %></time>
              </p>
              <div data-channel-message={@card["provider"]} class="whitespace-pre-wrap break-words text-sm/6 text-zinc-800"><span data-channel-source><%= message[:text] || message["text"] %></span><span data-channel-rendered /></div>
            </div>
          </div>
        </details>
        <div :if={@card["from"]} class="text-sm/6"><span class="mr-2 text-zinc-500">From</span><%= @card["from"] %></div>
        <.field :if={@card["recipient"]} label="To" for={@card_id <> "-recipient"}>
          <.c_input id={@card_id <> "-recipient"} name="recipient" value={@card["recipient"]}
            readonly={!@editable? || @card["provider"] != "gmail"} required />
        </.field>
        <div :if={@card["provider"] == "gmail"} class="grid gap-4 sm:grid-cols-2">
          <.field :for={name <- ~w(cc bcc)} label={String.upcase(name)} for={@card_id <> "-" <> name}>
            <.c_input id={@card_id <> "-" <> name} name={name} value={@card[name]} readonly={!@editable?} />
          </.field>
        </div>
        <.field :if={@card["subject"] || @card["provider"] == "gmail"} label="Subject" for={@card_id <> "-subject"}>
          <.c_input id={@card_id <> "-subject"} name="subject" value={@card["subject"]} readonly={!@editable?} />
        </.field>
        <dl :if={@card["provider"] == "calendar"} class="space-y-2 text-sm/6">
          <div :for={{label, key} <- [{"Starts", "start_at"}, {"Ends", "end_at"}]} :if={@card[key]}>
            <dt class="text-xs text-zinc-500"><%= label %></dt><dd><time datetime={@card[key]} data-workspace-time data-timezone={@card["timezone"]}><%= @card[key] %></time></dd>
          </div>
          <div :if={@card["timezone"]}><dt class="text-xs text-zinc-500">Timezone</dt><dd><%= @card["timezone"] %></dd></div>
        </dl>
        <.field label={cond do @card["provider"] == "browser" -> "Browser step"; @card["provider"] == "calendar" -> "Event details"; true -> "Message" end} for={@card_id <> "-body"}>
          <.c_textarea id={@card_id <> "-body"} name="body" value={@card["body"]} rows={7}
            readonly={!@editable? || @card["provider"] == "calendar"} required={@card["provider"] != "calendar"} />
        </.field>
        <details :if={@card["provider"] == "slack"} class="text-sm/6">
          <summary class="cursor-pointer font-medium text-zinc-600">Preview formatting</summary>
          <div data-draft-preview class="mt-3 whitespace-pre-wrap break-words text-zinc-800" />
        </details>
        <div :if={@card["connection_required"]} class="space-y-2 rounded-lg bg-amber-50 p-3 text-sm/6 text-amber-900">
          <p><%= @card["connection_notice"] %></p>
          <.button :if={safe_link(@card["connection_url"])} href={@card["connection_url"]} target="_blank" rel="noopener" variant="outline"><%= @card["connection_label"] %></.button>
        </div>
        <p :if={@card["delivery_note"]} class="text-xs/5 text-zinc-500"><%= @card["delivery_note"] %></p>
        <div class="flex flex-wrap items-center gap-2">
          <.button :if={@card["prepared_action_id"]} type="submit" data-decision="confirm"
            disabled={@busy? || @card["connection_required"] == true}>
            <%= @card["send_label"] || "Approve action" %>
          </.button>
          <.button :if={@card["prepared_action_id"]} type="submit" data-decision="reject" formnovalidate variant="plain" disabled={@busy?}>Cancel action</.button>
          <.button :if={@editable? && @card["provider"] == "gmail" && is_nil(@card["prepared_action_id"])}
            data-prepare-email disabled={@busy? || @card["connection_required"] == true}>Prepare to send</.button>
          <.button :if={@card["provider"] == "imessage" && is_nil(@card["prepared_action_id"]) && !terminal?(@card)} data-open-messages variant="outline">Open in Messages</.button>
          <.button :if={@card["body"]} data-copy-draft variant="outline">Copy</.button>
          <.button :if={safe_link(@card["open_url"])} href={@card["open_url"]} target="_blank" rel="noopener" variant="plain"><%= @card["open_label"] || "Open source" %></.button>
        </div>
        <p data-draft-feedback role="status" class="text-xs/5 text-zinc-500" />
      </form>
    </details>
    """
  end

  defp review_reference(assigns) do
    card = assigns.message.structured_data["draft_card"]
    current? = Enum.any?(assigns.reviews, &(&1.id == assigns.message.id))
    assigns = assigns |> assign(:card, card) |> assign(:current?, current?)

    ~H"""
    <div class="mt-2">
      <.button :if={@current?} variant="plain" class="text-xs" data-open-review={"review-#{@message.id}"}>
        <.provider_mark provider={@card["provider"]} /> Review <%= provider_label(@card["provider"]) %>
      </.button>
      <.draft_review :if={!@current?} message={@message} busy?={@busy?} />
    </div>
    """
  end

  attr :provider, :string, required: true

  def provider_mark(assigns) do
    assigns = assign(assigns, :logo, logo(assigns.provider))

    ~H"""
    <img :if={@logo} src={@logo} alt={provider_label(@provider)} class="size-5 shrink-0 object-contain" />
    <.icon :if={!@logo} name={if(@provider == "calendar", do: "hero-calendar-days", else: "hero-sparkles")} class="size-5 shrink-0 text-zinc-500" />
    """
  end

  attr :entries, :list, required: true

  def activity_timeline(assigns) do
    ~H"""
    <details :if={@entries != []} class="border-y border-zinc-950/10 py-4">
      <summary class="cursor-pointer text-sm/6 font-semibold text-zinc-950">Timeline · <%= length(@entries) %></summary>
      <ol class="mt-4 space-y-4" aria-label="Todo activity">
        <li :for={entry <- @entries}>
          <details class="border-l-2 border-zinc-200 pl-3">
            <summary class="cursor-pointer text-sm/6 text-zinc-800">
              <span class={if(entry.kind in ["sent", "marked_done"], do: "text-emerald-700 font-medium")}><%= entry.title %></span>
              <time :if={entry.occurred_at} datetime={entry.occurred_at} data-workspace-time class="ml-2 text-xs text-zinc-500"><%= entry.occurred_at %></time>
            </summary>
            <p :if={entry.body} class="mt-2 whitespace-pre-wrap break-words text-sm/6 text-zinc-600"><%= entry.body %></p>
          </details>
        </li>
      </ol>
    </details>
    """
  end

  defp action_request(action) do
    person = action["person_name"]
    target = if person, do: " to #{person}", else: ""
    purpose = action["purpose"]

    case action["provider"] do
      "gmail" ->
        "Draft an email#{target} for review. #{purpose}"

      "imessage" ->
        "Draft an iMessage#{target} for review. #{purpose}"

      "slack" ->
        "Draft a Slack message#{target} for review. #{purpose}"

      "browser" ->
        "Use the background Chrome browser on my Mac to help with this step: #{purpose}"

      "calendar" ->
        "Find time in my calendar and prepare an event for review. #{purpose}"

      _ ->
        "Help me with this next step: #{purpose}"
    end
  end

  defp icon(assigns), do: MaraithonWeb.CoreComponents.action_icon(assigns)

  defp logo("browser"), do: "/images/connector-logos/chrome.png"
  defp logo("gmail"), do: "/images/connector-logos/gmail.png"
  defp logo("imessage"), do: "/images/connector-logos/messages.png"
  defp logo("slack"), do: "/images/connector-logos/slack.svg"
  defp logo(_), do: nil
  defp provider_label("gmail"), do: "Gmail"
  defp provider_label("imessage"), do: "Messages"
  defp provider_label("slack"), do: "Slack"
  defp provider_label("browser"), do: "Chrome"
  defp provider_label("calendar"), do: "Calendar"
  defp provider_label(_), do: "Action"

  defp terminal?(card),
    do:
      card["status"] in [
        "Completed",
        "Running",
        "Could not complete",
        "Sent",
        "Saved to calendar",
        "Cancelled",
        "Expired",
        "Sending",
        "Could not send",
        "Check before retrying"
      ]

  defp safe_link(url) when is_binary(url), do: URI.parse(url).scheme in ["https", "http"]
  defp safe_link(_), do: false

  defp initials(name),
    do: (name || "") |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1)
end
