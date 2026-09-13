defmodule Maraithon.LLM.UserModel do
  @moduledoc """
  One user setting that swaps the model behind every assistant call.

  Chat runs, the chief of staff agent, and background jobs bind the acting
  user to their process. `apply/1` then pins that user's chosen model on the
  provider request, whatever tier the caller picked. Tasks spawned from a
  bound process inherit the binding through `$callers`. Without a binding
  or a setting, the configured model stays in place.
  """

  alias Maraithon.Accounts

  @key :maraithon_llm_user_id

  def bind(user_id) when is_binary(user_id) do
    Process.put(@key, user_id)
    :ok
  end

  def bind(_user_id), do: :ok

  def unbind, do: Process.delete(@key)

  @doc "Runs `fun` with `user_id` bound, restoring the previous binding afterwards."
  def with_user(user_id, fun) when is_function(fun, 0) do
    previous = Process.get(@key)
    bind(user_id)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  def current_user_id do
    Process.get(@key) || from_callers(Process.get(:"$callers") || [])
  end

  @doc "The model the bound user chose in Settings, or nil."
  def override do
    case current_user_id() do
      nil -> nil
      user_id -> safe_lookup(user_id)
    end
  end

  @doc "Pins the bound user's model on a provider request; other requests pass through."
  def apply(params) when is_map(params) do
    case override() do
      nil -> params
      model -> Map.put(params, "model", model)
    end
  end

  defp from_callers([]), do: nil

  defp from_callers([pid | rest]) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, @key, 0) do
          {@key, user_id} when is_binary(user_id) -> user_id
          _ -> from_callers(rest)
        end

      _ ->
        from_callers(rest)
    end
  end

  defp from_callers([_other | rest]), do: from_callers(rest)

  # A settings lookup must never turn into a failed model call.
  defp safe_lookup(user_id) do
    Accounts.assistant_model(user_id)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
