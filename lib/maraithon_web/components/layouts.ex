defmodule MaraithonWeb.Layouts do
  @moduledoc """
  Layout components for MaraithonWeb.
  """

  use MaraithonWeb, :html
  import MaraithonWeb.CoreComponents, except: [flash_group: 1], warn: false

  attr :flash, :map, required: true

  def flash_group(assigns), do: MaraithonWeb.CoreComponents.flash_group(assigns)

  embed_templates "layouts/*"
end
