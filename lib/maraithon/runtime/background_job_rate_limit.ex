defmodule Maraithon.Runtime.BackgroundJobRateLimit do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "background_job_rate_limits" do
    field :queue, :string, primary_key: true
    field :rate_limit_key, :string, primary_key: true
    field :blocked_until, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
