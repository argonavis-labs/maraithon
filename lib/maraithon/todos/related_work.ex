defmodule Maraithon.Todos.RelatedWork do
  @moduledoc """
  Retrieves older open work for the intake model without a provider round trip.

  Text overlap only selects context: the model still decides whether the owner,
  request, and source evidence describe the same outstanding work. In particular,
  a repeated reminder's new message ID must not hide the original todo.
  """

  import Ecto.Query

  alias Maraithon.PromptBudget
  alias Maraithon.Repo
  alias Maraithon.Todos.Todo

  @candidate_limit 8
  @matches_per_candidate 5
  @text_bytes 4_000

  def find(user_id, candidates) when is_binary(user_id) and is_list(candidates) do
    texts =
      candidates
      |> Enum.take(@candidate_limit)
      |> Enum.map(&candidate_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if texts == [], do: [], else: retrieve(user_id, texts)
  end

  defp retrieve(user_id, texts) do
    # Compute the user's compact search documents once for the whole handoff.
    # Only IDs leave this query; hydrate at most five matches per candidate.
    # Weight overlap by inverse document frequency: distinctive people/ticket
    # references must outrank boilerplate repeated across hundreds of reminders.
    # Round-robin rank keeps every candidate represented ahead of recent work
    # when the prompt has to shed optional context.
    sql = """
    WITH candidate_terms AS MATERIALIZED (
      SELECT ordinal, lexeme
      FROM unnest($2::text[]) WITH ORDINALITY AS input(text, ordinal)
      CROSS JOIN LATERAL unnest(tsvector_to_array(to_tsvector('english', input.text))) AS lexeme
    ), documents AS MATERIALIZED (
      SELECT id, inserted_at,
        tsvector_to_array(to_tsvector('english', concat_ws(' ', title, summary, next_action))) AS lexemes
      FROM todos
      WHERE user_id = $1 AND status IN ('open', 'snoozed')
    ), matches AS MATERIALIZED (
      SELECT id, inserted_at, lexeme
      FROM documents CROSS JOIN LATERAL unnest(lexemes) AS lexeme
      WHERE lexeme IN (SELECT lexeme FROM candidate_terms)
    ), frequencies AS (
      SELECT lexeme, count(*) AS frequency FROM matches GROUP BY lexeme
    ), scores AS (
      SELECT candidate_terms.ordinal, matches.id, matches.inserted_at,
        sum(1.0 / frequencies.frequency) AS score
      FROM matches
      JOIN frequencies USING (lexeme)
      JOIN candidate_terms USING (lexeme)
      GROUP BY candidate_terms.ordinal, matches.id, matches.inserted_at
    ), ranked AS (
      SELECT ordinal, id,
        row_number() OVER (PARTITION BY ordinal ORDER BY score DESC, inserted_at, id) AS rank
      FROM scores
    )
    SELECT id FROM ranked WHERE rank <= $3 ORDER BY rank, ordinal
    """

    ids =
      Repo.query!(sql, [user_id, texts, @matches_per_candidate])
      |> Map.fetch!(:rows)
      |> Enum.map(fn [id] -> Ecto.UUID.load!(id) end)
      |> Enum.uniq()

    by_id =
      Todo
      |> where([todo], todo.user_id == ^user_id and todo.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, fn id ->
      case Map.get(by_id, id) do
        nil -> []
        todo -> [todo]
      end
    end)
  end

  defp candidate_text(candidate) when is_map(candidate) do
    [Map.get(candidate, "title"), Map.get(candidate, "summary")]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
    |> String.trim()
    |> PromptBudget.truncate_utf8(@text_bytes)
  end

  defp candidate_text(_candidate), do: ""
end
