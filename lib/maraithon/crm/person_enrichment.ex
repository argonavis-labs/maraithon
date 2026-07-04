defmodule Maraithon.Crm.PersonEnrichment do
  @moduledoc """
  Durable public-web enrichment for CRM people.

  Briefings already fall back to web search for meeting attendees the CRM
  cannot explain — but that context evaporates with the briefing. This module
  makes enrichment durable: for people who matter right now (about to be met,
  or explicitly requested), run a bounded public search and store what came
  back on the person, so dossiers, the People surface, and the assistant can
  all cite it.

  Stored under `metadata["enrichment"]`:
  `%{"query", "sources" => [%{"title", "url", "snippet"}], "page_excerpt",
  "fetched_at"}`. User-authored `notes` are never touched.
  """

  alias Maraithon.Crm.Person
  alias Maraithon.Crm.UpcomingMeetings
  alias Maraithon.Repo
  alias Maraithon.WebSearch

  require Logger

  @staleness_days 30
  @max_per_run 5
  @max_sources 3
  @page_excerpt_chars 700
  @free_mail_domains ~w(gmail.com googlemail.com yahoo.com icloud.com me.com mac.com
                        hotmail.com outlook.com live.com aol.com proton.me protonmail.com)

  @doc """
  Enrich people the user is meeting in the next few weeks who lack fresh
  enrichment. Bounded to #{@max_per_run} people per run out of respect for
  the search backend.

  Returns `{:ok, %{candidates: n, enriched: n, skipped: n, failed: n}}`.
  """
  def run_for_upcoming(user_id, opts \\ []) when is_binary(user_id) do
    days = Keyword.get(opts, :days, 21)
    max = opts |> Keyword.get(:max, @max_per_run) |> min(20)

    candidates =
      user_id
      |> UpcomingMeetings.people_meeting_soon(days: days)
      |> Enum.map(& &1.person)
      |> Enum.filter(&needs_enrichment?/1)
      |> Enum.take(max)

    result =
      Enum.reduce(candidates, %{enriched: 0, skipped: 0, failed: 0}, fn person, acc ->
        case ensure_enrichment(user_id, person) do
          {:ok, :enriched} -> Map.update!(acc, :enriched, &(&1 + 1))
          {:ok, _skip_reason} -> Map.update!(acc, :skipped, &(&1 + 1))
          {:error, _reason} -> Map.update!(acc, :failed, &(&1 + 1))
        end
      end)

    {:ok, Map.put(result, :candidates, length(candidates))}
  end

  @doc """
  Fetch and store public-web context for one person, unless a fresh
  enrichment already exists.

  Returns `{:ok, :enriched | :fresh | :no_query | :no_results | :disabled}`
  or `{:error, reason}`.
  """
  def ensure_enrichment(user_id, %Person{} = person, opts \\ []) when is_binary(user_id) do
    force? = Keyword.get(opts, :force, false)

    cond do
      not force? and not needs_enrichment?(person) ->
        {:ok, :fresh}

      not WebSearch.enabled?([]) ->
        {:ok, :disabled}

      true ->
        case build_query(person) do
          nil -> {:ok, :no_query}
          query -> search_and_store(person, query)
        end
    end
  end

  @doc "True when the person has no enrichment or it is older than #{@staleness_days} days."
  def needs_enrichment?(%Person{metadata: metadata}) do
    case get_in(metadata || %{}, ["enrichment", "fetched_at"]) do
      fetched_at when is_binary(fetched_at) ->
        case DateTime.from_iso8601(fetched_at) do
          {:ok, at, _offset} ->
            DateTime.diff(DateTime.utc_now(), at, :day) >= @staleness_days

          _ ->
            true
        end

      _ ->
        true
    end
  end

  def needs_enrichment?(_person), do: true

  # ---------------------------------------------------------------------------

  defp search_and_store(person, query) do
    case WebSearch.search(query, limit: @max_sources) do
      {:ok, %{"results" => results}} when is_list(results) and results != [] ->
        sources =
          results
          |> Enum.take(@max_sources)
          |> Enum.map(fn result ->
            %{
              "title" => result["title"],
              "url" => result["url"],
              "snippet" => result["snippet"]
            }
          end)

        enrichment = %{
          "query" => query,
          "sources" => sources,
          "page_excerpt" => first_page_excerpt(sources),
          "fetched_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        store(person, enrichment)

      {:ok, _empty} ->
        {:ok, :no_results}

      {:error, :web_search_disabled} ->
        {:ok, :disabled}

      {:error, reason} ->
        Logger.warning("Person enrichment search failed",
          person_id: person.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp first_page_excerpt([%{"url" => url} | _]) when is_binary(url) do
    case WebSearch.fetch_page(url) do
      {:ok, %{"text" => text}} when is_binary(text) ->
        text |> String.slice(0, @page_excerpt_chars) |> String.trim()

      _ ->
        nil
    end
  end

  defp first_page_excerpt(_sources), do: nil

  defp store(person, enrichment) do
    metadata = Map.put(person.metadata || %{}, "enrichment", enrichment)

    person
    |> Ecto.Changeset.change(metadata: metadata)
    |> Repo.update()
    |> case do
      {:ok, _person} ->
        {:ok, :enriched}

      {:error, changeset} ->
        Logger.warning("Person enrichment store failed",
          person_id: person.id,
          reason: inspect(changeset.errors)
        )

        {:error, :store_failed}
    end
  end

  # "Jane Doe acme.com" beats "Jane Doe" — a work-email domain is the
  # strongest public disambiguator we hold. Free-mail domains add nothing.
  defp build_query(%Person{} = person) do
    name = displayable_name(person)

    if name do
      [name, work_domain(person), org_hint(person)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.join(" ")
    end
  end

  defp displayable_name(%Person{display_name: display_name}) when is_binary(display_name) do
    trimmed = String.trim(display_name)

    # A bare handle or single token is too ambiguous to search usefully.
    if String.contains?(trimmed, " ") and not String.contains?(trimmed, "@") do
      trimmed
    end
  end

  defp displayable_name(_person), do: nil

  defp work_domain(%Person{contact_details: details}) when is_map(details) do
    details
    |> Map.get("emails")
    |> List.wrap()
    |> Enum.flat_map(fn email ->
      case String.split(to_string(email), "@") do
        [_local, domain] -> [String.downcase(String.trim(domain))]
        _ -> []
      end
    end)
    |> Enum.reject(&(&1 == "" or &1 in @free_mail_domains))
    |> List.first()
  end

  defp work_domain(_person), do: nil

  defp org_hint(%Person{relationship: relationship}) when is_binary(relationship) do
    trimmed = String.trim(relationship)
    if trimmed != "" and String.length(trimmed) <= 60, do: trimmed
  end

  defp org_hint(_person), do: nil
end
