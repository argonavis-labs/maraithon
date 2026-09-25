defmodule MaraithonWeb.PersonReviewLive do
  use MaraithonWeb, :live_view
  alias Maraithon.Crm.Confirmations

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Person details",
       current_path: "/operator/people",
       person: nil,
       details: %{},
       reference: %{},
       request_id: Ecto.UUID.generate(),
       back: "/operator/people"
     )}
  end

  def handle_params(params, _uri, socket) do
    reference = Map.take(params, ~w(person_id todo_id reference note_id index))

    back =
      cond do
        reference["todo_id"] -> ~p"/todos/#{reference["todo_id"]}"
        reference["note_id"] -> ~p"/operator/people/context?#{%{id: reference["note_id"]}}"
        true -> ~p"/operator/people"
      end

    case Confirmations.review(socket.assigns.current_user.id, reference) do
      {:ok, person} ->
        {:noreply,
         assign(socket,
           person: person,
           details: details(person),
           reference: reference,
           back: back
         )}

      _ ->
        {:noreply,
         socket |> assign(:back, back) |> put_flash(:error, "This person is no longer available.")}
    end
  end

  def handle_event("edit", %{"details" => details}, socket),
    do: {:noreply, assign(socket, :details, details)}

  def handle_event("use_suggestion", _, socket) do
    details =
      Map.merge(socket.assigns.details, %{
        "relationship" => socket.assigns.person.suggested_relationship,
        "notes" => socket.assigns.person.suggested_notes || socket.assigns.details["notes"]
      })

    {:noreply, assign(socket, :details, details)}
  end

  def handle_event("confirm", %{"details" => details}, socket) do
    params =
      Map.merge(socket.assigns.reference, %{
        "details" => details,
        "request_id" => socket.assigns.request_id
      })

    case Confirmations.confirm(socket.assigns.current_user.id, params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Details confirmed.")
         |> push_navigate(to: socket.assigns.back)}

      {:error, reason} ->
        message =
          if reason == :ambiguous_contacts,
            do: "These details match different people. Open the correct person from People.",
            else: "Check the name, email addresses and phone numbers, then try again."

        {:noreply, socket |> assign(:details, details) |> put_flash(:error, message)}
    end
  end

  defp details(person) do
    %{
      "name" => person.name,
      "relationship" => person.relationship || "",
      "notes" => person.notes || "",
      "emails" => Enum.join(person.emails, "\n"),
      "phones" => Enum.join(person.phones, "\n")
    }
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="mx-auto max-w-2xl space-y-5">
        <.page_header title={if @person, do: @person.name, else: "Person details"}>
          <:actions><.button navigate={@back} variant="plain">Back</.button></:actions>
        </.page_header>
        <.form :if={@person} for={to_form(@details, as: :details)} phx-change="edit" phx-submit="confirm" id="person-review" class="space-y-4">
          <p class="text-sm text-zinc-500"><%= if @person.confirmed_at, do: "Confirmed by you", else: "Suggested details. Confirm what you recognize." %></p>
          <.field label="Name" for="person-name"><.c_input id="person-name" name="details[name]" value={@details["name"]} maxlength="240" required /></.field>
          <.field label="Relationship" for="person-relationship"><.c_input id="person-relationship" name="details[relationship]" value={@details["relationship"]} maxlength="160" /></.field>
          <.field label="Context" for="person-notes"><.c_textarea id="person-notes" name="details[notes]" value={@details["notes"]} maxlength="8000" /></.field>
          <div :if={@person.suggested_relationship && @person.suggested_relationship != @person.relationship} class="space-y-2 border-y border-zinc-950/10 py-3">
            <p class="text-sm font-medium">From your note</p><p class="text-sm text-zinc-600"><%= @person.suggested_relationship %></p>
            <p class="text-sm text-zinc-600"><%= @person.suggested_notes %></p>
            <.button type="button" variant="plain" phx-click="use_suggestion">Use this context</.button>
          </div>
          <.field label="Email addresses, one per line" for="person-emails"><.c_textarea id="person-emails" name="details[emails]" value={@details["emails"]} rows={2} /></.field>
          <.field label="Phone numbers, one per line" for="person-phones"><.c_textarea id="person-phones" name="details[phones]" value={@details["phones"]} rows={2} /></.field>
          <p class="text-xs text-zinc-500">Leave details you don't know blank.</p>
          <.button type="submit" phx-disable-with="Saving…">Confirm details</.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
