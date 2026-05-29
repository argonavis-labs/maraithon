defmodule Maraithon.Tools.ToolErrorCopy do
  @moduledoc false

  @technical_markers [
    "access_token",
    "authorization",
    "bearer ",
    "dbconnection",
    "ecto.",
    "http_status",
    "oauth_tokens",
    "postgrex",
    "refresh_token",
    "runtimeerror",
    "stacktrace",
    "token=",
    "traceback"
  ]

  @transient_statuses [408, 409, 425, 429]

  def connected_source(reason, opts) when is_list(opts) do
    label = Keyword.fetch!(opts, :label)

    unavailable =
      Keyword.get(
        opts,
        :unavailable,
        "#{label} is temporarily unavailable. Wait a minute before running this action."
      )

    not_found = Keyword.get(opts, :not_found, "#{label} could not find that item.")

    case reason do
      :no_token ->
        Keyword.get(opts, :not_connected, unavailable)

      :not_connected ->
        Keyword.get(opts, :not_connected, unavailable)

      :unauthorized ->
        Keyword.get(opts, :reauth_required, unavailable)

      :reauth_required ->
        Keyword.get(opts, :reauth_required, unavailable)

      :no_refresh_token ->
        Keyword.get(opts, :reconnect_required, Keyword.get(opts, :reauth_required, unavailable))

      {:http_status, status, _body} when status in [401, 403] ->
        Keyword.get(opts, :reauth_required, unavailable)

      {:http_status, 404, _body} ->
        not_found

      {:http_status, status, _body} when status in @transient_statuses or status >= 500 ->
        unavailable

      {:http_status, _status, _body} ->
        Keyword.get(opts, :unavailable, unavailable)

      {:rate_limited, _body} ->
        unavailable

      {:http_error, _reason} ->
        unavailable

      {:exit, _reason} ->
        "#{label} was interrupted before it could finish. Refresh #{label} before continuing."

      message when is_binary(message) ->
        safe_message(message, unavailable)

      _other ->
        unavailable
    end
  end

  def action_failed(label, action) when is_binary(label) and is_binary(action) do
    "Could not #{action}. Refresh #{label} before continuing."
  end

  def safe_message(message, fallback) when is_binary(message) and is_binary(fallback) do
    message = String.trim(message)

    cond do
      message == "" -> fallback
      technical_message?(message) -> fallback
      true -> message
    end
  end

  def safe_message(_message, fallback) when is_binary(fallback), do: fallback

  defp technical_message?(message) do
    lower = String.downcase(message)

    Enum.any?(@technical_markers, &String.contains?(lower, &1)) or
      String.contains?(message, ["{", "}", "=>"]) or
      Regex.match?(~r/\b[45]\d\d\b/, message)
  end
end
