defmodule Maraithon.AppUrl do
  @moduledoc """
  Builds public application URLs from runtime config without requiring the Phoenix
  endpoint process to be started.
  """

  alias MaraithonWeb.Endpoint

  @fallback_base_url "https://maraithon.com"

  def base_url do
    [
      System.get_env("APP_BASE_URL"),
      Application.get_env(:maraithon, :app_base_url),
      endpoint_config_url(),
      endpoint_runtime_url(),
      @fallback_base_url
    ]
    |> Enum.find(&present?/1)
    |> to_string()
    |> String.trim_trailing("/")
  end

  def url(path) when is_binary(path) do
    base_url() <> normalize_path(path)
  end

  def url(path), do: url(to_string(path))

  defp endpoint_config_url do
    :maraithon
    |> Application.get_env(Endpoint, [])
    |> Keyword.get(:url, [])
    |> url_from_endpoint_config()
  end

  defp endpoint_runtime_url do
    Endpoint.url()
  rescue
    RuntimeError -> nil
  catch
    :exit, _reason -> nil
  end

  defp url_from_endpoint_config(config) when is_list(config) do
    host = config |> Keyword.get(:host) |> blank_to_nil()

    if host do
      scheme = config |> Keyword.get(:scheme, "https") |> to_string()
      port = Keyword.get(config, :port)
      "#{scheme}://#{host}#{port_suffix(scheme, port)}"
    end
  end

  defp url_from_endpoint_config(_config), do: nil

  defp port_suffix(_scheme, nil), do: ""
  defp port_suffix("http", 80), do: ""
  defp port_suffix("https", 443), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  defp normalize_path(""), do: ""
  defp normalize_path("/" <> _ = path), do: path
  defp normalize_path(path), do: "/" <> path

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
end
