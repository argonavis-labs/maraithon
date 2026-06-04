defmodule Maraithon.Slack.UserDirectory do
  @moduledoc """
  Resolves Slack user IDs to display names for source context and generated work.
  """

  alias Maraithon.Connectors.Slack

  require Logger

  @mention_regex ~r/<@([A-Z0-9]+)(?:\|[^>]+)?>/

  def resolve(access_token, user_ids, opts \\ [])

  def resolve(access_token, user_ids, opts) when is_binary(access_token) and is_list(user_ids) do
    max_users = Keyword.get(opts, :max_users, 120)
    max_concurrency = Keyword.get(opts, :max_concurrency, 6)

    user_ids
    |> normalize_user_ids()
    |> Enum.take(max_users)
    |> Task.async_stream(
      fn user_id -> {user_id, fetch_display_name(access_token, user_id)} end,
      max_concurrency: max_concurrency,
      timeout: :timer.seconds(10),
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {user_id, display_name}}, acc when is_binary(display_name) ->
        Map.put(acc, user_id, display_name)

      _result, acc ->
        acc
    end)
  end

  def resolve(_access_token, _user_ids, _opts), do: %{}

  def display_name(directory, user_id) when is_map(directory) do
    user_id = normalize_user_id(user_id)

    case user_id && Map.get(directory, user_id) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  def display_name(_directory, _user_id), do: nil

  def mentioned_users(text, directory) do
    text
    |> user_ids_from_text()
    |> Enum.map(fn user_id ->
      %{
        "id" => user_id,
        "display_name" => display_name(directory, user_id)
      }
    end)
  end

  def replace_mentions(text, directory) when is_binary(text) do
    Regex.replace(@mention_regex, text, fn original, user_id ->
      case display_name(directory, user_id) do
        nil -> original
        display_name -> "@#{display_name}"
      end
    end)
  end

  def replace_mentions(text, _directory), do: text

  def user_ids_from_text(text) when is_binary(text) do
    @mention_regex
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> normalize_user_ids()
  end

  def user_ids_from_text(_text), do: []

  def normalize_user_ids(user_ids) when is_list(user_ids) do
    user_ids
    |> Enum.map(&normalize_user_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def normalize_user_ids(_user_ids), do: []

  def normalize_user_id(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  def normalize_user_id(_value), do: nil

  defp fetch_display_name(access_token, user_id) do
    case Slack.get_user_info(access_token, user_id) do
      {:ok, %{"user" => user}} ->
        display_name_from_user(user, user_id)

      {:error, reason} ->
        Logger.debug("Slack user lookup failed",
          slack_user_id: user_id,
          reason: inspect(reason)
        )

        nil
    end
  rescue
    exception ->
      Logger.debug("Slack user lookup raised",
        slack_user_id: user_id,
        reason: Exception.message(exception)
      )

      nil
  end

  defp display_name_from_user(user, user_id) when is_map(user) do
    profile = Map.get(user, "profile", %{})

    [
      Map.get(profile, "display_name"),
      Map.get(profile, "display_name_normalized"),
      Map.get(profile, "real_name"),
      Map.get(profile, "real_name_normalized"),
      Map.get(user, "real_name"),
      Map.get(user, "name")
    ]
    |> Enum.find_value(&clean_display_name(&1, user_id))
  end

  defp display_name_from_user(_user, _user_id), do: nil

  defp clean_display_name(value, user_id) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      value == user_id -> nil
      true -> value
    end
  end

  defp clean_display_name(_value, _user_id), do: nil
end
