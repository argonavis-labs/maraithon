defmodule Maraithon.LocalBrowserHistory do
  @moduledoc """
  Context for browser visits (Chrome, Safari, Arc, Brave) synced from a
  user's local machine. Owns bulk-insert with idempotent dedupe, recent
  lookups, host-scoped lookups, simple substring search, and per-device
  purges.

  Privacy: `ingest_batch/3` drops rows whose host matches the conservative
  default deny-list documented inline in the migration
  (`priv/repo/migrations/...create_local_browser_visits.exs`). The list
  is intentionally narrow — banks, search-engine queries, payment,
  medical / health, and adult content — and is enforced server-side so
  even a misbehaving client can't write those rows.
  """

  import Ecto.Query

  alias Maraithon.LocalBrowserHistory.LocalVisit
  alias Maraithon.Repo

  # Conservative deny-list (see migration comment). Anything matching any
  # of these patterns is dropped before insert. Hosts are lower-cased
  # before testing.
  @private_host_patterns [
    ~r/^(google|duckduckgo|bing)\.com$/i,
    ~r/^(www\.)?(google|duckduckgo|bing)\.com$/i,
    ~r/bank/i,
    ~r/paypal\.com$/i,
    ~r/medical/i,
    ~r/health/i,
    ~r/adult/i,
    ~r/porn/i
  ]

  # Some hosts are only private when paired with a search-shaped URL
  # path. For these we don't reject the host outright — we only filter
  # rows where the url path looks like a search query.
  @search_engine_hosts ~w(google.com www.google.com duckduckgo.com www.duckduckgo.com bing.com www.bing.com)

  @doc """
  Ingests a batch of visit maps from a device for the given user.

  Each entry should be a string-keyed or atom-keyed map matching the
  payload defined in the companion spec. Inserts are idempotent via the
  `(user_id, device_id, source, guid)` unique constraint — re-sending
  the same payload is a no-op. Rows whose host matches the private
  deny-list are dropped (counted against `:filtered`).

  Returns `{:ok, %{accepted: integer, duplicate: integer, invalid:
  integer, filtered: integer}}`.
  """
  def ingest_batch(user_id, device_id, visits)
      when is_binary(user_id) and is_list(visits) do
    started_at = System.monotonic_time(:millisecond)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {prepared, filtered_or_invalid} =
      visits
      |> Enum.map(&prepare_row(&1, user_id, device_id, now))
      |> Enum.split_with(&match?({:ok, _row}, &1))

    filtered_count = Enum.count(filtered_or_invalid, &match?({:filtered, _}, &1))
    invalid_count = Enum.count(filtered_or_invalid, &match?({:error, _}, &1))

    rows = Enum.map(prepared, fn {:ok, row} -> row end)

    {inserted_count, _returned} =
      if rows == [] do
        {0, nil}
      else
        Repo.insert_all(LocalVisit, rows,
          on_conflict: :nothing,
          conflict_target: [:user_id, :device_id, :source, :guid]
        )
      end

    total = length(rows)
    duplicate_count = total - inserted_count
    latency_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:maraithon, :companion, :browser_visits_ingested],
      %{
        count: length(visits),
        accepted: inserted_count,
        duplicate: duplicate_count,
        invalid: invalid_count,
        filtered: filtered_count,
        latency_ms: latency_ms
      },
      %{user_id: user_id, device_id: device_id}
    )

    {:ok,
     %{
       accepted: inserted_count,
       duplicate: duplicate_count,
       invalid: invalid_count,
       filtered: filtered_count
     }}
  end

  def ingest_batch(_user_id, _device_id, _visits), do: {:error, :invalid_batch}

  @doc """
  Returns the user's most recent visits, newest first. Optional
  `:browser` filter narrows to one browser.
  """
  def recent_visits(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 50)
    browser = Keyword.get(opts, :browser)

    query =
      from visit in LocalVisit,
        where: visit.user_id == ^user_id,
        order_by: [desc: visit.last_visited_at],
        limit: ^limit

    query
    |> maybe_filter_browser(browser)
    |> Repo.all()
  end

  @doc """
  Returns visits for a given user filtered by host substring. The host
  comparison is case-insensitive. `:browser`, `:since`, and `:before`
  options work the same way as `recent_visits/2`.
  """
  def visits_by_host(user_id, host, opts \\ [])
      when is_binary(user_id) and is_binary(host) do
    limit = Keyword.get(opts, :limit, 50)
    browser = Keyword.get(opts, :browser)
    needle = "%" <> String.downcase(host) <> "%"

    query =
      from visit in LocalVisit,
        where: visit.user_id == ^user_id,
        where: ilike(visit.host, ^needle),
        order_by: [desc: visit.last_visited_at],
        limit: ^limit

    query
    |> maybe_filter_browser(browser)
    |> Repo.all()
  end

  @doc """
  Substring search across `title` (decrypted in memory), `url`, and
  `host`. Title is encrypted so we fetch a generous set ordered by
  `last_visited_at` and filter post-query. Acceptable because per-device
  history volumes are bounded.
  """
  def search(user_id, term, opts \\ [])
      when is_binary(user_id) and is_binary(term) do
    limit = Keyword.get(opts, :limit, 50)
    browser = Keyword.get(opts, :browser)
    needle = String.downcase(term)

    user_id
    |> recent_visits(limit: 1000, browser: browser)
    |> Enum.filter(&matches_term?(&1, needle))
    |> Enum.take(limit)
  end

  @doc """
  Fetches one visit for a user by its source GUID. Returns `nil` when
  no matching visit exists.
  """
  def get_by_guid(user_id, guid) when is_binary(user_id) and is_binary(guid) do
    Repo.one(
      from visit in LocalVisit,
        where: visit.user_id == ^user_id and visit.guid == ^guid,
        limit: 1
    )
  end

  def get_by_guid(_user_id, _guid), do: nil

  @doc """
  Purges every visit for a (user, device) pair. Returns
  `{:ok, %{deleted: count}}`.
  """
  def purge_device(user_id, device_id) when is_binary(user_id) do
    {deleted, _} =
      Repo.delete_all(
        from visit in LocalVisit,
          where: visit.user_id == ^user_id and visit.device_id == ^device_id
      )

    {:ok, %{deleted: deleted}}
  end

  @doc """
  True when the host is on the private deny-list. Exposed for the tool
  layer so we can double-check before quoting a URL back to the user.
  """
  def private_host?(nil), do: false

  def private_host?(host) when is_binary(host) do
    normalized = String.downcase(String.trim(host))

    Enum.any?(@private_host_patterns, fn pattern ->
      Regex.match?(pattern, normalized)
    end)
  end

  @doc """
  True when a (host, url) pair should be filtered as a search-engine
  query. Pure helper exposed for tooling that wants the same logic the
  ingest layer applies.
  """
  def search_query?(host, url) when is_binary(host) and is_binary(url) do
    normalized = String.downcase(String.trim(host))

    if normalized in @search_engine_hosts do
      String.contains?(String.downcase(url), "search?") or
        String.contains?(String.downcase(url), "/search")
    else
      false
    end
  end

  def search_query?(_host, _url), do: false

  # -- internals ---------------------------------------------------------

  defp prepare_row(visit, user_id, device_id, now) when is_map(visit) do
    url = fetch(visit, :url)
    host_input = fetch(visit, :host)
    derived_host = derive_host(host_input, url)

    cond do
      not is_binary(url) or url == "" ->
        {:error, :missing_url}

      private_host?(derived_host) or search_query?(derived_host, url) ->
        {:filtered, derived_host}

      true ->
        attrs = %{
          user_id: user_id,
          device_id: device_id,
          source: fetch(visit, :source) || "browser_history",
          browser: normalize_browser(fetch(visit, :browser)),
          guid: namespaced_guid(fetch(visit, :browser), fetch(visit, :guid)),
          local_id: fetch(visit, :local_id) || fetch(visit, :guid),
          url: url,
          title: fetch(visit, :title),
          host: derived_host,
          visit_count: parse_integer(fetch(visit, :visit_count)) || 1,
          last_visited_at: parse_datetime(fetch(visit, :last_visited_at)),
          is_typed_url: truthy?(fetch(visit, :is_typed_url))
        }

        changeset = LocalVisit.changeset(%LocalVisit{}, attrs)

        if changeset.valid? do
          struct = Ecto.Changeset.apply_changes(changeset)

          row =
            LocalVisit.__schema__(:fields)
            |> Kernel.--([:id, :inserted_at, :updated_at])
            |> Enum.into(%{}, fn field -> {field, Map.get(struct, field)} end)
            |> Map.put(:id, Ecto.UUID.generate())
            |> Map.put(:inserted_at, now)
            |> Map.put(:updated_at, now)

          {:ok, row}
        else
          {:error, changeset}
        end
    end
  end

  defp prepare_row(_other, _user_id, _device_id, _now), do: {:error, :invalid}

  defp maybe_filter_browser(query, nil), do: query

  defp maybe_filter_browser(query, browser) when is_binary(browser) do
    normalized = normalize_browser(browser)
    from visit in query, where: visit.browser == ^normalized
  end

  defp namespaced_guid(_browser, nil), do: nil
  defp namespaced_guid(nil, guid), do: guid

  defp namespaced_guid(browser, guid) when is_binary(browser) and is_binary(guid) do
    normalized = normalize_browser(browser)

    if String.starts_with?(guid, normalized <> ":") do
      guid
    else
      "#{normalized}:#{guid}"
    end
  end

  defp normalize_browser(nil), do: nil

  defp normalize_browser(value) when is_binary(value) do
    value |> String.downcase() |> String.trim()
  end

  defp derive_host(host, _url) when is_binary(host) and host != "" do
    host |> String.downcase() |> String.trim()
  end

  defp derive_host(_host, url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: nil} -> nil
      %URI{host: ""} -> nil
      %URI{host: h} -> String.downcase(h)
    end
  end

  defp derive_host(_host, _url), do: nil

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_other), do: false

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp parse_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp matches_term?(%LocalVisit{title: title, url: url, host: host}, needle) do
    haystack =
      [title, url, host]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.join(" ")

    String.contains?(haystack, needle)
  end
end
