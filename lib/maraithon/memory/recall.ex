defmodule Maraithon.Memory.Recall do
  @moduledoc """
  Centralized candidate recall for durable memory.

  This module ranks already-decrypted `Memory.Item` rows under a token budget.
  The scoring is deliberately only candidate selection: model-facing callers can
  still do semantic relevance selection after this narrows the context.
  """

  import Ecto.Query

  alias Maraithon.Memory.Item
  alias Maraithon.Repo

  @default_limit 25
  @default_max_tokens 1_500
  @default_candidate_limit 120
  @max_candidate_limit 500

  def recall(user_id, opts \\ [])

  def recall(user_id, opts) when is_binary(user_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = bounded_integer(opts, :limit, @default_limit, 1, 100)
    max_tokens = bounded_integer(opts, :max_tokens, @default_max_tokens, 100, 8_000)

    candidate_limit =
      bounded_integer(
        opts,
        :candidate_limit,
        @default_candidate_limit,
        limit,
        @max_candidate_limit
      )

    query = opts |> Keyword.get(:query) |> normalize_text()
    filters = normalized_filters(opts)

    scored =
      user_id
      |> candidates_query(filters, now, Keyword.get(opts, :include_superseded, false))
      |> limit(^candidate_limit)
      |> Repo.all()
      |> Enum.map(&{&1, score(&1, query, filters, now)})
      |> Enum.sort_by(fn {_item, score} -> score end, :desc)

    {items, used_tokens, dropped} = apply_budget(scored, limit, max_tokens)

    {:ok, items, %{used_tokens: used_tokens, dropped: dropped, candidate_count: length(scored)}}
  end

  def recall(_user_id, _opts), do: {:error, :invalid_user}

  defp candidates_query(user_id, filters, now, include_superseded?) do
    Item
    |> where([item], item.user_id == ^user_id)
    |> maybe_status_filter(include_superseded?)
    |> where([item], is_nil(item.expires_at) or item.expires_at > ^now)
    |> maybe_filter_values(:kind, filters.kinds)
    |> maybe_filter_values(:scope, filters.scopes)
    |> maybe_filter_tag(filters.tag)
    |> maybe_filter_source_ref(filters.source_ref_type, filters.source_ref_id)
    |> order_by([item], desc: item.importance, desc: item.updated_at, desc: item.inserted_at)
  end

  defp maybe_status_filter(query, true),
    do: where(query, [item], item.status in ["active", "superseded"])

  defp maybe_status_filter(query, false), do: where(query, [item], item.status == "active")

  defp maybe_filter_values(query, _field, []), do: query

  defp maybe_filter_values(query, field, values) do
    where(query, [item], field(item, ^field) in ^values)
  end

  defp maybe_filter_tag(query, nil), do: query
  defp maybe_filter_tag(query, tag), do: where(query, [item], ^tag in item.tags)

  defp maybe_filter_source_ref(query, nil, _source_ref_id), do: query
  defp maybe_filter_source_ref(query, _source_ref_type, nil), do: query

  defp maybe_filter_source_ref(query, source_ref_type, source_ref_id) do
    where(
      query,
      [item],
      item.source_ref_type == ^source_ref_type and item.source_ref_id == ^source_ref_id
    )
  end

  # Weights intentionally sum around a 100-point scale. Query and subject boosts
  # are boosts, not gates, so the model can still see high-value adjacent facts.
  defp score(%Item{} = item, query, filters, now) do
    importance = (item.importance || 50) * 0.45
    confidence = (item.confidence || 0.75) * 100 * 0.30
    recency = recency_score(item, now) * 0.10
    subject = subject_match_score(item, filters) * 0.20
    query_match = query_match_score(item, query) * 0.15
    decay = decay_penalty(item, now)

    importance + confidence + recency + subject + query_match + decay
  end

  defp recency_score(item, now) do
    timestamp = item.last_used_at || item.updated_at || item.inserted_at

    case timestamp do
      %DateTime{} = timestamp ->
        age_days = max(DateTime.diff(now, timestamp, :day), 0)
        max(100 - age_days * 4, 0)

      _other ->
        0
    end
  end

  defp subject_match_score(item, filters) do
    metadata = item.metadata || %{}

    [
      same?(Map.get(metadata, "subject_type"), filters.subject_type),
      same?(Map.get(metadata, "subject_id"), filters.subject_id),
      same?(Map.get(metadata, "project_id"), filters.project_id),
      same?(Map.get(metadata, "person_id"), filters.person_id),
      same?(item.source_ref_type, filters.subject_type) and
        same?(item.source_ref_id, filters.subject_id)
    ]
    |> Enum.count(& &1)
    |> case do
      0 -> 0
      count -> min(60 + count * 10, 100)
    end
  end

  defp query_match_score(_item, nil), do: 0

  defp query_match_score(item, query) do
    haystack =
      [
        item.title,
        item.content,
        item.summary,
        item.source,
        item.source_ref_type,
        item.source_ref_id,
        Jason.encode!(item.metadata || %{}),
        Enum.join(item.tags || [], " ")
      ]
      |> Enum.join(" ")
      |> String.downcase()

    query
    |> query_terms()
    |> Enum.count(&String.contains?(haystack, &1))
    |> case do
      0 -> 0
      count -> min(60 + count * 10, 100)
    end
  end

  defp decay_penalty(%{decay_at: %DateTime{} = decay_at}, now) do
    if DateTime.compare(decay_at, now) in [:lt, :eq], do: -20, else: 0
  end

  defp decay_penalty(_item, _now), do: 0

  defp apply_budget(scored, limit, max_tokens) do
    Enum.reduce(scored, {[], 0, 0}, fn {item, _score}, {items, used_tokens, dropped} ->
      item_tokens = estimate_tokens(item)

      cond do
        length(items) >= limit ->
          {items, used_tokens, dropped + 1}

        used_tokens + item_tokens <= max_tokens ->
          {[item | items], used_tokens + item_tokens, dropped}

        true ->
          {items, used_tokens, dropped + 1}
      end
    end)
    |> then(fn {items, used_tokens, dropped} -> {Enum.reverse(items), used_tokens, dropped} end)
  end

  defp estimate_tokens(%Item{} = item) do
    [
      item.kind,
      item.scope,
      item.title,
      item.summary,
      item.content,
      item.source,
      item.source_ref_type,
      item.source_ref_id
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.length()
    |> Kernel./(4)
    |> Float.ceil()
    |> trunc()
    |> max(24)
  end

  defp normalized_filters(opts) do
    %{
      kinds: string_list(Keyword.get(opts, :kinds) || Keyword.get(opts, :kind)),
      scopes: string_list(Keyword.get(opts, :scopes) || Keyword.get(opts, :scope)),
      tag: opts |> Keyword.get(:tag) |> normalize_text(),
      subject_type: opts |> Keyword.get(:subject_type) |> normalize_text(),
      subject_id: opts |> Keyword.get(:subject_id) |> normalize_text(),
      project_id: opts |> Keyword.get(:project_id) |> normalize_text(),
      person_id: opts |> Keyword.get(:person_id) |> normalize_text(),
      source_ref_type: opts |> Keyword.get(:source_ref_type) |> normalize_text(),
      source_ref_id: opts |> Keyword.get(:source_ref_id) |> normalize_text()
    }
  end

  defp string_list(nil), do: []

  defp string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp string_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> string_list()
  end

  defp string_list(_value), do: []

  defp query_terms(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^a-z0-9:_-]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.uniq()
  end

  defp bounded_integer(opts, key, default, minimum, maximum) do
    opts
    |> Keyword.get(key, default)
    |> case do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _other -> default
    end
    |> max(minimum)
    |> min(maximum)
  end

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> default
    end
  end

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_value), do: nil

  defp same?(_left, nil), do: false
  defp same?(nil, _right), do: false
  defp same?(left, right), do: to_string(left) == to_string(right)
end
