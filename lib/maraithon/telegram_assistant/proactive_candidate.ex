defmodule Maraithon.TelegramAssistant.ProactiveCandidate do
  @moduledoc """
  Durable candidate queue entry for proactive Telegram delivery planning.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @sources ~w(insight brief proactive_check_in)
  @statuses ~w(pending planned delivered held expired)
  @dispositions ~w(interrupt_now digest hold)

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
    |> validate_map(:structured_data)
    |> validate_map(:telegram_opts)
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

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
