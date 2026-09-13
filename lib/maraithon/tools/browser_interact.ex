defmodule Maraithon.Tools.BrowserInteract do
  @moduledoc "Execute the exact browser interaction approved in a prepared-action card."
  def execute(args) do
    case Maraithon.TodoBrowser.execute(args, :write) do
      {:error, {:browser_unknown, message}} ->
        Maraithon.Tools.provider_error("browser", :timeout, message)

      result ->
        result
    end
  end
end
