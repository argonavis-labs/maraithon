defmodule MaraithonWeb.CompanionAuthHTML do
  @moduledoc """
  Templates for the companion device-pair flow.
  """

  use MaraithonWeb, :html

  embed_templates "companion_auth_html/*"

  def device_label(nil), do: "your Mac"
  def device_label(""), do: "your Mac"
  def device_label(name) when is_binary(name), do: name
end
