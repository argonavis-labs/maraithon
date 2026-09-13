defmodule MaraithonAgentLab.MixProject do
  use Mix.Project

  def project do
    [
      app: :maraithon_agent_lab,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:req_llm, "== 1.22.0"}, {:jido, "== 2.3.3"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
