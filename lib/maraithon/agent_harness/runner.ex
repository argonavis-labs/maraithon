defmodule Maraithon.AgentHarness.Runner do
  @moduledoc """
  Generic model-first agent loop entrypoint.
  """

  alias Maraithon.AgentHarness.Manifest
  alias Maraithon.AgentHarness.ToolCatalog
  alias Maraithon.LLM

  def run_once(manifest, context, opts \\ []) when is_map(manifest) do
    with {:ok, params} <- build_llm_params(manifest, context, opts) do
      LLM.complete(params)
    end
  end

  def build_llm_params(manifest, context, opts \\ []) when is_map(manifest) do
    with {:ok, model} <- Manifest.require_text(manifest, :model),
         {:ok, intelligence} <- Manifest.require_text(manifest, :intelligence) do
      {:ok,
       %{
         "model" => model,
         "reasoning_effort" => intelligence,
         "max_output_tokens" => Keyword.get(opts, :max_output_tokens, 1800),
         "messages" => [
           %{"role" => "system", "content" => system_message(manifest)},
           %{"role" => "user", "content" => user_message(manifest, context)}
         ]
       }}
    end
  end

  defp system_message(manifest) do
    [
      Manifest.get(manifest, :system_prompt),
      "Goals:",
      Enum.join(Manifest.get(manifest, :goals, []), "\n"),
      "Skills:",
      skill_instructions(Manifest.get(manifest, :skills, [])),
      "Allowed tools:",
      tool_descriptions(Manifest.get(manifest, :tool_allowlist, []))
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp user_message(_manifest, context) do
    Jason.encode!(%{context: context})
  end

  defp skill_instructions(skills) do
    skills
    |> Enum.map(fn skill -> "## #{skill.name}\n#{skill.instructions}" end)
    |> Enum.join("\n\n")
  end

  defp tool_descriptions(tool_allowlist) do
    tool_allowlist
    |> ToolCatalog.describe()
    |> Jason.encode!()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
