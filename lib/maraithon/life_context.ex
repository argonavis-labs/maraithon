defmodule Maraithon.LifeContext do
  @moduledoc "User-authored life and work context, with a reviewable interpretation in encrypted memory."
  import Ecto.Query
  alias Maraithon.{Crm, Memory, Repo}
  alias Maraithon.Memory.Item
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Runtime.BackgroundJobs

  @source "life_work_context"
  @tag "life_work_note"

  def list(user_id) do
    Memory.list_items(user_id, tag: @tag, limit: 50)
    |> Enum.filter(&(&1.source == @source))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  def get(user_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Item{source: @source, status: "active"} = note <- Memory.get_item_for_user(user_id, id) do
      note
    else
      _ -> nil
    end
  end

  def capture(user_id, attrs) do
    text = if is_binary(attrs["text"]), do: String.trim(attrs["text"])
    domain = if attrs["domain"] in ~w(life work both), do: attrs["domain"], else: "both"
    request_id = attrs["request_id"] || Ecto.UUID.generate()

    with true <- is_binary(text) and String.length(text) in 10..10_000,
         {:ok, request_id} <- Ecto.UUID.cast(request_id) do
      Repo.transaction(fn ->
        WriteFence.lock_user_writable!(user_id)
        dedupe = "life-work:#{request_id}"
        existing = Repo.get_by(Item, user_id: user_id, dedupe_key: dedupe, status: "active")

        if existing do
          if existing.content != text, do: Repo.rollback(:request_conflict)
          existing
        else
          note =
            write!(user_id, %{
              "title" => if(domain == "work", do: "Work context", else: "Life & work context"),
              "content" => text,
              "dedupe_key" => dedupe,
              "metadata" => %{
                "state" => "queued",
                "domain" => domain,
                "input_mode" => if(attrs["input_mode"] == "voice", do: "voice", else: "text")
              }
            })

          enqueue!(note)
          note
        end
      end)
    else
      _ -> {:error, :invalid_context}
    end
  end

  def retry(user_id, id) do
    transaction(user_id, id, fn note ->
      unless note.metadata["state"] == "failed", do: Repo.rollback(:not_ready)
      note = update!(note, %{"state" => "queued"})
      enqueue!(note)
      note
    end)
  end

  def confirm(user_id, id, attrs) do
    summary = text(attrs["summary"], 2_000)
    rules = strings(attrs["rules"], 12, 600)

    if summary do
      transaction(user_id, id, fn note ->
        unless note.metadata["state"] in ~w(review confirmed), do: Repo.rollback(:not_ready)

        note =
          update!(note, %{
            "state" => "confirmed",
            "summary" => summary,
            "rules" => rules,
            "confirmed_at" => timestamp()
          })

        # One replaceable instruction per note prevents edited rules lingering.
        case Memory.write(user_id, %{
               "kind" => "instruction",
               "title" => "Life & work guidance",
               "content" => Enum.join([summary | rules], "\n"),
               "source" => @source,
               "author_type" => "user",
               "confidence" => 1.0,
               "importance" => 90,
               "tags" => ["life_work_context", "todo_scope"],
               "source_ref_type" => "memory",
               "source_ref_id" => note.id,
               "dedupe_key" => "life-work-guidance:#{note.id}"
             }) do
          {:ok, _} ->
            invalidate_todos!(user_id)
            note

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    else
      {:error, :invalid_context}
    end
  end

  def archive(user_id, id) do
    transaction(user_id, id, fn note ->
      guidance =
        Repo.get_by(Item,
          user_id: user_id,
          dedupe_key: "life-work-guidance:#{note.id}",
          status: "active"
        )

      if guidance, do: archive_memory!(user_id, guidance.id)
      archived = archive_memory!(user_id, note.id)
      invalidate_todos!(user_id)
      archived
    end)
  end

  defp archive_memory!(user_id, id) do
    case Memory.forget(user_id, id, source: @source) do
      {:ok, item} -> item
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Refresh on demand without scheduling the whole inventory or calling a model in this transaction.
  def invalidate_todos!(user_id) do
    revision = Ecto.UUID.generate()

    from(t in Maraithon.Todos.Todo,
      where: t.user_id == ^user_id and t.status in ~w(triage open snoozed),
      update: [
        set: [
          metadata:
            fragment(
              "COALESCE(?, '{}'::jsonb) || ?::jsonb",
              t.metadata,
              ^%{"life_context_revision" => revision}
            )
        ]
      ]
    )
    |> Repo.update_all([])

    :ok
  end

  def transaction(user_id, id, fun) do
    Repo.transaction(fn ->
      WriteFence.lock_user_writable!(user_id)

      with {:ok, id} <- Ecto.UUID.cast(id),
           %Item{source: @source, status: "active"} = note <-
             Repo.one(
               from n in Item, where: n.user_id == ^user_id and n.id == ^id, lock: "FOR UPDATE"
             ) do
        fun.(note)
      else
        _ -> Repo.rollback(:not_found)
      end
    end)
  end

  def update!(%Item{} = note, metadata) do
    write!(note.user_id, %{
      "id" => note.id,
      "title" => note.title,
      "content" => note.content,
      "dedupe_key" => note.dedupe_key,
      "metadata" => Map.merge(note.metadata || %{}, metadata)
    })
  end

  def serialize(note) do
    metadata = note.metadata || %{}

    %{
      id: note.id,
      text: note.content,
      state: metadata["state"] || "queued",
      domain: metadata["domain"] || "both",
      summary: metadata["summary"],
      rules: metadata["rules"] || [],
      people: metadata["people"] || [],
      confirmed_at: metadata["confirmed_at"],
      created_at: DateTime.to_iso8601(note.inserted_at)
    }
  end

  def prompt_context(user_id) do
    list(user_id)
    |> Enum.filter(&(&1.metadata["state"] == "confirmed"))
    |> Enum.take(16)
    |> Enum.map(fn note ->
      %{
        domain: note.metadata["domain"],
        summary: text(note.metadata["summary"], 800),
        rules: strings(note.metadata["rules"], 12, 300)
      }
    end)
    |> Enum.reduce_while([], fn item, items ->
      next = items ++ [item]
      if byte_size(Jason.encode!(next)) <= 12_000, do: {:cont, next}, else: {:halt, items}
    end)
  end

  def confirmed_people(user_id) do
    Repo.all(
      from p in Crm.Person,
        where: p.user_id == ^user_id and p.status == "active",
        where: fragment("?->'confirmed_details' IS NOT NULL", p.metadata),
        order_by: [desc: p.updated_at],
        limit: 16
    )
  end

  defp write!(user_id, attrs) do
    attrs =
      Map.merge(attrs, %{
        "source" => @source,
        "tags" => [@tag],
        "author_type" => "user",
        "kind" => "fact",
        "confidence" => 1.0,
        "importance" => 85
      })

    case Memory.write(user_id, attrs) do
      {:ok, note} -> note
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp enqueue!(note) do
    case BackgroundJobs.enqueue("life_context_preparation", %{
           user_id: note.user_id,
           queue: Maraithon.Todos.Brief.queue(),
           rate_limit_key: "model",
           max_attempts: 3,
           partition_key:
             "tenant:#{:crypto.hash(:sha256, note.user_id) |> Base.url_encode64(padding: false)}",
           dedupe_key: "life-context:#{note.id}:#{DateTime.to_iso8601(note.updated_at)}",
           payload: %{"note_id" => note.id}
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def text(value, max) when is_binary(value) do
    case String.trim(value) |> String.slice(0, max) do
      "" -> nil
      value -> value
    end
  end

  def text(_, _), do: nil

  def strings(values, count, length) do
    values
    |> List.wrap()
    |> Enum.map(&text(&1, length))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(count)
  end

  def timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
