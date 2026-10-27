defmodule MaraithonWeb.TodoChatLive do
  use MaraithonWeb, :live_view

  @impl true
  def mount(%{"todo_id" => todo_id}, _session, socket) do
    # Keep saved chat links working; all todo surfaces share one workspace.
    {:ok, push_navigate(socket, to: ~p"/todos/#{todo_id}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path="/todos" current_user={@current_user}>
      <p class="text-sm text-zinc-500">Opening your todo…</p>
    </Layouts.app>
    """
  end
end
