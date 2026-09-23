defmodule Maraithon.Todos.TrainingEligibility do
  @moduledoc "Keeps explicitly marked evaluation fixtures out of personal training exports."
  alias Maraithon.Todos.{TrainingExample, TrainingFeedback}

  def eligible?(record), do: is_nil(exclusion_reason(record))

  def exclusion_reason(%TrainingExample{payload: payload}) do
    if marked?(Map.take(payload || %{}, ~w(candidate saved_todo))), do: "evaluation_fixture"
  end

  def exclusion_reason(%TrainingFeedback{payload: payload}) do
    if marked?(payload || %{}), do: "evaluation_fixture"
  end

  # Runs are shared context, not labels. A mixed batch can contain both genuine
  # and fixture candidates; eligibility belongs to each example and feedback.
  def exclusion_reason(_), do: nil

  defp marked?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      case {to_string(key), nested} do
        {"production_validation", true} ->
          true

        {"eval_job_id", id} when is_binary(id) and id != "" ->
          true

        {"source", "production_validation"} ->
          true

        {"surface", "production_validation"} ->
          true

        {key, text}
        when key in ["title", "subject", "source_subject", "original_title"] and is_binary(text) ->
          String.contains?(String.downcase(text), "[maraithon eval]")

        {key, text} when key in ["dedupe_key", "request_id"] and is_binary(text) ->
          String.starts_with?(text, [
            "delegation-eval:",
            "todo-outcome-validation-",
            "eval:",
            "eval-stop:"
          ])

        _ ->
          marked?(nested)
      end
    end)
  end

  defp marked?(value) when is_list(value), do: Enum.any?(value, &marked?/1)
  defp marked?(_), do: false
end
