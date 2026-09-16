defmodule MaraithonWeb.DelegationPanel do
  use MaraithonWeb, :live_component
  alias Maraithon.{AssistantIdentities, Delegations}
  alias Maraithon.Delegations.Preflight
  alias MaraithonWeb.DelegationCopy

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open?: false,
       busy?: false,
       scope: nil,
       error: nil,
       actor: "as_user",
       preflight_id: nil,
       preview_ref: nil,
       request_id: Ecto.UUID.generate()
     )}
  end

  @impl true
  def update(%{preview_poll: ref}, socket) do
    if socket.assigns.open? and socket.assigns.preview_ref == ref and is_nil(socket.assigns.scope),
      do: {:ok, poll_preview(socket)},
      else: {:ok, socket}
  end

  def update(attrs, socket) do
    socket = assign(socket, attrs)
    todo = socket.assigns.todo
    delegation = Delegations.for_todo(todo.user_id, todo.id)
    available? = Delegations.available?(todo)

    {:ok,
     assign(socket,
       delegation: Delegations.summary(delegation),
       available?: available?,
       proposal: Maraithon.ChiefOfStaff.Skills.DelegationProposals.current(todo),
       assistant?: available? and not is_nil(AssistantIdentities.get(todo.user_id))
     )}
  end

  @impl true
  def handle_event("open", _, socket),
    do:
      {:noreply,
       socket |> assign(open?: true, request_id: Ecto.UUID.generate())
       |> preview((socket.assigns.proposal || %{})["actor"] || "as_user")}

  def handle_event("close", _, socket),
    do: {:noreply, socket |> cancel_async({:preview, socket.assigns.preview_ref})
      |> assign(open?: false, busy?: false, scope: nil, preflight_id: nil, preview_ref: nil)}

  def handle_event("retry_preview", _, socket), do: {:noreply, preview(socket, socket.assigns.actor)}

  def handle_event("actor", %{"actor" => actor}, socket) when actor in ~w(as_user as_assistant),
    do: {:noreply, preview(socket, actor)}

  def handle_event(
        "delegate",
        %{"delegation" => input},
        %{assigns: %{scope: %{} = scope, busy?: false}} = socket
      ) do
    todo = socket.assigns.todo

    attrs = %{
      "actor" => scope["actor"],
      "kind" => scope["kind"],
      "outcome" => input["outcome"],
      "instruction" => input["instruction"] || "",
      "to" => recipients(input["to"], scope["to"]),
      "cc" => recipients(input["cc"], scope["cc"]),
      "scope_hash" => scope["scope_hash"],
      "preflight_id" => socket.assigns.preflight_id,
      "request_id" => socket.assigns.request_id,
      "expected_revision" => scope["workflow_revision"]
    }

    {:noreply,
     socket
     |> assign(busy?: true, error: nil)
     |> start_async(:delegate, fn -> Delegations.delegate(todo.user_id, todo.id, attrs) end)}
  end

  def handle_event("delegate", _, socket), do: {:noreply, socket}

  def handle_event(
        "control",
        %{"action" => action} = input,
        %{assigns: %{busy?: false, delegation: %{} = d}} = socket
      ) do
    user_id = socket.assigns.todo.user_id

    attrs = %{
      "expected_revision" => d["revision"],
      "request_id" => "#{socket.assigns.request_id}:#{action}:#{d["revision"]}",
      "answer" => input["answer"]
    }

    {:noreply,
     socket
     |> assign(busy?: true, error: nil)
     |> start_async(:control, fn ->
       Delegations.control(user_id, d["id"], action, attrs)
     end)}
  end

  def handle_event("control", _, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:preview, ref}, result, %{assigns: %{preview_ref: ref, open?: true}} = socket) do
    case result do
      {:ok, {:ok, %{scope: scope, preflight: %{id: id}}}} ->
        {:noreply, assign(socket, scope: scope, preflight_id: id, busy?: false)}

      {:ok, {:ok, %{preflight: %{id: id, retry_after_ms: delay}}}} ->
        send_update_after(__MODULE__, [id: socket.assigns.id, preview_poll: ref], delay)
        {:noreply, assign(socket, preflight_id: id)}

      {:ok, {:error, reason}} -> failed(socket, reason)
      {:exit, _} -> failed(socket, :unavailable)
    end
  end

  def handle_async({:preview, _}, _, socket), do: {:noreply, socket}

  def handle_async(operation, {:ok, {:ok, d}}, socket) when operation in [:delegate, :control],
    do:
      {:noreply,
       assign(socket, delegation: Delegations.summary(d), open?: false, busy?: false, scope: nil)}

  def handle_async(_, {:ok, {:error, reason}}, socket), do: failed(socket, reason)
  def handle_async(_, {:exit, _}, socket), do: failed(socket, :unavailable)

  defp failed(socket, reason) do
    d = Delegations.for_todo(socket.assigns.todo.user_id, socket.assigns.todo.id)

    {:noreply,
     assign(socket,
       busy?: false,
       delegation: Delegations.summary(d),
       error: DelegationCopy.error(reason)
     )}
  end

  defp preview(socket, actor) do
    kind = (socket.assigns.proposal || %{})["kind"] || "information"

    socket
    |> cancel_async({:preview, socket.assigns.preview_ref})
    |> assign(actor: actor, preview_kind: kind, preview_ref: make_ref(), preflight_id: nil,
      busy?: true, scope: nil, error: nil)
    |> poll_preview()
  end

  defp poll_preview(socket) do
    todo = socket.assigns.todo
    attrs = %{"actor" => socket.assigns.actor, "kind" => socket.assigns.preview_kind,
      "preflight_id" => socket.assigns.preflight_id}

    start_async(socket, {:preview, socket.assigns.preview_ref}, fn ->
      Preflight.preview(todo.user_id, todo.id, attrs)
    end)
  end

  defp recipients(nil, default), do: default
  defp recipients(text, _), do: String.split(text, ",", trim: true) |> Enum.map(&String.trim/1)

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} hidden={not @available? and is_nil(@delegation)} aria-label="Delegated conversation" class="space-y-3">
      <div :if={@delegation} class="space-y-2 border-y border-zinc-950/10 py-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="min-w-0">
            <p class="text-sm/6 font-medium text-zinc-950"><%= @delegation["status_line"] %></p>
            <p class="text-xs/5 text-zinc-500"><%= @delegation["actor_label"] %></p>
          </div>
          <div class="flex flex-wrap gap-1">
            <.button :for={action <- @delegation["controls"] -- ["answer"]} variant="plain"
              phx-click="control" phx-value-action={action} phx-target={@myself} disabled={@busy?}>
              <%= DelegationCopy.control(action) %>
            </.button>
          </div>
        </div>
        <p :if={@delegation["last_action"]} class="text-sm/6 text-zinc-700"><%= @delegation["last_action"] %></p>
        <p :if={@delegation["hold_reason"] == "send_may_be_in_flight"} class="text-sm/6 text-amber-700">One message may already be sending. Maraithon is checking its delivery.</p>
        <.form :if={"answer" in @delegation["controls"]} for={%{}} phx-submit="control" phx-target={@myself} class="space-y-2">
          <input type="hidden" name="action" value="answer" />
          <.field label={@delegation["question"]} for="delegation-answer"><.c_textarea id="delegation-answer" name="answer" value="" required maxlength="2000" /></.field>
          <.button type="submit" disabled={@busy?}>Answer</.button>
        </.form>
      </div>
      <.button :if={@available? && !@open? && (is_nil(@delegation) || @delegation["state"] in ~w(completed stopped expired))}
        variant={if(@proposal, do: "solid", else: "outline")} phx-click="open" phx-target={@myself}><%= if @proposal, do: @proposal["label"], else: "Delegate" %></.button>
      <p :if={@proposal && !@open? && is_nil(@delegation)} class="text-sm/6 text-zinc-600"><%= @proposal["reason"] %></p>
      <div :if={@open?} class="space-y-4 rounded-lg border border-zinc-950/10 p-4" aria-label="Delegate this task">
        <div class="flex items-center justify-between gap-3">
          <h2 class="text-sm/6 font-semibold text-zinc-950">Delegate this task</h2>
          <.button variant="plain" phx-click="close" phx-target={@myself} disabled={@busy? && not is_nil(@scope)}>Cancel</.button>
        </div>
        <div class="flex flex-wrap gap-2" aria-label="Sending identity">
          <.button :for={{actor, label} <- [{"as_user", "As me"}, {"as_assistant", "As my assistant"}]}
            variant={if(@actor == actor, do: "solid", else: "outline")} aria-pressed={@actor == actor}
            phx-click="actor" phx-value-actor={actor} phx-target={@myself}
            disabled={(@busy? && not is_nil(@scope)) || (actor == "as_assistant" && !@assistant?)}><%= label %></.button>
          <.link :if={!@assistant?} href={~p"/settings/assistant"} class="self-center text-sm/6 text-zinc-600 underline">Set up your assistant</.link>
        </div>
        <p :if={@busy?} role="status" class="text-sm/6 text-zinc-500"><%= if @scope, do: "Starting delegation…", else: "Checking this conversation… You can close this and return later." %></p>
        <.button :if={@error && is_nil(@scope) && !@busy?} variant="outline" phx-click="retry_preview" phx-target={@myself}>Retry</.button>
        <.form :if={@scope} for={%{}} as={:delegation} phx-submit="delegate" phx-target={@myself} class="space-y-3">
          <.description_list>
            <.description_term>From</.description_term>
            <.description_details><%= @scope["identity"]["display_name"] %> <%= @scope["identity"]["email"] || @scope["identity"]["user_id"] %></.description_details>
            <.description_term>Task owner</.description_term>
            <.description_details><%= @scope["task_owner"]["label"] || @scope["task_owner"]["name"] || if(@scope["task_owner"]["kind"] == "user", do: "You", else: @scope["counterparty_label"]) %></.description_details>
          </.description_list>
          <.field label="Outcome" for="delegation-outcome"><.c_input id="delegation-outcome" name="delegation[outcome]" value={@scope["outcome"]} required maxlength="2000" /></.field>
          <.field :if={@scope["provider"] == "gmail"} label="With" for="delegation-to"><.c_input id="delegation-to" name="delegation[to]" value={Enum.join(@scope["to"], ", ")} required /></.field>
          <.field :if={@scope["provider"] == "gmail"} label="Cc" for="delegation-cc"><.c_input id="delegation-cc" name="delegation[cc]" value={Enum.join(@scope["cc"], ", ")} /></.field>
          <p :if={(@scope["first_send_cc"] || []) != []} class="text-sm/6 text-zinc-600">Copy on first message: <%= Enum.join(@scope["first_send_cc"], ", ") %></p>
          <p :if={@scope["provider"] == "slack"} class="text-sm/6 text-zinc-600">With <%= @scope["counterparty_label"] %> in <%= @scope["channel"] %></p>
          <.field label="Instruction (optional)" for="delegation-instruction"><.c_input id="delegation-instruction" name="delegation[instruction]" value="" maxlength="2000" /></.field>
          <div class="flex justify-end"><.button type="submit" disabled={@busy?}>Delegate</.button></div>
        </.form>
      </div>
      <p :if={@error} role="alert" class="text-sm/6 text-red-700"><%= @error %></p>
    </section>
    """
  end
end
