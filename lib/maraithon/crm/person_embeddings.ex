defmodule Maraithon.Crm.PersonEmbeddings do
  @moduledoc """
  Build, write, and refresh CRM person embeddings used for semantic resolve.

  The embedding source text is intentionally compact (display name +
  relationship facts + a few normalized contact identifiers + the first
  chunk of notes) so cheap embeddings stay accurate without leaking long
  free-text bodies.
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

    cond do
      text == "" ->
        {:ok, :empty}

      not force? and hash == person.embedding_source_hash ->
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
    person
    |> Person.changeset(%{
      embedding: Pgvector.new(vector),
      embedding_source_hash: hash,
      embedding_refreshed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

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
