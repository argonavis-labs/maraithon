defmodule Maraithon.Todos.PublicMetadata do
  @moduledoc """
  Filters todo and people metadata down to fields safe for product surfaces.

  Source pipelines keep internal identifiers, scoring hints, and model runtime
  data in metadata. This module is the boundary before that data reaches web,
  mobile, or assistant-visible output.
  """

  @public_todo_keys MapSet.new(~w(
    account
    account_email
    body_excerpt
    company
    contact
    context_brief
    due_context
    email_subject
    from
    holiday_date
    holiday_name
    life_domain
    omni_project
    organization
    person
    project
    project_name
    quote
    relationship
    relationship_context
    requested_by
    resolution_note
    sender_name
    source_account_label
    source_excerpt
    source_quote
    subject
    thread_state
    thread_subject
    topic
    why_it_matters
    why_now
  ))

  @public_person_keys MapSet.new(~w(
    deal_stage
    deal_value
    family_member
    family_role
    mobile_status
    relationship_domain
    relationship_preset
    relationship_preset_label
    todo_policy
  ))

  @internal_terms ~w(
    agent
    assistant
    confidence
    generation
    heuristic
    internal
    json
    llm
    model
    prompt
    quality
    rationale
    reasoning
    score
    source_backed
    source_health
    threshold
    token
  )

  def todo(metadata), do: filter(metadata, @public_todo_keys)

  def person(metadata), do: filter(metadata, @public_person_keys)

  def public_text?(value) when is_binary(value), do: public_value?(value)
  def public_text?(_value), do: false

  defp filter(metadata, public_keys) when is_map(metadata) do
    metadata
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = to_string(key)

      if public_key?(key, public_keys) and public_value?(value) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp filter(_metadata, _public_keys), do: %{}

  defp public_key?(key, public_keys) when is_binary(key) do
    MapSet.member?(public_keys, key) and not internal_key?(key)
  end

  defp internal_key?(key) do
    normalized = key |> String.downcase() |> String.replace("_", " ")
    Enum.any?(@internal_terms, &String.contains?(normalized, &1))
  end

  defp public_value?(value) when is_binary(value) do
    trimmed = String.trim(value)
    trimmed != "" and not internal_value?(trimmed)
  end

  defp public_value?(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: true

  defp public_value?(_value), do: false

  defp internal_value?(value) do
    normalized = String.downcase(value)

    Regex.match?(~r/\b\d{1,3}%/u, normalized) or
      Enum.any?(@internal_terms, &String.contains?(normalized, &1))
  end
end
