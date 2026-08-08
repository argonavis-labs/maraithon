defmodule Maraithon.TelegramAssistant.ProactiveCandidate do
  @moduledoc """
  Durable candidate queue entry for proactive Telegram delivery planning.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # "nudge" (SPEC 01 R4) is NudgeSweep's time-based follow-up proposals.
  # Plain changeset inclusion list — the DB column is an unconstrained
  # string, so no migration accompanies additions here.
  @sources ~w(insight brief proactive_check_in nudge)
  @statuses ~w(pending planned delivered held expired)
  @dispositions ~w(interrupt_now digest hold)
  @max_structured_data_bytes 256_000
  @max_telegram_opts_bytes 32_000
  @max_json_depth 10
  @max_json_nodes 20_000
  @max_json_map_entries 2_000
  @max_json_list_items 2_000
  @max_json_binary_bytes 64_000

  schema "proactive_candidates" do
    field :source, :string
    field :source_id, :string
    field :dedupe_key, :string
    field :title, :string
    field :body, :string
    field :urgency, :float, default: 0.0
    field :why_now, :string
    field :structured_data, :map, default: %{}
    field :telegram_opts, :map, default: %{}
    field :status, :string, default: "pending"
    field :disposition, :string
    field :plan_reason, :string
    field :planned_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :user, User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @enqueue_required_fields [
    :user_id,
    :source,
    :source_id,
    :dedupe_key,
    :title,
    :body,
    :urgency,
    :expires_at
  ]

  @enqueue_optional_fields [
    :why_now,
    :structured_data,
    :telegram_opts,
    :status,
    :disposition,
    :plan_reason,
    :planned_at,
    :delivered_at
  ]

  def sources, do: @sources
  def statuses, do: @statuses
  def dispositions, do: @dispositions

  def enqueue_changeset(candidate, attrs) do
    candidate
    |> cast(attrs || %{}, @enqueue_required_fields ++ @enqueue_optional_fields)
    |> validate_required(@enqueue_required_fields)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:disposition, @dispositions)
    |> validate_length(:source_id, min: 1, max: 255)
    |> validate_length(:dedupe_key, min: 3, max: 255)
    |> validate_length(:title, min: 1, max: 255)
    |> validate_length(:body, min: 1, max: 10_000)
    |> validate_length(:why_now, max: 2_000)
    |> validate_length(:plan_reason, max: 2_000)
    |> validate_number(:urgency, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_json_map(:structured_data, @max_structured_data_bytes)
    |> validate_json_map(:telegram_opts, @max_telegram_opts_bytes)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :dedupe_key],
      name: :proactive_candidates_live_dedupe_index
    )
  end

  def plan_changeset(candidate, disposition, reason) do
    candidate
    |> cast(
      %{
        status: "planned",
        disposition: disposition,
        plan_reason: reason,
        planned_at: DateTime.utc_now()
      },
      [:status, :disposition, :plan_reason, :planned_at]
    )
    |> validate_required([:status, :disposition, :planned_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:disposition, @dispositions)
    |> validate_length(:plan_reason, max: 2_000)
  end

  def status_changeset(candidate, status) do
    attrs =
      case status do
        "delivered" -> %{status: status, delivered_at: DateTime.utc_now()}
        _status -> %{status: status}
      end

    candidate
    |> cast(attrs, [:status, :delivered_at])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end

  @doc false
  def safe_json_shape?(value, max_bytes \\ @max_structured_data_bytes)

  def safe_json_shape?(value, max_bytes),
    do: safe_json_shape?(value, max_bytes, @max_json_binary_bytes)

  def safe_json_shape?(value, max_bytes, max_binary_bytes)
      when is_integer(max_bytes) and max_bytes > 0 and is_integer(max_binary_bytes) and
             max_binary_bytes > 0 do
    match?(
      {:ok, _nodes, _bytes},
      preflight_json(value, 0, 0, 0, max_bytes, max_binary_bytes)
    )
  end

  defp preflight_json(_value, _depth, nodes, _bytes, _max_bytes, _max_binary_bytes)
       when nodes >= @max_json_nodes,
       do: :error

  defp preflight_json(_value, depth, _nodes, _bytes, _max_bytes, _max_binary_bytes)
       when depth > @max_json_depth,
       do: :error

  defp preflight_json(%module{}, _depth, nodes, bytes, max_bytes, _max_binary_bytes)
       when module in [DateTime, NaiveDateTime, Date, Time],
       do: add_json_cost(nodes, bytes, 64, max_bytes)

  defp preflight_json(value, _depth, nodes, bytes, max_bytes, max_binary_bytes)
       when is_binary(value) do
    if byte_size(value) <= max_binary_bytes,
      do: add_json_cost(nodes, bytes, byte_size(value) + 2, max_bytes),
      else: :error
  end

  defp preflight_json(value, _depth, nodes, bytes, max_bytes, _max_binary_bytes)
       when is_integer(value) and value >= -9_223_372_036_854_775_808 and
              value <= 9_223_372_036_854_775_807,
       do: add_json_cost(nodes, bytes, 32, max_bytes)

  defp preflight_json(value, _depth, nodes, bytes, max_bytes, _max_binary_bytes)
       when is_float(value) or is_boolean(value) or is_nil(value),
       do: add_json_cost(nodes, bytes, 32, max_bytes)

  defp preflight_json(value, depth, nodes, bytes, max_bytes, max_binary_bytes)
       when is_map(value) do
    if map_size(value) > @max_json_map_entries do
      :error
    else
      with {:ok, next_nodes, next_bytes} <- add_json_cost(nodes, bytes, 2, max_bytes) do
        Enum.reduce_while(value, {:ok, next_nodes, next_bytes}, fn {key, nested},
                                                                   {:ok, count, size} ->
          with {:ok, key_cost} <- json_key_cost(key),
               {:ok, key_nodes, key_bytes} <- add_json_cost(count, size, key_cost, max_bytes),
               {:ok, nested_nodes, nested_bytes} <-
                 preflight_json(
                   nested,
                   depth + 1,
                   key_nodes,
                   key_bytes,
                   max_bytes,
                   max_binary_bytes
                 ) do
            {:cont, {:ok, nested_nodes, nested_bytes}}
          else
            _error -> {:halt, :error}
          end
        end)
      end
    end
  end

  defp preflight_json(value, depth, nodes, bytes, max_bytes, max_binary_bytes)
       when is_list(value) do
    with {:ok, next_nodes, next_bytes} <- add_json_cost(nodes, bytes, 2, max_bytes) do
      preflight_json_list(
        value,
        depth,
        next_nodes,
        next_bytes,
        0,
        max_bytes,
        max_binary_bytes
      )
    end
  end

  defp preflight_json(_value, _depth, _nodes, _bytes, _max_bytes, _max_binary_bytes),
    do: :error

  defp preflight_json_list(
         [],
         _depth,
         nodes,
         bytes,
         _items,
         _max_bytes,
         _max_binary_bytes
       ),
       do: {:ok, nodes, bytes}

  defp preflight_json_list(
         _list,
         _depth,
         _nodes,
         _bytes,
         items,
         _max_bytes,
         _max_binary_bytes
       )
       when items >= @max_json_list_items,
       do: :error

  defp preflight_json_list(
         [head | tail],
         depth,
         nodes,
         bytes,
         items,
         max_bytes,
         max_binary_bytes
       ) do
    case preflight_json(head, depth + 1, nodes, bytes, max_bytes, max_binary_bytes) do
      {:ok, next_nodes, next_bytes} ->
        preflight_json_list(
          tail,
          depth,
          next_nodes,
          next_bytes,
          items + 1,
          max_bytes,
          max_binary_bytes
        )

      :error ->
        :error
    end
  end

  defp preflight_json_list(
         _improper,
         _depth,
         _nodes,
         _bytes,
         _items,
         _max_bytes,
         _max_binary_bytes
       ),
       do: :error

  defp add_json_cost(nodes, bytes, cost, max_bytes) do
    if nodes + 1 <= @max_json_nodes and bytes + cost <= max_bytes,
      do: {:ok, nodes + 1, bytes + cost},
      else: :error
  end

  defp json_key_cost(key) when is_binary(key) and byte_size(key) <= 255,
    do: {:ok, byte_size(key) + 3}

  defp json_key_cost(key) when is_atom(key), do: json_key_cost(Atom.to_string(key))

  defp json_key_cost(key)
       when is_integer(key) and key >= -9_223_372_036_854_775_808 and
              key <= 9_223_372_036_854_775_807,
       do: {:ok, 32}

  defp json_key_cost(_key), do: :error

  defp validate_json_map(changeset, field, max_bytes) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        not is_map(value) ->
          [{field, "must be a map"}]

        not safe_json_shape?(value, max_bytes) ->
          [{field, "is too complex"}]

        true ->
          case Jason.encode(value) do
            {:ok, encoded} when byte_size(encoded) <= max_bytes -> []
            {:ok, _encoded} -> [{field, "is too large"}]
            {:error, _reason} -> [{field, "must be JSON encodable"}]
          end
      end
    end)
  end
end
