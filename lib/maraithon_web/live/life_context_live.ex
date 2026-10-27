defmodule MaraithonWeb.LifeContextLive do
  use MaraithonWeb, :live_view
  alias Maraithon.LifeContext

  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 3_000)

    {:ok,
     assign(socket,
       page_title: "Life & work",
       current_path: "/operator/people",
       notes: [],
       selected: nil,
       draft: %{"text" => "", "domain" => "both", "input_mode" => "text"},
       request_id: Ecto.UUID.generate(),
       review: %{}
     )}
  end

  def handle_params(params, _uri, socket) do
    note = LifeContext.get(socket.assigns.current_user.id, params["id"])
    {:noreply, socket |> assign(:selected, note) |> fill_review() |> refresh_notes()}
  end

  def handle_event("draft", %{"context" => draft}, socket) do
    {:noreply, assign(socket, draft: draft, request_id: Ecto.UUID.generate())}
  end

  def handle_event("capture", %{"context" => draft}, socket) do
    case LifeContext.capture(
           socket.assigns.current_user.id,
           Map.put(draft, "request_id", socket.assigns.request_id)
         ) do
      {:ok, note} ->
        {:noreply,
         socket
         |> assign(:draft, %{"text" => "", "domain" => "both", "input_mode" => "text"})
         |> assign(:request_id, Ecto.UUID.generate())
         |> push_patch(to: ~p"/operator/people/context?#{%{id: note.id}}")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:draft, draft)
         |> put_flash(:error, "Add between 10 and 10,000 characters, then try again.")}
    end
  end

  def handle_event("edit_review", %{"review" => review}, socket),
    do: {:noreply, assign(socket, :review, review)}

  def handle_event("confirm", %{"review" => review}, socket) do
    attrs = Map.update(review, "rules", [], &String.split(&1, "\n", trim: true))

    apply_action(socket, fn id ->
      LifeContext.confirm(socket.assigns.current_user.id, id, attrs)
    end)
  end

  def handle_event("retry", _, socket),
    do: apply_action(socket, &LifeContext.retry(socket.assigns.current_user.id, &1))

  def handle_event("archive", _, socket) do
    case socket.assigns.selected &&
           LifeContext.archive(socket.assigns.current_user.id, socket.assigns.selected.id) do
      {:ok, _} -> {:noreply, push_patch(socket, to: ~p"/operator/people/context")}
      _ -> {:noreply, put_flash(socket, :error, "This context couldn't be archived.")}
    end
  end

  def handle_info(:refresh, socket) do
    socket = refresh_notes(socket)

    socket =
      if socket.assigns.selected && socket.assigns.selected.metadata["state"] == "queued" do
        selected = LifeContext.get(socket.assigns.current_user.id, socket.assigns.selected.id)
        socket |> assign(:selected, selected) |> fill_review()
      else
        socket
      end

    Process.send_after(self(), :refresh, 3_000)
    {:noreply, socket}
  end

  defp refresh_notes(socket),
    do: assign(socket, :notes, LifeContext.list(socket.assigns.current_user.id))

  defp fill_review(socket) do
    metadata = if socket.assigns.selected, do: socket.assigns.selected.metadata, else: %{}

    assign(socket, :review, %{
      "summary" => metadata["summary"] || "",
      "rules" => Enum.join(metadata["rules"] || [], "\n")
    })
  end

  defp apply_action(socket, action) do
    case socket.assigns.selected && action.(socket.assigns.selected.id) do
      {:ok, note} ->
        {:noreply, socket |> assign(:selected, note) |> fill_review() |> refresh_notes()}

      _ ->
        {:noreply, put_flash(socket, :error, "Check the details and try again.")}
    end
  end

  defp label("confirmed"), do: "Confirmed guidance"
  defp label("review"), do: "Ready to review"
  defp label("failed"), do: "Needs another try"
  defp label(_), do: "Making sense of your note…"

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="mx-auto max-w-3xl space-y-6">
        <.page_header title="Life & work">
          <:actions><.button navigate={~p"/operator/people"} variant="plain">People</.button></:actions>
        </.page_header>
        <.form :if={!@selected} for={to_form(@draft, as: :context)} phx-change="draft" phx-submit="capture" id="life-context-capture" class="space-y-4">
          <p class="text-sm/6 text-zinc-600">Tell me about the people, responsibilities, and routines that matter to you.</p>
          <.field label="Context" for="context-domain"><.c_select id="context-domain" name="context[domain]">
            <option :for={{value, title} <- [{"both", "Life & work"}, {"life", "Life"}, {"work", "Work"}]} value={value} selected={@draft["domain"] == value}><%= title %></option>
          </.c_select></.field>
          <div id="life-context-voice" phx-hook=".ContextVoice" class="space-y-3">
            <.field label="Your note" for="context-text"><.c_textarea id="context-text" name="context[text]" value={@draft["text"]} rows={7} maxlength="10000" required /></.field>
            <input type="hidden" id="context-input-mode" name="context[input_mode]" value={@draft["input_mode"] || "text"} />
            <.button type="button" variant="plain" data-voice-button hidden>Record a voice note</.button>
            <p data-voice-status role="status" class="text-xs/5 text-zinc-500">Type a note, or use your device's keyboard dictation.</p>
          </div>
          <.button type="submit" phx-disable-with="Saving…">Make sense of this</.button>
        </.form>
        <section :if={@selected} class="space-y-5">
          <.button patch={~p"/operator/people/context"} variant="plain">All context</.button>
          <details><summary class="cursor-pointer text-sm font-medium">Your note</summary><p class="mt-3 whitespace-pre-wrap text-sm/6 text-zinc-600"><%= @selected.content %></p></details>
          <p role="status" class="text-sm font-medium"><%= label(@selected.metadata["state"]) %></p>
          <.button :if={@selected.metadata["state"] == "failed"} phx-click="retry">Try again</.button>
          <.form :if={@selected.metadata["state"] in ~w(review confirmed)} for={to_form(@review, as: :review)} phx-change="edit_review" phx-submit="confirm" id="context-review" class="space-y-4">
            <.field label="Summary" for="context-summary"><.c_textarea id="context-summary" name="review[summary]" value={@review["summary"]} maxlength="2000" required /></.field>
            <.field label="Guidance, one point per line" for="context-rules"><.c_textarea id="context-rules" name="review[rules]" value={@review["rules"]} rows={6} /></.field>
            <.button type="submit" phx-disable-with="Saving…"><%= if @selected.metadata["state"] == "confirmed", do: "Save guidance", else: "Confirm guidance" %></.button>
          </.form>
          <div :if={(@selected.metadata["people"] || []) != []} class="divide-y divide-zinc-950/10">
            <h2 class="py-3 text-sm font-semibold">People to confirm</h2>
            <.link :for={person <- @selected.metadata["people"]} navigate={~p"/operator/people/confirm?#{%{note_id: @selected.id, index: person["index"]}}"} class="flex items-center justify-between gap-4 py-3 text-sm hover:bg-zinc-50">
              <span><span class="font-medium"><%= person["name"] %></span><span class="mt-1 block text-zinc-500"><%= person["relationship"] %></span></span>
              <span class="text-xs text-zinc-500"><%= if person["confirmed_at"], do: "Details confirmed", else: "Review phone & email" %></span>
            </.link>
          </div>
          <.button variant="plain" phx-click="archive" data-confirm="Archive this context and stop using its guidance?">Archive context</.button>
        </section>
        <section :if={!@selected} class="divide-y divide-zinc-950/10">
          <h2 class="py-3 text-sm font-semibold">Context you've shared</h2>
          <p :if={@notes == []} class="py-4 text-sm text-zinc-500">Your notes and confirmed guidance will appear here.</p>
          <.link :for={note <- @notes} patch={~p"/operator/people/context?#{%{id: note.id}}"} class="block space-y-1 py-4 hover:bg-zinc-50">
            <p class="line-clamp-3 text-sm/6"><%= note.metadata["summary"] || note.content %></p>
            <p class="text-xs text-zinc-500"><%= label(note.metadata["state"]) %></p>
          </.link>
        </section>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ContextVoice">
        export default {
          mounted() {
            const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition
            if (!Recognition) return
            const button = this.el.querySelector('[data-voice-button]')
            const status = this.el.querySelector('[data-voice-status]')
            button.hidden = false
            status.textContent = 'Uses your browser’s speech service. Review the transcript before saving.'
            this.recording = false
            this.onClick = () => {
              if (this.recording) { this.recognition.stop(); return }
              const field = this.el.querySelector('textarea')
              const initial = field.value
              this.recognition = new Recognition()
              this.recognition.continuous = true
              this.recognition.interimResults = true
              this.recognition.onresult = event => {
                const words = Array.from(event.results).map(result => result[0].transcript).join(' ')
                field.value = [initial, words].filter(Boolean).join('\n').slice(0, 10000)
                this.el.querySelector('[name="context[input_mode]"]').value = 'voice'
                field.dispatchEvent(new Event('input', {bubbles: true}))
              }
              this.recognition.onerror = () => { status.textContent = 'Dictation stopped. Your text is kept; try again or type.' }
              this.recognition.onend = () => { this.recording = false; button.textContent = 'Record a voice note'; field.readOnly = false; clearTimeout(this.timer) }
              try {
                this.recognition.start()
                this.recording = true; field.readOnly = true
                button.textContent = 'Stop recording'
                status.textContent = 'Listening… up to one minute. Review the text before saving.'
                this.timer = setTimeout(() => this.recognition?.stop(), 55000)
              } catch { status.textContent = 'Dictation is unavailable. You can type your note.' }
            }
            button.addEventListener('click', this.onClick)
          },
          updated() {
            if (!(window.SpeechRecognition || window.webkitSpeechRecognition)) return
            const button = this.el.querySelector('[data-voice-button]')
            button.hidden = false
            button.textContent = this.recording ? 'Stop recording' : 'Record a voice note'
            this.el.querySelector('textarea').readOnly = this.recording
          },
          destroyed() {
            clearTimeout(this.timer)
            this.recognition?.abort()
            this.el.querySelector('[data-voice-button]')?.removeEventListener('click', this.onClick)
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
