defmodule Maraithon.AgentHarness.Runner do
  @moduledoc """
  Generic model-first agent loop entrypoint.
  """

  alias Maraithon.AgentHarness.Manifest
  alias Maraithon.AgentHarness.ToolCatalog
  alias Maraithon.LLM
  alias Maraithon.Memory
  alias Maraithon.OpenLoops

  def run_once(manifest, context, opts \\ []) when is_map(manifest) do
    with {:ok, params} <- build_llm_params(manifest, context, opts) do
      LLM.complete(params)
    end
  end

  def build_llm_params(manifest, context, opts \\ []) when is_map(manifest) do
    with {:ok, model} <- Manifest.require_text(manifest, :model),
         {:ok, intelligence} <- Manifest.require_text(manifest, :intelligence) do
      context =
        context
        |> Memory.enrich_context()
        |> OpenLoops.enrich_context()

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
      memory_guidance(Manifest.get(manifest, :tool_allowlist, [])),
      open_loop_guidance(Manifest.get(manifest, :tool_allowlist, [])),
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

  defp memory_guidance(tool_allowlist) do
    memory_tools =
      ~w(write_memory recall_memory list_memories forget_memory record_memory_feedback)

    if Enum.any?(memory_tools, &Enum.member?(tool_allowlist, &1)) do
      """
      Deep Memory:
      - Use deep_memory from the runtime context as durable user/system steering context.
      - Call recall_memory when a relationship, preference, relevance decision, or past correction may change the answer.
      - Call write_memory when the user or system provides durable facts or instructions.
      - Call record_memory_feedback when the user says something is or is not relevant.
      - Call forget_memory when the user asks to remove or stop using a memory.
      """
      |> String.trim()
    end
  end

  defp open_loop_guidance(tool_allowlist) do
    open_loop_tools = ~w(get_open_loops upsert_todos list_todos resolve_todo)

    if Enum.any?(open_loop_tools, &Enum.member?(tool_allowlist, &1)) do
      """
      Open Loops:
      - Use open_loops from the runtime context as the durable state of work the user must not miss.
      - Call get_open_loops before answering broad questions about what is open, owed, pending, or worth attention.
      - Call upsert_todos to create or refresh todos; it performs model-level semantic dedupe before writing.
      - Link people and write memory when the tool contract provides explicit structured relationship or memory evidence.
      """
      |> String.trim()
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
