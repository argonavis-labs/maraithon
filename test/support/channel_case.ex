defmodule MaraithonWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix channel tests. Mirrors the shape of
  `MaraithonWeb.ConnCase` (sandbox setup + endpoint alias) and imports
  the helpers from `Phoenix.ChannelTest` that channel tests use.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint MaraithonWeb.Endpoint

      import Phoenix.ChannelTest
      import MaraithonWeb.ChannelCase
    end
  end

  setup tags do
    Maraithon.DataCase.setup_sandbox(tags)
    :ok
  end
end
