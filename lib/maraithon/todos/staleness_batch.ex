defmodule Maraithon.Todos.StalenessBatch do
  @moduledoc """
  Persisted state for one batched staleness-triage Telegram card (SPEC 05 R10).

  A batch links the `(chat_id, message_id)` of the sent card to the todo ids
  it proposed, so `TelegramAssistant.TodoActions` can re-render the SAME
  multi-item message as each Keep/Done/Dismiss button is tapped instead of
  overwriting it with a single-todo card. `resolved` is keyed by todo id
  (string) and written with `Map.put`, so a duplicate tap simply re-writes the
  same resolution — never appends or double-counts.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Maraithon.Repo

  @primary_key {:id, :binary_id, autogenerate: true}

  @statuses ~w(open complete)
  @actions ~w(important done dismiss)

  schema "todo_staleness_batches" do
    field :user_id, :string
    field :chat_id, :string
    field :message_id, :string
    field :todo_ids, {:array, :binary_id}
    field :rationales, :map, default: %{}
    field :resolved, :map, default: %{}
    field :status, :string, default: "open"

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [:id, :user_id, :chat_id, :message_id, :todo_ids, :rationales, :resolved, :status])
    |> validate_required([:user_id, :chat_id, :message_id, :todo_ids])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:chat_id, :message_id])
  end

  def create(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.update("chat_id", nil, &normalize_id/1)
      |> Map.update("message_id", nil, &normalize_id/1)

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Looks up the batch behind a Telegram message. Both ids are normalized to
  the same string form `create/1` stores (integer ids become their base-10
  string), so the write and read paths can never diverge on id shape — a
  silent miss here would drop the tap into the destructive single-todo
  refresh path (SPEC 05 R12/edge cases).
  """
  def get_by_message(chat_id, message_id) do
    with chat_id when is_binary(chat_id) <- normalize_id(chat_id),
         message_id when is_binary(message_id) <- normalize_id(message_id) do
      Repo.get_by(__MODULE__, chat_id: chat_id, message_id: message_id)
    else
      _other -> nil
    end
  end

  @doc """
  Records the user's tap for one todo in the batch. Idempotent: re-invoking
  with the same `(todo_id, action)` leaves the `resolved` map unchanged.
  """
  def record_resolution(%__MODULE__{} = batch, todo_id, action, opts \\ [])
      when is_binary(todo_id) and action in @actions do
    resolved = batch.resolved || %{}

    case Map.get(resolved, todo_id) do
      %{"action" => ^action} ->
        {:ok, batch}

      _other ->
        at =
          opts
          |> Keyword.get(:now, DateTime.utc_now())
          |> DateTime.to_iso8601()

        resolved = Map.put(resolved, todo_id, %{"action" => action, "at" => at})

        batch
        |> changeset(%{resolved: resolved})
        |> Repo.update()
    end
  end

  def all_resolved?(%__MODULE__{todo_ids: todo_ids, resolved: resolved}) do
    resolved = resolved || %{}

    todo_ids
    |> List.wrap()
    |> Enum.all?(fn todo_id -> Map.has_key?(resolved, to_string(todo_id)) end)
  end

  def mark_complete(%__MODULE__{} = batch) do
    batch
    |> changeset(%{status: "complete"})
    |> Repo.update()
  end

  @doc """
  Whether the user already received a triage card recently — the per-user
  weekly-ish stagger gate (SPEC 05 R14).
  """
  def exists_since?(user_id, %DateTime{} = since) when is_binary(user_id) do
    Repo.exists?(
      from(batch in __MODULE__,
        where: batch.user_id == ^user_id and batch.inserted_at >= ^since
      )
    )
  end

  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(_value), do: nil
end
