defmodule Maraithon.Todos.RelevanceMemory do
  @moduledoc """
  Recalls a bounded set of the user's learned relevance patterns for the work
  being judged. Learning and admission use the same account-scoped retrieval.
  """

  alias Maraithon.Memory
  alias Maraithon.Memory.Recall

  def recall(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    {:ok, items, _metadata} =
      Recall.recall(user_id,
        query: String.slice(query, 0, 6_000),
        kind: "relevance_feedback",
        tag: "todo_relevance",
        limit: limit,
        candidate_limit: 500,
        max_tokens: 8_000
      )

    items
  rescue
    # Keep established preferences available if semantic recall is unavailable.
    _error ->
      Memory.list_items(user_id,
        kind: "relevance_feedback",
        tag: "todo_relevance",
        status: "active",
        limit: Keyword.get(opts, :limit, 24)
      )
  end
end
