defmodule Maraithon.Runtime.BackgroundJobPartition do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "background_job_partitions" do
    field :queue, :string, primary_key: true
    field :partition_key, :string, primary_key: true
    field :last_started_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
