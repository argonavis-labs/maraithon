defmodule Maraithon.TestSupport.ContinuationContextEngine do
  @moduledoc false
  def build_context(_attrs),
    do: %{"defaults" => %{}, "request" => %{"text" => "Review this meeting"}}

  def tool_catalog(_context), do: []
end
