defmodule Maraithon.Crm.PersonEmbeddings do
  @moduledoc """
  Build, write, and refresh CRM person embeddings used for semantic resolve.

  The embedding source text is intentionally compact (display name +
  relationship facts + a few normalized contact identifiers + the first
  chunk of notes) so cheap embeddings stay accurate without leaking long
  free-text bodies.

  All write operations are no-ops when the `crm_people.embedding` column
  isn't present (e.g. on Fly Managed Postgres before pgvector has been
  enabled by a superuser). That lets the rest of the CRM keep working
  without semantic resolve until the extension is installed.
  """

  import Ecto.Query

  alias Maraithon.Crm.Person
  alias Maraithon.LLM.Embeddings
  alias Maraithon.Repo

  require Logger

  @max_notes_chars 800

  @doc """
  Build the canonical embedding source text for a person.
  """
  def source_text(%Person{} = person) do
    parts =
      [
        person.display_name,
        person.first_name,
        person.last_name,
        person.relationship,
        person.preferred_communication_method &&
          "prefers #{person.preferred_communication_method}",
        person.communication_frequency &&
          "talks #{person.communication_frequency}",
        contact_summary(person.contact_details),
        notes_excerpt(person.notes)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    parts
    |> Enum.join("\n")
    |> String.trim()
  end

  def source_text(_other), do: ""

  @doc "Stable hash of the embedding source text."
  def source_hash(%Person{} = person), do: source_hash(source_text(person))

  def source_hash(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  def source_hash(_other), do: nil

  @doc """
  Recompute and store the embedding for a person if the source text has
  changed since the last refresh.
  """
  def refresh(person, opts \\ [])

  def refresh(%Person{} = person, opts) do
    text = source_text(person)
    hash = source_hash(text)
    force? = Keyword.get(opts, :force, false)
    current_hash = current_embedding_hash(person)

    cond do
      text == "" ->
        {:ok, :empty}

      not embedding_storage_available?() ->
        {:ok, :pgvector_unavailable}

      not force? and hash == current_hash ->
        {:ok, :unchanged}

      true ->
        case Embeddings.embed(text, opts) do
          {:ok, vector} ->
            store(person, vector, hash)

          {:error, reason} ->
            Logger.warning("Person embedding refresh failed",
              person_id: person.id,
              reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  end

  def refresh(_person, _opts), do: {:error, :invalid_person}

  @doc """
  Spawn a background refresh; the inbound write path never blocks on it.
  """
  def refresh_async(person, opts \\ [])

  def refresh_async(%Person{} = person, opts) do
    if async_enabled?() do
      Task.start(fn ->
        try do
          refresh(person, opts)
        rescue
          error ->
            Logger.warning("Person embedding refresh crashed",
              person_id: person.id,
              reason: Exception.message(error)
            )
        end
      end)
    end

    :ok
  end

  def refresh_async(_person, _opts), do: :ok

  defp async_enabled? do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:async_enabled, true)
  end

  @doc """
  Backfill embeddings for a user. Returns counts so callers can report
  progress.
  """
  def backfill_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 200)
    only_missing? = Keyword.get(opts, :only_missing, true)

    base =
      Person
      |> where([p], p.user_id == ^user_id)
      |> limit(^limit)

    query =
      if only_missing? do
        where(base, [p], is_nil(p.embedding) or is_nil(p.embedding_source_hash))
      else
        base
      end

    persons = Repo.all(query)

    Enum.reduce(persons, %{refreshed: 0, skipped: 0, failed: 0}, fn person, acc ->
      case refresh(person, opts) do
        {:ok, :empty} -> Map.update!(acc, :skipped, &(&1 + 1))
        {:ok, :unchanged} -> Map.update!(acc, :skipped, &(&1 + 1))
        {:ok, %Person{}} -> Map.update!(acc, :refreshed, &(&1 + 1))
        {:error, _reason} -> Map.update!(acc, :failed, &(&1 + 1))
      end
    end)
  end

  defp store(person, vector, hash) do
    pgvector = Pgvector.new(vector)
    now = DateTime.utc_now()

    Repo.query!(
      """
      UPDATE crm_people
      SET embedding = $1::vector,
          embedding_source_hash = $2,
          embedding_refreshed_at = $3
      WHERE id = $4
      """,
      [pgvector, hash, now, Ecto.UUID.dump!(person.id)]
    )

    {:ok,
     %{
       person
       | __meta__: person.__meta__
     }
     |> Map.put(:embedding, pgvector)
     |> Map.put(:embedding_source_hash, hash)
     |> Map.put(:embedding_refreshed_at, now)}
  end

  defp embedding_storage_available? do
    case Process.get(:maraithon_pgvector_available) do
      nil ->
        available =
          try do
            %{rows: rows} =
              Repo.query!(
                "SELECT 1 FROM information_schema.columns " <>
                  "WHERE table_name = 'crm_people' AND column_name = 'embedding'"
              )

            rows != []
          rescue
            _ -> false
          end

        Process.put(:maraithon_pgvector_available, available)
        available

      cached when is_boolean(cached) ->
        cached
    end
  end

  defp current_embedding_hash(%Person{id: id}) when is_binary(id) do
    if embedding_storage_available?() do
      case Repo.query!("SELECT embedding_source_hash FROM crm_people WHERE id = $1", [
             Ecto.UUID.dump!(id)
           ]) do
        %{rows: [[hash]]} when is_binary(hash) -> hash
        _ -> nil
      end
    else
      nil
    end
  end

  defp current_embedding_hash(_other), do: nil

  defp contact_summary(%{} = contact_details) do
    [
      first_or_nil(contact_details["emails"]),
      first_or_nil(contact_details["slack_ids"]),
      first_or_nil(contact_details["phones"]),
      first_or_nil(contact_details["telegram_ids"])
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      values -> Enum.join(values, " ")
    end
  end

  defp contact_summary(_other), do: nil

  defp first_or_nil([value | _]) when is_binary(value) and value != "", do: value
  defp first_or_nil(_other), do: nil

  defp notes_excerpt(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= @max_notes_chars -> trimmed
      true -> String.slice(trimmed, 0, @max_notes_chars)
    end
  end

  defp notes_excerpt(_other), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_other), do: false
end
