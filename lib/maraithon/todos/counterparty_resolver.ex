defmodule Maraithon.Todos.CounterpartyResolver do
  @moduledoc """
  SPEC 04 R1: deterministic resolution of a todo's free-text
  `counterparty_label` to exactly one active CRM person.

  Resolution is intentionally conservative: the label is searched through
  `Maraithon.Crm.list_people/2`, the results are narrowed to name-compatible
  candidates (the same first-token/full-name compatibility rule
  `Maraithon.Crm.PersonDeduper` uses for its deterministic merges — the
  minimal token check is duplicated here because that function is private
  to the deduper), and a person is returned only when exactly one candidate
  survives. Two or more compatible candidates are `:ambiguous`, zero are
  `:not_found` — never "just pick the first result". A wrong-person FK is
  worse than none, since every downstream consumer (the counterparty query
  filter, the relationship read path) would confidently return the wrong
  person's data.

  No LLM call ever happens on this path; only the backfill's model-gated
  second pass (`Maraithon.Todos.CounterpartyBackfill`) may resolve an
  ambiguous case.
  """

  alias Maraithon.Crm
  alias Maraithon.Crm.Person

  @default_search_limit 10

  @doc """
  Resolve `label` to exactly one active CRM person for `user_id`.

  Returns `{:ok, %Crm.Person{}}` when exactly one name-compatible candidate
  matches, `:ambiguous` for two or more, and `:not_found` for zero.
  """
  def resolve_person(user_id, label, opts \\ [])

  def resolve_person(user_id, label, opts)
      when is_binary(user_id) and is_binary(label) and is_list(opts) do
    case candidates(user_id, label, opts) do
      [%Person{} = person] -> {:ok, person}
      [] -> :not_found
      _two_or_more -> :ambiguous
    end
  end

  def resolve_person(_user_id, _label, _opts), do: :not_found

  @doc """
  The name-compatible active-person candidate set for `label`.

  Exposed so the backfill can hand the model the same candidates the
  deterministic pass judged ambiguous.
  """
  def candidates(user_id, label, opts \\ [])

  def candidates(user_id, label, opts)
      when is_binary(user_id) and is_binary(label) and is_list(opts) do
    label = String.trim(label)

    if label == "" do
      []
    else
      limit = Keyword.get(opts, :limit, @default_search_limit)

      user_id
      |> Crm.list_people(query: label, status: "active", limit: limit)
      |> Enum.filter(&label_compatible?(label, &1))
    end
  end

  def candidates(_user_id, _label, _opts), do: []

  @doc """
  Whether `label` is name-compatible with the person's display name, using
  the same single-token/first-token/full-name compatibility rule
  `Maraithon.Crm.PersonDeduper.name_compatible?/2` applies (duplicated here
  because that helper is private to the deduper).
  """
  def label_compatible?(label, %Person{} = person) do
    name_compatible?(normalize_name(label), normalize_name(person.display_name))
  end

  def label_compatible?(_label, _person), do: false

  defp name_compatible?(left_name, right_name)
       when is_binary(left_name) and is_binary(right_name) do
    left_tokens = String.split(left_name, " ", trim: true)
    right_tokens = String.split(right_name, " ", trim: true)

    cond do
      left_tokens == [] or right_tokens == [] ->
        false

      left_name == right_name ->
        true

      single_token?(left_tokens) and multi_token?(right_tokens) ->
        List.first(left_tokens) == List.first(right_tokens)

      multi_token?(left_tokens) and single_token?(right_tokens) ->
        List.first(left_tokens) == List.first(right_tokens)

      multi_token?(left_tokens) and multi_token?(right_tokens) ->
        compatible_full_names?(left_tokens, right_tokens)

      true ->
        false
    end
  end

  defp name_compatible?(_left_name, _right_name), do: false

  defp compatible_full_names?(left_tokens, right_tokens) do
    List.last(left_tokens) == List.last(right_tokens) and
      compatible_first_tokens?(List.first(left_tokens), List.first(right_tokens))
  end

  defp compatible_first_tokens?(left, right) when is_binary(left) and is_binary(right) do
    left == right or common_prefix_length(left, right) >= 4
  end

  defp compatible_first_tokens?(_left, _right), do: false

  defp common_prefix_length(left, right) do
    left
    |> String.graphemes()
    |> Enum.zip(String.graphemes(right))
    |> Enum.take_while(fn {left_char, right_char} -> left_char == right_char end)
    |> length()
  end

  defp single_token?([_token]), do: true
  defp single_token?(_tokens), do: false

  defp multi_token?(tokens), do: length(tokens) >= 2

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  defp normalize_name(_value), do: ""
end
