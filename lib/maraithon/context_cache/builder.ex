defmodule Maraithon.ContextCache.Builder do
  @moduledoc """
  Builds the per-user "today digest" that the Telegram assistant reads from
  ContextCache. Pulls from the existing OpenLoops, Todos, and CRM primitives
  so the digest stays in sync with durable state.
  """

  alias Maraithon.ContextCache
  alias Maraithon.Crm
  alias Maraithon.OpenLoops
  alias Maraithon.Todos

  require Logger

  @soft_refresh_after_ms 5 * 60 * 1_000

  @doc """
  Build the digest for a user from current durable state and put it in the
  cache. Returns the digest map.
  """
  def refresh(user_id) when is_binary(user_id) do
    digest = build_digest(user_id)
    ContextCache.put_digest(user_id, digest)
    digest
  end

  def refresh(_user_id), do: nil

  @doc """
  Spawn a background refresh if the cached digest is missing or older than the
  soft TTL. Always returns immediately.
  """
  def maybe_refresh_async(user_id) when is_binary(user_id) do
    case ContextCache.get_digest(user_id) do
      nil ->
        spawn_refresh(user_id)

      %{generated_at: %DateTime{} = generated_at} ->
        if stale?(generated_at) do
          spawn_refresh(user_id)
        else
          :ok
        end

      _other ->
        spawn_refresh(user_id)
    end
  end

  def maybe_refresh_async(_user_id), do: :ok

  @doc false
  def build_digest(user_id) when is_binary(user_id) do
    top_todos =
      user_id
      |> Todos.summarize_for_prompt(5)
      |> Enum.map(&compact_todo/1)

    open_loops = OpenLoops.snapshot(user_id, limit: 6, include_memory?: false)

    waiting_on =
      open_loops
      |> Map.get(:relationships, [])
      |> Enum.take(5)
      |> Enum.map(&compact_relationship/1)

    %{
      top_todos: top_todos,
      open_loops_summary: summarize_open_loops(open_loops),
      waiting_on: waiting_on,
      relationship_count: length(Crm.summarize_for_prompt(user_id, 50)),
      generated_at: DateTime.utc_now()
    }
  end

  defp spawn_refresh(user_id) do
    if async_enabled?() do
      Task.start(fn ->
        try do
          refresh(user_id)
        rescue
          error ->
            Logger.warning("ContextCache refresh failed",
              user_id: user_id,
              reason: Exception.message(error)
            )
        end
      end)
    end

    :ok
  end

  defp async_enabled? do
    case Application.get_env(:maraithon, __MODULE__, []) do
      keyword when is_list(keyword) ->
        Keyword.get(keyword, :async_enabled, true)

      _other ->
        true
    end
  end

  defp stale?(%DateTime{} = generated_at) do
    DateTime.diff(DateTime.utc_now(), generated_at, :millisecond) >= @soft_refresh_after_ms
  end

  defp stale?(_other), do: true

  defp compact_todo(todo) when is_map(todo) do
    Map.take(todo, [:id, :title, :summary, :next_action, :due_at, :priority, :attention_mode])
    |> Map.merge(
      Map.take(todo, [
        "id",
        "title",
        "summary",
        "next_action",
        "due_at",
        "priority",
        "attention_mode"
      ])
    )
  end

  defp compact_todo(other), do: other

  defp compact_relationship(rel) when is_map(rel) do
    Map.take(rel, [:person_id, :person_name, :summary, :last_interaction_at])
    |> Map.merge(Map.take(rel, ["person_id", "person_name", "summary", "last_interaction_at"]))
  end

  defp compact_relationship(other), do: other

  defp summarize_open_loops(%{} = snapshot) do
    todo_count = snapshot |> Map.get(:todos, []) |> length()
    relationship_count = snapshot |> Map.get(:relationships, []) |> length()
    insight_count = snapshot |> Map.get(:open_insights, []) |> length()

    %{
      open_todos: todo_count,
      open_relationships: relationship_count,
      open_insights: insight_count
    }
  end

  defp summarize_open_loops(_other), do: %{}
end
